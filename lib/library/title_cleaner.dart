// lib/library/title_cleaner.dart
//
// Display-only cleaning of song titles and artists. Files ripped from
// download sites carry junk in their tags / file names ("01 - Song
// [www.SenSongsMp3.co]", "[iSongs.info] 01 - Song", artist "www.site.com").
// Nothing here touches files or tags on disk — every Library list calls
// these helpers so the same song reads the same everywhere.
import 'package:path/path.dart' as p;

class TitleCleaner {
  TitleCleaner._();

  static const String unknownArtist = 'Unknown Artist';

  static const _tlds = 'com|co|net|in|info|org|me|fm|cc|biz|pk|lk|io|tv|ws|to|us|uk|xyz|site|download';
  static const _siteNames =
      'isongs|sensongs|naasongs|starmusiq|masstamilan|pagalworld|pagal ?world|mr-?jatt|djmaza|songspk|'
      'downloadming|wapking|djpunjab|webmusic|mp3mad|raagtune|freshmaza|songsmp3|mp3songs';

  /// Whole bracketed group that mentions a site, e.g. "[www.SenSongsMp3.co]".
  static final RegExp _bracketedSite = RegExp(
      r'\s*[\(\[\{][^\)\]\}]*(www\.|\b[\w-]+\.(' + _tlds + r')\b|' + _siteNames + r'|songs ?mp3)[^\)\]\}]*[\)\]\}]',
      caseSensitive: false);

  /// Bare site token outside brackets, e.g. "Song - PagalWorld.com".
  static final RegExp _bareSite = RegExp(
      r'(https?://)?(www\.)?\b[\w-]+\.(' + _tlds + r')\b(\.[a-z]{2})?|\b(' + _siteNames + r')\b',
      caseSensitive: false);

  static final RegExp _leadingTrackNo = RegExp(r'^\s*\d{1,3}\s*[-.)_]\s*');
  static final RegExp _leadingPaddedNo = RegExp(r'^\s*0\d\s+(?=\D)');
  static final RegExp _edgeJunk = RegExp(r'^[\s\-–—:|_.]+|[\s\-–—:|_.]+$');

  /// True when [text] looks like a web address / download-site name.
  static bool looksLikeSite(String text) {
    final t = text.trim();
    if (t.isEmpty) return false;
    return RegExp(r'www\.|https?://', caseSensitive: false).hasMatch(t) ||
        RegExp(r'\b[\w-]+\.(' + _tlds + r')\b', caseSensitive: false).hasMatch(t) ||
        RegExp(r'\b(' + _siteNames + r')\b', caseSensitive: false).hasMatch(t);
  }

  /// Cleaned title from a tag title [raw], falling back to the file name of
  /// [path] (without extension) when the tag is empty. Never returns an
  /// empty string when any input is non-empty.
  static String title(String? raw, {String? path}) {
    final tag = raw?.trim() ?? '';
    final base = tag.isNotEmpty ? tag : (path != null ? p.basenameWithoutExtension(path) : '');
    if (base.trim().isEmpty) return base.trim();

    var t = base.replaceAll('_', ' ');
    // Site tags can wrap or lead the title, and can be stacked.
    t = t.replaceAll(_bracketedSite, ' ').replaceAll(_bareSite, ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').replaceAll(_edgeJunk, '');
    // Track numbers may sit behind a removed leading tag, so strip after.
    t = t.replaceFirst(_leadingTrackNo, '').replaceFirst(_leadingPaddedNo, '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').replaceAll(_edgeJunk, '');
    return t.isEmpty ? base.trim() : t;
  }

  /// Cleaned artist, or null when it is empty, "unknown", or a website
  /// name. [albumArtist] is the fallback tried before giving up.
  static String? artist(String? raw, {String? albumArtist}) {
    final cleaned = _cleanArtist(raw);
    if (cleaned != null) return cleaned;
    return _cleanArtist(albumArtist);
  }

  /// [artist] with 'Unknown Artist' as the final fallback.
  static String artistOrUnknown(String? raw, {String? albumArtist}) =>
      artist(raw, albumArtist: albumArtist) ?? unknownArtist;

  static String? _cleanArtist(String? raw) {
    if (raw == null) return null;
    var t = raw.trim();
    if (t.isEmpty) return null;
    if (looksLikeSite(t)) {
      // "Artist [www.site.com]" keeps the artist; a pure site name is dropped.
      t = t.replaceAll(_bracketedSite, ' ').replaceAll(_bareSite, ' ');
      t = t.replaceAll(RegExp(r'\s+'), ' ').replaceAll(_edgeJunk, '');
      if (t.isEmpty || looksLikeSite(t)) return null;
    }
    final low = t.toLowerCase();
    if (low.contains('unknown') || low == 'na' || low == 'n/a' || low == '-' || low == '<unknown>') return null;
    return t;
  }

  /// Alphabet header for A-Z lists: A-Z for letters, '#' for everything
  /// else (digits, symbols, non-Latin scripts).
  static String sectionLetter(String displayTitle) {
    final t = displayTitle.trim();
    if (t.isEmpty) return '#';
    final first = t[0].toUpperCase();
    return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
  }
}
