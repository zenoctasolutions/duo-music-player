// lib/library/m3u_service.dart
//
// Pure-Dart M3U / M3U8 encode, parse and library matching. No Flutter or
// platform dependencies so it is fully unit-testable.
import 'package:path/path.dart' as p;

import 'title_cleaner.dart';

/// One track line of a playlist file.
class M3uEntry {
  /// Path exactly as normalised from the file (absolute when [baseDir] was
  /// supplied for relative entries).
  final String path;

  /// Raw text of the line (before decoding), for diagnostics.
  final String raw;

  /// From #EXTINF: the text after the comma (usually "Artist - Title").
  final String? extTitle;

  /// From #EXTINF: seconds, null when absent or negative (-1 = unknown).
  final int? durationSec;

  const M3uEntry({required this.path, required this.raw, this.extTitle, this.durationSec});

  @override
  String toString() => 'M3uEntry($path, $extTitle, $durationSec)';
}

class M3uMatch {
  final M3uEntry entry;
  final String libraryPath;

  /// 'path', 'basename' or 'title'.
  final String how;
  const M3uMatch(this.entry, this.libraryPath, this.how);
}

class M3uResolution {
  final List<M3uMatch> matched;
  final List<M3uEntry> unresolved;
  const M3uResolution(this.matched, this.unresolved);

  List<String> get paths => matched.map((m) => m.libraryPath).toList();
}

class M3uService {
  M3uService._();

  // ------------------------------------------------------------------ encode

  /// Build an extended M3U. Callbacks supply optional metadata per path;
  /// without them the title falls back to the cleaned file name.
  /// Paths are written relative to their deepest common folder when every
  /// track lives under one, otherwise absolute.
  static String encode(
    String name,
    List<String> paths, {
    int? Function(String path)? durationOf,
    String? Function(String path)? titleOf,
    String? Function(String path)? artistOf,
    String newline = '\n',
  }) {
    final posix = p.posix;
    final norm = paths.map((e) => e.replaceAll('\\', '/')).toList();
    final common = _commonDir(norm);
    final b = StringBuffer('#EXTM3U$newline');
    final safeName = name.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (safeName.isNotEmpty) b.write('#PLAYLIST:$safeName$newline');
    for (var i = 0; i < paths.length; i++) {
      final orig = paths[i];
      final title = TitleCleaner.title(titleOf?.call(orig), path: orig);
      final artist = TitleCleaner.artist(artistOf?.call(orig));
      final label = (artist != null ? '$artist - $title' : title).replaceAll(RegExp(r'[\r\n]+'), ' ');
      final d = durationOf?.call(orig);
      b.write('#EXTINF:${(d != null && d > 0) ? d : -1},$label$newline');
      final line = common != null ? posix.relative(norm[i], from: common) : norm[i];
      b.write('$line$newline');
    }
    return b.toString();
  }

  /// Deepest folder containing every path, or null when paths are not all
  /// absolute POSIX paths sharing a non-root folder.
  static String? _commonDir(List<String> norm) {
    if (norm.isEmpty || norm.any((e) => !e.startsWith('/'))) return null;
    final posix = p.posix;
    final dirs = norm.map((e) => posix.split(posix.dirname(e))).toList();
    var common = dirs.first;
    for (final d in dirs.skip(1)) {
      var n = 0;
      while (n < common.length && n < d.length && common[n] == d[n]) {
        n++;
      }
      common = common.sublist(0, n);
    }
    if (common.length <= 1) return null; // only '/' shared
    return posix.joinAll(common);
  }

  // ------------------------------------------------------------------- parse

  /// Parse playlist [content]. Relative entries are joined onto [baseDir].
  /// HTTP(S) stream URLs and blank/comment lines are skipped.
  static List<M3uEntry> parse(String content, {required String baseDir}) {
    if (content.startsWith('\uFEFF')) content = content.substring(1);
    final out = <M3uEntry>[];
    String? pendingTitle;
    int? pendingDur;
    for (final rawLine in content.split(RegExp(r'\r\n|\r|\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) {
        if (line.toUpperCase().startsWith('#EXTINF:')) {
          final body = line.substring(8);
          final comma = body.indexOf(',');
          final durText = (comma < 0 ? body : body.substring(0, comma)).trim().split(RegExp(r'\s'))[0];
          final d = double.tryParse(durText)?.round();
          pendingDur = (d != null && d >= 0) ? d : null;
          final t = comma < 0 ? '' : body.substring(comma + 1).trim();
          pendingTitle = t.isEmpty ? null : t;
        }
        continue;
      }
      if (RegExp(r'^https?://', caseSensitive: false).hasMatch(line)) {
        pendingTitle = null;
        pendingDur = null;
        continue;
      }
      out.add(M3uEntry(
        path: normalizePath(line, baseDir: baseDir),
        raw: line,
        extTitle: pendingTitle,
        durationSec: pendingDur,
      ));
      pendingTitle = null;
      pendingDur = null;
    }
    return out;
  }

  /// Decode `file://`, percent-escapes and backslashes, and make absolute.
  static String normalizePath(String raw, {required String baseDir}) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('file:')) {
      try {
        s = Uri.parse(s).toFilePath(windows: false);
      } catch (_) {
        s = s.replaceFirst(RegExp(r'^file:(//)?(localhost)?', caseSensitive: false), '');
        s = _safeDecode(s);
      }
    } else if (RegExp(r'%[0-9A-Fa-f]{2}').hasMatch(s)) {
      s = _safeDecode(s);
    }
    s = s.replaceAll('\\', '/');
    final isAbs = s.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(s);
    if (!isAbs) s = p.posix.join(baseDir.replaceAll('\\', '/'), s);
    return p.posix.normalize(s);
  }

  static String _safeDecode(String s) {
    try {
      return Uri.decodeFull(s);
    } catch (_) {
      return s;
    }
  }

  // ----------------------------------------------------------------- resolve

  static String _key(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();

  /// Map [entries] onto [libraryPaths]: exact path, then unique
  /// case-insensitive basename, then unique cleaned-title match.
  /// Duplicate library hits are collapsed in order.
  static M3uResolution resolve(List<M3uEntry> entries, Iterable<String> libraryPaths) {
    final lib = libraryPaths.toList();
    final exact = <String>{...lib};
    final byBase = <String, List<String>>{};
    final byTitle = <String, List<String>>{};
    for (final l in lib) {
      byBase.putIfAbsent(p.basename(l).toLowerCase(), () => []).add(l);
      final k = _key(TitleCleaner.title(null, path: l));
      if (k.isNotEmpty) byTitle.putIfAbsent(k, () => []).add(l);
    }
    final matched = <M3uMatch>[];
    final unresolved = <M3uEntry>[];
    final seen = <String>{};
    for (final e in entries) {
      String? hit;
      String how = 'path';
      if (exact.contains(e.path)) {
        hit = e.path;
      } else {
        final base = p.basename(e.path.replaceAll('\\', '/')).toLowerCase();
        final b = byBase[base];
        if (b != null && b.length == 1) {
          hit = b.first;
          how = 'basename';
        } else if (b == null) {
          final cands = <String>{
            _key(TitleCleaner.title(null, path: e.path)),
            if (e.extTitle != null) ...[
              _key(TitleCleaner.title(e.extTitle)),
              if (e.extTitle!.contains(' - ')) _key(TitleCleaner.title(e.extTitle!.split(' - ').sublist(1).join(' - '))),
            ],
          }..remove('');
          for (final c in cands) {
            final t = byTitle[c];
            if (t != null && t.length == 1) {
              hit = t.first;
              how = 'title';
              break;
            }
          }
        }
      }
      if (hit == null) {
        unresolved.add(e);
      } else if (seen.add(hit)) {
        matched.add(M3uMatch(e, hit, how));
      }
    }
    return M3uResolution(matched, unresolved);
  }

  /// Display label for an entry using TitleCleaner.
  static String displayTitle(M3uEntry e) {
    final t = e.extTitle;
    if (t != null && t.trim().isNotEmpty) return TitleCleaner.title(t);
    return TitleCleaner.title(null, path: e.path);
  }

  /// Playlist name suggested by the file name or #PLAYLIST header.
  static String? playlistNameFromContent(String content) {
    final m = RegExp(r'^\uFEFF?.*?#PLAYLIST:(.+)$', multiLine: true).firstMatch(content);
    final n = m?.group(1)?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }
}
