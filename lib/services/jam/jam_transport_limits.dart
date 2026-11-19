import 'jam_queue.dart';

/// Each of two 256 UTF-16-unit identifiers can expand to six ASCII bytes per
/// unit when JSON escapes control characters. The per-entry and envelope
/// allowances cover property names, punctuation, outcome and revision.
const jamMaxResponseBytes = JamQueue.maxEntries * (2 * 256 * 6 + 64) + 1024;
