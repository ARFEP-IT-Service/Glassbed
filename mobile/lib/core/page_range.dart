/// Parses a page selection like "1-3, 5" into 0-based page indices, in the given order.
///
/// Empty text means all pages. "3-" runs to the last page, "-2" starts at the first.
/// "," and ";" separate parts; empty parts are ignored. A range ending past the last
/// page is cut at the last page.
/// Throws [FormatException] for anything else: not a number, page 0, a reversed
/// range ("5-3") or a start beyond [pageCount].
List<int> parsePageRange(String text, int pageCount) {
  final t = text.trim();
  if (t.isEmpty) return [for (var i = 0; i < pageCount; i++) i];
  final result = <int>[];
  for (final raw in t.replaceAll(';', ',').split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    int start, end;
    final dash = part.indexOf('-');
    if (dash >= 0) {
      final a = part.substring(0, dash).trim(), b = part.substring(dash + 1).trim();
      start = a.isEmpty ? 1 : _number(a, part);
      end = b.isEmpty ? pageCount : _number(b, part);
    } else {
      start = end = _number(part, part);
    }
    if (start < 1 || end < start || start > pageCount) {
      throw FormatException('Invalid page range', part);
    }
    for (var p = start; p <= end && p <= pageCount; p++) {
      result.add(p - 1);
    }
  }
  return result;
}

int _number(String s, String part) {
  if (!RegExp(r'^\d+$').hasMatch(s)) throw FormatException('Invalid page range', part);
  return int.parse(s);
}
