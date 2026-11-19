import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:mornye/constants/plugin_code_api.dart';
import 'package:path/path.dart' as p;

enum PluginCodeFailure {
  invalidFormat,
  notFound,
  network,
  server,
  malformed,
  insecureUrl,
  hashMismatch,
  tooLarge,
  installFailed,
  timeout,
}

class PluginCodeException implements Exception {
  const PluginCodeException(this.failure);

  final PluginCodeFailure failure;

  @override
  String toString() => 'PluginCodeException(${failure.name})';
}

class PluginCodeItem {
  const PluginCodeItem({
    required this.id,
    required this.name,
    required this.version,
    required this.url,
    required this.sha256,
  });

  final String id;
  final String name;
  final String version;
  final Uri url;
  final String sha256;
}

class PluginCodeBundle {
  const PluginCodeBundle({
    required this.code,
    required this.name,
    required this.items,
  });

  final String code;
  final String name;
  final List<PluginCodeItem> items;
}

enum PluginCodeOutcome { added, updated, alreadyAdded, failed }

class PluginCodeItemResult {
  const PluginCodeItemResult({
    required this.item,
    required this.outcome,
    this.failure,
  });

  final PluginCodeItem item;
  final PluginCodeOutcome outcome;
  final PluginCodeFailure? failure;
}

class PluginCodeReport {
  const PluginCodeReport({required this.bundle, required this.results});

  final PluginCodeBundle bundle;
  final List<PluginCodeItemResult> results;

  int count(PluginCodeOutcome outcome) =>
      results.where((result) => result.outcome == outcome).length;

  bool get anyChanged =>
      count(PluginCodeOutcome.added) + count(PluginCodeOutcome.updated) > 0;
}

String? normalizePluginCode(String input) {
  final code = input.trim().toUpperCase();
  if (code.length < pluginCodeMinLength || code.length > pluginCodeMaxLength) {
    return null;
  }
  return RegExp(r'^[A-Z0-9-]+$').hasMatch(code) ? code : null;
}

int comparePluginVersions(String a, String b) {
  List<int> parse(String value) => value
      .split(RegExp(r'[.+-]'))
      .map((part) => int.tryParse(part) ?? 0)
      .toList();
  final left = parse(a);
  final right = parse(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

class PluginCodeService {
  PluginCodeService({http.Client? client, Directory? tempRoot})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _tempRoot = tempRoot;

  final http.Client _client;
  final bool _ownsClient;
  final Directory? _tempRoot;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<PluginCodeBundle> lookup(String input) async {
    final code = normalizePluginCode(input);
    if (code == null) {
      throw const PluginCodeException(PluginCodeFailure.invalidFormat);
    }
    final uri = Uri.https(pluginCodeApiHost, '$pluginCodeApiPath$code');
    final response = await _get(
      uri,
      timeout: pluginCodeLookupTimeout,
      allowHost: (host) => host == pluginCodeApiHost,
    );
    if (response.statusCode == 404) {
      throw const PluginCodeException(PluginCodeFailure.notFound);
    }
    if (response.statusCode != 200) {
      throw const PluginCodeException(PluginCodeFailure.server);
    }
    return _parseBundle(code, response.bodyBytes);
  }

  PluginCodeBundle _parseBundle(String code, List<int> body) {
    try {
      final decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map) throw const FormatException();
      final rawItems = decoded['items'];
      if (rawItems is! List || rawItems.isEmpty) throw const FormatException();
      final items = <PluginCodeItem>[];
      for (final raw in rawItems) {
        if (raw is! Map) throw const FormatException();
        final id = raw['id'];
        final version = raw['version'];
        final url = raw['url'];
        final hash = raw['sha256'];
        if (id is! String ||
            id.trim().isEmpty ||
            version is! String ||
            version.trim().isEmpty ||
            url is! String ||
            hash is! String ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hash)) {
          throw const FormatException();
        }
        final name = raw['name'];
        items.add(
          PluginCodeItem(
            id: id.trim(),
            name: name is String && name.trim().isNotEmpty
                ? name.trim()
                : id.trim(),
            version: version.trim(),
            url: Uri.parse(url),
            sha256: hash.toLowerCase(),
          ),
        );
      }
      final name = decoded['name'];
      return PluginCodeBundle(
        code: code,
        name: name is String && name.trim().isNotEmpty ? name.trim() : code,
        items: items,
      );
    } on FormatException {
      throw const PluginCodeException(PluginCodeFailure.malformed);
    }
  }

  Future<http.Response> _get(
    Uri uri, {
    required Duration timeout,
    bool Function(String host)? allowHost,
  }) async {
    var current = uri;
    for (var hop = 0; hop <= pluginCodeMaxRedirects; hop++) {
      if (current.scheme != 'https' ||
          current.host.isEmpty ||
          (allowHost != null && !allowHost(current.host))) {
        throw const PluginCodeException(PluginCodeFailure.insecureUrl);
      }
      final http.Response response;
      try {
        final request = http.Request('GET', current)..followRedirects = false;
        final streamed = await _client.send(request).timeout(timeout);
        response = await http.Response.fromStream(streamed).timeout(timeout);
      } on TimeoutException {
        throw const PluginCodeException(PluginCodeFailure.network);
      } on SocketException {
        throw const PluginCodeException(PluginCodeFailure.network);
      } on HandshakeException {
        throw const PluginCodeException(PluginCodeFailure.network);
      } on http.ClientException {
        throw const PluginCodeException(PluginCodeFailure.network);
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location == null) {
          throw const PluginCodeException(PluginCodeFailure.server);
        }
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw const PluginCodeException(PluginCodeFailure.server);
  }

  Future<File> downloadVerified(PluginCodeItem item) async {
    final response = await _get(item.url, timeout: pluginCodeDownloadTimeout);
    if (response.statusCode != 200) {
      throw const PluginCodeException(PluginCodeFailure.server);
    }
    final bytes = response.bodyBytes;
    if (bytes.length > pluginCodeMaxPackageBytes) {
      throw const PluginCodeException(PluginCodeFailure.tooLarge);
    }
    if (sha256.convert(bytes).toString() != item.sha256) {
      throw const PluginCodeException(PluginCodeFailure.hashMismatch);
    }
    final root = _tempRoot ?? Directory.systemTemp;
    final dir = await root.createTemp('musa_plugin_code_');
    final safeId = item.id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = File(p.join(dir.path, '$safeId.mornye-ext'));
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<PluginCodeReport> redeem(
    String input, {
    required Map<String, String> installedVersions,
    required Future<bool> Function(String path) install,
    required Future<bool> Function(String path) upgrade,
    Duration itemTimeout = pluginCodeItemTimeout,
    void Function(PluginCodeBundle bundle)? onBundle,
    void Function(int index, PluginCodeItem item)? onItemStart,
    void Function(int index, PluginCodeItemResult result)? onItemResult,
  }) async {
    final bundle = await lookup(input);
    onBundle?.call(bundle);
    final results = <PluginCodeItemResult>[];
    for (var index = 0; index < bundle.items.length; index++) {
      final item = bundle.items[index];
      onItemStart?.call(index, item);
      final result = await _processItem(
        item,
        installed: installedVersions[item.id],
        install: install,
        upgrade: upgrade,
        itemTimeout: itemTimeout,
      );
      results.add(result);
      onItemResult?.call(index, result);
    }
    return PluginCodeReport(bundle: bundle, results: results);
  }

  Future<PluginCodeItemResult> _processItem(
    PluginCodeItem item, {
    required String? installed,
    required Future<bool> Function(String path) install,
    required Future<bool> Function(String path) upgrade,
    required Duration itemTimeout,
  }) async {
    if (installed != null &&
        comparePluginVersions(item.version, installed) <= 0) {
      return PluginCodeItemResult(
        item: item,
        outcome: PluginCodeOutcome.alreadyAdded,
      );
    }
    File? file;
    var timedOut = false;
    try {
      final ok = await (() async {
        file = await downloadVerified(item);
        return installed == null
            ? await install(file!.path)
            : await upgrade(file!.path);
      })().timeout(itemTimeout);
      return PluginCodeItemResult(
        item: item,
        outcome: !ok
            ? PluginCodeOutcome.failed
            : installed == null
            ? PluginCodeOutcome.added
            : PluginCodeOutcome.updated,
        failure: ok ? null : PluginCodeFailure.installFailed,
      );
    } on TimeoutException {
      timedOut = true;
      return PluginCodeItemResult(
        item: item,
        outcome: PluginCodeOutcome.failed,
        failure: PluginCodeFailure.timeout,
      );
    } on PluginCodeException catch (error) {
      return PluginCodeItemResult(
        item: item,
        outcome: PluginCodeOutcome.failed,
        failure: error.failure,
      );
    } on FileSystemException {
      return PluginCodeItemResult(
        item: item,
        outcome: PluginCodeOutcome.failed,
        failure: PluginCodeFailure.installFailed,
      );
    } catch (_) {
      return PluginCodeItemResult(
        item: item,
        outcome: PluginCodeOutcome.failed,
        failure: PluginCodeFailure.installFailed,
      );
    } finally {
      final created = file;
      if (created != null && !timedOut) {
        try {
          await created.parent.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
