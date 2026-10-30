// lib/search/search_service.dart
//
// Pure-Dart global search: tokenised, case- and diacritic-insensitive,
// ranked prefix > word-start > substring, grouped into Songs / Albums /
// Artists / Playlists. No Flutter imports so it can run in an isolate and be
// unit-tested directly.
import 'package:path/path.dart' as p;

import '../library/title_cleaner.dart';

/// Raw per-song input; cleaning is done by [SearchService.buildIndex].
class SearchInput {
  final String path;
  final String? title; // raw tag title
  final String? artist; // raw tag artist
  final String? album;
  const SearchInput({required this.path, this.title, this.artist, this.album});
}

class SearchSong {
  final String path;
  final String title; // cleaned
  final String artist; // cleaned or ''
  final String album; // '' when unknown
  final String fileName;
  final String folder;
  final String _nTitle, _nArtist, _nAlbum, _nFile, _nFolder;
  SearchSong._(this.path, this.title, this.artist, this.album, this.fileName, this.folder)
      : _nTitle = SearchService.fold(title),
        _nArtist = SearchService.fold(artist),
        _nAlbum = SearchService.fold(album),
        _nFile = SearchService.fold(fileName),
        _nFolder = SearchService.fold(folder);
}

class SearchAlbum {
  final String name;
  final String artist;
  final List<String> paths;
  const SearchAlbum(this.name, this.artist, this.paths);
}

class SearchArtist {
  final String name;
  final List<String> paths;
  const SearchArtist(this.name, this.paths);
}

class SearchPlaylist {
  final String name;
  final List<String> paths;
  const SearchPlaylist(this.name, this.paths);
}

class SearchResults {
  final List<SearchSong> songs;
  final List<SearchAlbum> albums;
  final List<SearchArtist> artists;
  final List<SearchPlaylist> playlists;
  const SearchResults(this.songs, this.albums, this.artists, this.playlists);
  static const empty = SearchResults([], [], [], []);
  bool get isEmpty => songs.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty;
  int get total => songs.length + albums.length + artists.length + playlists.length;
}

/// Immutable searchable snapshot (sendable to an isolate).
class SearchIndex {
  final List<SearchSong> songs;
  final List<SearchAlbum> albums;
  final List<SearchArtist> artists;
  final List<SearchPlaylist> playlists;
  const SearchIndex(this.songs, this.albums, this.artists, this.playlists);
  int get size => songs.length;
  SearchResults search(String query) => SearchService.search(this, query);
}

class SearchService {
  SearchService._();

  static const int maxSongs = 200;
  static const int maxGroup = 50;

  static const _from = 'àáâãäåāăąçćĉċčďđèéêëēĕėęěĝğġģĥħìíîïĩīĭįıĵķĺļľŀłñńņňòóôõöøōŏőŕŗřśŝşšţťŧùúûüũūŭůűųŵýÿŷźżžß';
  static const _to = 'aaaaaaaaacccccddeeeeeeeeegggghhiiiiiiiiijklllllnnnnooooooooorrrssssttt'
      'uuuuuuuuuuwyyyzzzs';
  static final Map<int, String> _fold = _buildFold();

  static Map<int, String> _buildFold() {
    final m = <int, String>{};
    final from = _from.runes.toList();
    final to = _to.runes.toList();
    for (var i = 0; i < from.length && i < to.length; i++) {
      m[from[i]] = String.fromCharCode(to[i]);
    }
    return m;
  }

  /// Length-preserving fold: lower-case, strip diacritics, and turn every
  /// non letter/digit into a space. Because the length never changes, match
  /// offsets in the folded text apply to the original text (for highlights).
  static String fold(String? s) {
    if (s == null || s.isEmpty) return '';
    final b = StringBuffer();
    for (final ch in s.characters16) {
      b.write(_foldChar(ch));
    }
    return b.toString();
  }

  static String _foldChar(String ch) {
    var l = ch.toLowerCase();
    if (l.length != 1) l = ch;
    final mapped = _fold[l.codeUnitAt(0)];
    if (mapped != null) return mapped;
    final c = l.codeUnitAt(0);
    final isAlnum = (c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x7a) ||
        (c >= 0xc0 && !(c >= 0x2000 && c <= 0x206f) && !(c >= 0x3000 && c <= 0x303f));
    return isAlnum ? l : ' ';
  }

  static List<String> tokenize(String query) =>
      fold(query).split(' ').where((t) => t.isNotEmpty).toList();

  /// Builds the index. [playlists] maps playlist name to its song paths.
  static SearchIndex buildIndex(List<SearchInput> inputs, {Map<String, List<String>> playlists = const {}}) {
    final songs = <SearchSong>[];
    final albumMap = <String, List<String>>{};
    final albumArtist = <String, String>{};
    final artistMap = <String, List<String>>{};
    for (final i in inputs) {
      final title = TitleCleaner.title(i.title, path: i.path);
      final artist = TitleCleaner.artist(i.artist) ?? '';
      final album = (i.album ?? '').trim();
      final s = SearchSong._(i.path, title, artist, album, p.basename(i.path), p.basename(p.dirname(i.path)));
      songs.add(s);
      if (album.isNotEmpty) {
        albumMap.putIfAbsent(album, () => []).add(i.path);
        if (artist.isNotEmpty) albumArtist.putIfAbsent(album, () => artist);
      }
      if (artist.isNotEmpty) artistMap.putIfAbsent(artist, () => []).add(i.path);
    }
    return SearchIndex(
      songs,
      [for (final e in albumMap.entries) SearchAlbum(e.key, albumArtist[e.key] ?? '', e.value)],
      [for (final e in artistMap.entries) SearchArtist(e.key, e.value)],
      [for (final e in playlists.entries) SearchPlaylist(e.key, e.value)],
    );
  }

  // Match quality of a single token against one folded field: 0 = none.
  static int _tokenScore(String field, String token, {required bool first}) {
    if (field.isEmpty) return 0;
    if (field.startsWith(token)) return first ? 100 : 80;
    var i = field.indexOf(token);
    if (i < 0) return 0;
    while (i >= 0) {
      if (field.codeUnitAt(i - 1) == 0x20) return 70;
      i = field.indexOf(token, i + 1);
    }
    return 40;
  }

  /// Weighted score for [tokens] against [fields] (field, weight); every token
  /// must match at least one field or the result is 0.
  static double _score(List<String> tokens, List<(String, double)> fields) {
    var total = 0.0;
    for (var t = 0; t < tokens.length; t++) {
      var best = 0.0;
      for (final f in fields) {
        final s = _tokenScore(f.$1, tokens[t], first: t == 0) * f.$2;
        if (s > best) best = s;
      }
      if (best == 0) return 0;
      total += best;
    }
    return total;
  }

  static SearchResults search(SearchIndex index, String query) {
    final tokens = tokenize(query);
    if (tokens.isEmpty) return SearchResults.empty;
    final phrase = tokens.join(' ');

    final songHits = <(SearchSong, double)>[];
    for (final s in index.songs) {
      var sc = _score(tokens, [
        (s._nTitle, 1.0),
        (s._nArtist, 0.8),
        (s._nAlbum, 0.7),
        (s._nFile, 0.5),
        (s._nFolder, 0.3),
      ]);
      if (sc == 0) continue;
      if (tokens.length > 1 && s._nTitle.startsWith(phrase)) sc += 50;
      songHits.add((s, sc));
    }
    songHits.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.title.toLowerCase().compareTo(b.$1.title.toLowerCase());
    });

    List<T> rank<T>(List<T> items, List<(String, double)> Function(T) fields, String Function(T) name, int cap) {
      final hits = <(T, double)>[];
      for (final it in items) {
        final sc = _score(tokens, fields(it));
        if (sc > 0) hits.add((it, sc));
      }
      hits.sort((a, b) {
        final c = b.$2.compareTo(a.$2);
        return c != 0 ? c : name(a.$1).toLowerCase().compareTo(name(b.$1).toLowerCase());
      });
      return [for (final h in hits.take(cap)) h.$1];
    }

    return SearchResults(
      [for (final h in songHits.take(maxSongs)) h.$1],
      rank<SearchAlbum>(index.albums, (a) => [(fold(a.name), 1.0), (fold(a.artist), 0.6)], (a) => a.name, maxGroup),
      rank<SearchArtist>(index.artists, (a) => [(fold(a.name), 1.0)], (a) => a.name, maxGroup),
      rank<SearchPlaylist>(index.playlists, (a) => [(fold(a.name), 1.0)], (a) => a.name, maxGroup),
    );
  }

  /// Ranges of [original] to highlight for [tokens] (already folded). Prefers
  /// a word-start occurrence of each token, else the first substring hit.
  static List<(int, int)> highlightRanges(String original, List<String> tokens) {
    final f = fold(original);
    final ranges = <(int, int)>[];
    for (final t in tokens) {
      var at = -1;
      var i = f.indexOf(t);
      while (i >= 0) {
        if (i == 0 || f.codeUnitAt(i - 1) == 0x20) {
          at = i;
          break;
        }
        if (at < 0) at = i;
        i = f.indexOf(t, i + 1);
      }
      if (at >= 0) ranges.add((at, at + t.length));
    }
    ranges.sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final r in ranges) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2) {
        if (r.$2 > merged.last.$2) merged[merged.length - 1] = (merged.last.$1, r.$2);
      } else {
        merged.add(r);
      }
    }
    return merged;
  }
}

extension on String {
  // Iterates UTF-16 units as 1-char strings so fold stays length-preserving.
  Iterable<String> get characters16 sync* {
    for (var i = 0; i < length; i++) {
      yield this[i];
    }
  }
}
