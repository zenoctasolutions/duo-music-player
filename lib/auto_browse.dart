// lib/auto_browse.dart
//
// Android Auto (and other MediaBrowser clients — Wear OS, Assistant) browse
// tree. audio_service already exposes the app as a MediaBrowserService; the
// AudioHandler in songs_page.dart forwards getChildren / playFromMediaId /
// search here. Pure logic over an [AutoLibrary] snapshot so it's unit-tested.
//
// Tree:
//   root
//   ├─ Recently played    (also served for Auto's "recent" root)
//   ├─ Favorites
//   ├─ Most played
//   ├─ Recently added
//   ├─ Playlists ─ <each playlist>
//   └─ All songs
//
// Song ids are "song|<category>|<path>" so playing one queues the rest of
// that category, the way tapping a song inside a list does in the app.

import 'package:audio_service/audio_service.dart';

class AutoLibrary {
  final List<String> allPaths;
  final String Function(String path) title;
  final String? Function(String path) artist;
  final Set<String> favorites;
  final List<String> recent;
  final List<String> mostPlayed;
  final List<String> recentlyAdded;
  final Map<String, List<String>> playlists;

  const AutoLibrary({
    required this.allPaths,
    required this.title,
    required this.artist,
    this.favorites = const {},
    this.recent = const [],
    this.mostPlayed = const [],
    this.recentlyAdded = const [],
    this.playlists = const {},
  });
}

class AutoBrowse {
  AutoBrowse._();

  static const catRecent = 'cat:recent';
  static const catFavorites = 'cat:favorites';
  static const catMost = 'cat:most';
  static const catAdded = 'cat:added';
  static const catPlaylists = 'cat:playlists';
  static const catAll = 'cat:all';
  static const _playlistPrefix = 'pl:';

  /// Auto limits list sizes; very long lists are capped.
  static const int maxItems = 400;

  static MediaItem _folder(String id, String title, {String? subtitle}) =>
      MediaItem(id: id, title: title, displaySubtitle: subtitle, playable: false);

  static MediaItem _song(AutoLibrary lib, String category, String path) => MediaItem(
        id: 'song|$category|$path',
        title: lib.title(path),
        artist: lib.artist(path),
        playable: true,
        extras: {'path': path},
      );

  /// Paths shown under [category] (a cat:* id or a playlist id).
  static List<String> pathsFor(String category, AutoLibrary lib) {
    final existing = lib.allPaths.toSet();
    List<String> keep(Iterable<String> ps) => ps.where(existing.contains).toList();
    switch (category) {
      case catRecent:
        return keep(lib.recent);
      case catFavorites:
        return lib.allPaths.where(lib.favorites.contains).toList();
      case catMost:
        return keep(lib.mostPlayed);
      case catAdded:
        return keep(lib.recentlyAdded);
      case catAll:
        return List.of(lib.allPaths);
    }
    if (category.startsWith(_playlistPrefix)) {
      return keep(lib.playlists[category.substring(_playlistPrefix.length)] ?? const []);
    }
    return const [];
  }

  static List<MediaItem> children(String parentId, AutoLibrary lib) {
    if (parentId == AudioService.browsableRootId) {
      return [
        _folder(catRecent, 'Recently played'),
        _folder(catFavorites, 'Favorites'),
        _folder(catMost, 'Most played'),
        _folder(catAdded, 'Recently added'),
        _folder(catPlaylists, 'Playlists'),
        _folder(catAll, 'All songs', subtitle: '${lib.allPaths.length} songs'),
      ];
    }
    if (parentId == AudioService.recentRootId) {
      return pathsFor(catRecent, lib).take(10).map((p) => _song(lib, catRecent, p)).toList();
    }
    if (parentId == catPlaylists) {
      final names = lib.playlists.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return [
        for (final n in names)
          _folder('$_playlistPrefix$n', n, subtitle: '${pathsFor('$_playlistPrefix$n', lib).length} songs'),
      ];
    }
    return pathsFor(parentId, lib).take(maxItems).map((p) => _song(lib, parentId, p)).toList();
  }

  /// Queue + start index for a tapped song id, or null if unknown.
  static (List<String>, int)? resolvePlay(String mediaId, AutoLibrary lib) {
    final parts = mediaId.split('|');
    if (parts.length < 3 || parts.first != 'song') return null;
    final category = parts[1];
    final path = parts.sublist(2).join('|');
    var queue = pathsFor(category, lib);
    var index = queue.indexOf(path);
    if (index < 0) {
      if (!lib.allPaths.contains(path)) return null;
      queue = [path];
      index = 0;
    }
    return (queue, index);
  }

  /// Voice/text search ("play <song> on Duo Music Player"): title matches
  /// first, then artist matches. An empty query means "just play music".
  static List<String> search(String query, AutoLibrary lib) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      final recent = pathsFor(catRecent, lib);
      return recent.isNotEmpty ? recent : List.of(lib.allPaths);
    }
    final byTitle = <String>[];
    final byArtist = <String>[];
    for (final p in lib.allPaths) {
      if (lib.title(p).toLowerCase().contains(q)) {
        byTitle.add(p);
      } else if ((lib.artist(p) ?? '').toLowerCase().contains(q)) {
        byArtist.add(p);
      }
    }
    return [...byTitle, ...byArtist];
  }

  static List<MediaItem> searchItems(String query, AutoLibrary lib) =>
      search(query, lib).take(50).map((p) => _song(lib, catAll, p)).toList();
}
