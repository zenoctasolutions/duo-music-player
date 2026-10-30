// lib/player/track_text.dart
//
// Local fallback for display titles/artists on the Now Playing screens.
// Deliberately isolated: when lib/library/title_cleaner.dart lands, swap the
// bodies of these two functions to delegate to it and nothing else changes.
class TrackText {
  TrackText._();

  static final RegExp _leadingNumber = RegExp(r'^\s*\d{1,3}\s*[-._)]\s*');
  static const String _tlds = r'(?:com|net|org|info|in|me|co|biz|fm|pk|ws|cc|io|tv|xyz|site|mobi|download)';
  // [www.site.com] / (site.info) anywhere in the string.
  static final RegExp _bracketSite = RegExp(
    r'\s*[\[\(\{]\s*(?:https?://)?(?:www\.)?[\w-]+(?:\.[\w-]+)*\.' + _tlds + r'[^\]\)\}]*[\]\)\}]',
    caseSensitive: false,
  );
  // trailing " - www.site.com"
  static final RegExp _trailingSite = RegExp(
    r'\s*[-–|]\s*(?:https?://)?(?:www\.)?[\w-]+(?:\.[\w-]+)*\.' + _tlds + r'\s*$',
    caseSensitive: false,
  );
  static final RegExp _looksLikeSite = RegExp(
    r'(?:https?://|www\.|\b[\w-]+\.' + _tlds + r'\b)',
    caseSensitive: false,
  );

  /// Title without a leading track number or website tag. Never returns an
  /// empty string: falls back to the trimmed input.
  static String title(String raw) {
    var t = raw.trim();
    t = t.replaceAll(_bracketSite, '');
    t = t.replaceAll(_trailingSite, '');
    t = t.replaceFirst(_leadingNumber, '');
    t = t.replaceAll(RegExp(r'[\s_]+'), ' ').trim();
    t = t.replaceAll(RegExp(r'^[-–\s]+|[-–\s]+$'), '');
    return t.isEmpty ? raw.trim() : t;
  }

  /// Artist, or null when missing / "unknown" / a website.
  static String? artist(String? raw) {
    final a = raw?.trim();
    if (a == null || a.isEmpty) return null;
    final lower = a.toLowerCase();
    if (lower == 'unknown' || lower == 'unknown artist' || lower == '<unknown>') return null;
    if (_looksLikeSite.hasMatch(a)) return null;
    return a;
  }
}
