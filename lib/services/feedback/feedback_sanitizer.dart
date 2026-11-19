import 'package:mornye/services/bug_log.dart';

class FeedbackSanitizer {
  const FeedbackSanitizer._();

  static const maxTextLength = 4000;

  static final _link = RegExp(r'https?://[^\s)\]>"]+', caseSensitive: false);
  static final _sensitiveQuery = RegExp(
    r'(token|sig|signature|key|secret|auth|password|passwd|session|cookie|'
    r'credential|jwt|code)',
    caseSensitive: false,
  );
  static final _secretLikeWord = RegExp(
    r'\b(?=[A-Za-z0-9_-]*\d)(?=[A-Za-z0-9_-]*[A-Za-z])[A-Za-z0-9_-]{32,}\b',
  );
  static final _linkMark = RegExp('(\\d+)');

  /// Text written by the person reporting: links stay (without credentials or
  /// signed queries) and long words stay unless they look like a secret.
  static String cleanUserText(String text, {int maxLength = maxTextLength}) {
    final links = <String>[];
    final masked = text.replaceAllMapped(_link, (match) {
      links.add(_safeLink(match[0]!));
      return '${links.length - 1}';
    });
    var value = _clean(masked, redactLinks: false, redactLongWords: false);
    value = value.replaceAll(_secretLikeWord, '[redactado]');
    value = value.replaceAllMapped(
      _linkMark,
      (match) => links[int.parse(match[1]!)],
    );
    return value.length > maxLength ? value.substring(0, maxLength) : value;
  }

  static String _safeLink(String link) {
    final uri = Uri.tryParse(link);
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return '[URL]';
    final risky =
        uri.userInfo.isNotEmpty ||
        (uri.hasQuery && _sensitiveQuery.hasMatch(uri.query)) ||
        _sensitiveQuery.hasMatch(uri.fragment);
    if (!risky) return link;
    final port = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$port${uri.path}';
  }

  static String clean(String text, {int maxLength = maxTextLength}) =>
      _clean(text, maxLength: maxLength);

  static String _clean(
    String text, {
    int maxLength = maxTextLength,
    bool redactLinks = true,
    bool redactLongWords = true,
  }) {
    var value = text;
    if (redactLinks) value = value.replaceAll(_link, '[URL]');
    value = value.replaceAllMapped(
      RegExp(r'\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (match) => '${match[1]} [redactado]',
    );
    value = value.replaceAll(
      RegExp(
        r'\b(token|access[_-]?token|refresh[_-]?token|password|passwd|'
        r'contrasena|api[_-]?key|secret|cookie|authorization|sig|signature)'
        r'\s*[:=]\s*[^\s,;&]+',
        caseSensitive: false,
      ),
      '[redactado]',
    );
    value = value.replaceAll(
      RegExp(r'\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b'),
      '[correo]',
    );
    value = value.replaceAll(
      RegExp(r'\b[A-Za-z]:\\(?:[^\\\s:*?"<>|]+\\)*[^\\\s:*?"<>|]*'),
      '[ruta]',
    );
    value = value.replaceAll(
      RegExp(
        r'(?<![A-Za-z0-9_])/(?:storage|sdcard|data|home|Users|mnt|var|private)'
        r'(?:/[^\s,;:)\]"]+)+',
      ),
      '[ruta]',
    );
    if (redactLongWords) {
      value = value.replaceAll(
        RegExp(r'\b[A-Za-z0-9_-]{32,}\b'),
        '[redactado]',
      );
    }
    value = value
        .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
        .trim();
    return value.length > maxLength ? value.substring(0, maxLength) : value;
  }

  static String cleanLine(String text, {int maxLength = 120}) =>
      clean(text.replaceAll(RegExp(r'\s+'), ' '), maxLength: maxLength);

  static List<String> cleanLogEntries(
    List<Map<String, String>> entries, {
    int limit = 20,
  }) {
    final recent = entries.length > limit
        ? entries.sublist(entries.length - limit)
        : entries;
    return [
      for (final entry in recent)
        cleanLine(
          [
            entry['time'],
            entry['category'],
            entry['type'],
            entry['tag'],
            entry['frames'],
            if (entry['count'] != null) 'omitidos ${entry['count']}',
            if (entry['note'] != null) BugLog.sanitizeNote(entry['note']!),
          ].whereType<String>().where((part) => part.isNotEmpty).join(' | '),
          maxLength: 400,
        ),
    ];
  }
}
