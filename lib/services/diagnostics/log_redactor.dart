import 'dart:convert';

class LogRedactor {
  const LogRedactor._();

  static const maxLines = 300;
  static const maxBytes = 20 * 1024;
  static const maxLineLength = 400;
  static const mask = '[redactado]';

  static const _names =
      r'[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|contrasena|api[_-]?key|'
      r'admin[_-]?key|sp_dc|sp_key|cookie|signature|authorization|credential|'
      r'session[_-]?id|jwt|private[_-]?key)[A-Za-z0-9_.-]*';

  static final _header = RegExp(
    r'\b(authorization|proxy-authorization|cookie|set-cookie|x-api-key|'
    r'x-auth-token)\s*[:=]\s*[^\r\n]*',
    caseSensitive: false,
  );
  static final _scheme = RegExp(
    r'\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+',
    caseSensitive: false,
  );
  static final _pair = RegExp(
    r'''(["']?)(''' +
        _names +
        r''')(["']?)(\s*[:=]\s*)(?!\[redactado\])("[^"]*"|'[^']*'|[^\s,;&"'}\]]+)''',
    caseSensitive: false,
  );
  static final _jwt = RegExp(
    r'\beyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*',
  );
  static final _url = RegExp(
    r'''https?://[^\s)\]>"']+''',
    caseSensitive: false,
  );
  static final _pluginCodePath = RegExp(
    r'(/v1/(?:code|pack)/)[A-Za-z0-9-]{4,40}',
    caseSensitive: false,
  );
  static final _pluginCodeWord = RegExp(
    r'\b(codigo|código|code|pack)(\s*[:=]\s*)[A-Za-z0-9-]{4,32}\b',
    caseSensitive: false,
  );
  static final _pluginCodeShape = RegExp(r'\b[A-Z0-9]{3}-[A-Z0-9]{3}\b');
  static final _email = RegExp(
    r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b',
  );
  static final _windowsUser = RegExp(
    r'\b([A-Za-z]:[\\/]+Users[\\/]+)[^\\/:*?"<>|\r\n]+',
    caseSensitive: false,
  );
  static final _unixUser = RegExp(
    r'(?<![A-Za-z0-9_])(/(?:home|Users))/[^/\s]+',
  );
  static const _androidRoots =
      r'(?<![A-Za-z0-9_])/(?:storage|sdcard|mnt/sdcard|data/(?:user|data)|'
      r'private/var)';
  static final _androidFile = RegExp(
    '$_androidRoots'
    r'''(?:/[^/\r\n"',;:)\]]+)+?\.[A-Za-z0-9]{2,5}(?![A-Za-z0-9])''',
  );
  static final _androidPath = RegExp(
    '$_androidRoots'
    r'''(?:/[^\s,;:)\]"']+)+''',
  );
  static final _secretWord = RegExp(
    r'(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*\d)(?=[A-Za-z0-9_+/=-]*[A-Za-z])'
    r'[A-Za-z0-9_+/=-]{32,}(?![A-Za-z0-9_+/=-])',
  );
  static final _veryLongWord = RegExp(r'[A-Za-z0-9_-]{48,}');
  static final _control = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]');

  static String redactLine(String line) {
    var value = line.replaceAll(_control, '');
    value = value.replaceAllMapped(_header, (m) => '${m[1]}: $mask');
    value = value.replaceAllMapped(_scheme, (m) => '${m[1]} $mask');
    value = value.replaceAllMapped(_url, (m) => _safeUrl(m[0]!));
    value = value.replaceAllMapped(_pair, (m) {
      final raw = m[5]!;
      final quote = raw.startsWith('"') || raw.startsWith("'") ? raw[0] : '';
      return '${m[1]}${m[2]}${m[3]}${m[4]}$quote$mask$quote';
    });
    value = value.replaceAll(_jwt, mask);
    value = value.replaceAllMapped(_pluginCodePath, (m) => '${m[1]}$mask');
    value = value.replaceAllMapped(
      _pluginCodeWord,
      (m) => '${m[1]}${m[2]}$mask',
    );
    value = value.replaceAll(_pluginCodeShape, '[codigo]');
    value = value.replaceAll(_email, '[correo]');
    value = value.replaceAllMapped(_windowsUser, (m) => '${m[1]}[usuario]');
    value = value.replaceAllMapped(_unixUser, (m) => '${m[1]}/[usuario]');
    value = value.replaceAll(_androidFile, '[ruta]');
    value = value.replaceAll(_androidPath, '[ruta]');
    value = value.replaceAll(_secretWord, mask);
    value = value.replaceAll(_veryLongWord, mask);
    if (value.length > maxLineLength) {
      value = '${value.substring(0, maxLineLength)}...';
    }
    return value;
  }

  static String _safeUrl(String raw) {
    final trailing = RegExp(r'[.,;]+$').firstMatch(raw)?[0] ?? '';
    final text = trailing.isEmpty
        ? raw
        : raw.substring(0, raw.length - trailing.length);
    final uri = Uri.tryParse(text);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      return '[URL]$trailing';
    }
    final port = uri.hasPort ? ':${uri.port}' : '';
    final query = uri.hasQuery || uri.fragment.isNotEmpty ? '?$mask' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}$query$trailing';
  }

  /// Redacts every line, keeps the latest [lines] lines and at most [bytes]
  /// UTF-8 bytes (the oldest lines go first).
  static String redact(
    String text, {
    int lines = maxLines,
    int bytes = maxBytes,
  }) {
    final all = const LineSplitter().convert(text);
    final recent = all.length > lines ? all.sublist(all.length - lines) : all;
    final cleaned = [for (final line in recent) redactLine(line)];
    var total = 0;
    var start = cleaned.length;
    while (start > 0) {
      final cost = utf8.encode(cleaned[start - 1]).length + 1;
      if (total + cost > bytes) break;
      total += cost;
      start--;
    }
    return cleaned.sublist(start).join('\n');
  }
}
