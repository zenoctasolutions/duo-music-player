// lib/albums_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music/player_screen.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'list_page.dart';
import 'songs_page.dart' show GlobalMiniPlayer; // Import GlobalMiniPlayer
import 'banner_ad_widget2.dart';
import 'ad_widgets.dart';
import 'library/title_cleaner.dart';
import 'library/library_motion.dart';
import 'library/widgets/library_widgets.dart';
import 'motion/motion_kit.dart';
import 'player/art_colors.dart';
import 'ui/app_page_bar.dart';
import 'library/queue_menu.dart';


/// Display-only: drops a trailing "(2012)" / " - (2012)" from an album title
/// when the year is shown elsewhere. Never used for grouping keys.
String stripTrailingYear(String title, {required bool yearShownElsewhere}) {
  if (!yearShownElsewhere) return title;
  final out = title.replaceFirst(RegExp(r'\s*(?:[-\u2013]\s*)?\(\s*(?:19|20)\d{2}\s*\)\s*$'), '').trim();
  return out.isEmpty ? title : out;
}

class SongMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? coverArt;
  final int? year;
  final Duration? duration;

  SongMetadata({this.title, this.artist, this.album, this.coverArt, this.year, this.duration});

  bool get hasMetadata =>
      (title != null && title!.isNotEmpty) ||
          (artist != null && artist!.isNotEmpty) ||
          (album != null && album!.isNotEmpty);
}

/// Simple singleton navigator so mini-player / full-screen player can call next/prev.
class AlbumNavigator {
  static _AlbumsPageState? _state;
  static void _register(_AlbumsPageState s) => _state = s;
  static void _unregister(_AlbumsPageState s) {
    if (_state == s) _state = null;
  }

  static void next() => _state?._playNextInGroup();
  static void previous() => _state?._playPreviousInGroup();

  /// Optional helper — let an external controller tell AlbumsPage what is currently playing.
  static void notifyPlayingIndex(int index) =>
      _state?._externalNotifyPlayingIndex(index);
}

class AlbumsPage extends StatefulWidget {
  final List<FileSystemEntity> audioFiles;
  final Function(String path, int index)? onPlay;
  final int? currentPlayingIndex;
  final Widget? miniPlayer;
  final bool isDarkMode;
  final AudioPlayer? audioPlayer; // Added to receive the global AudioPlayer

  const AlbumsPage({
    super.key,
    required this.audioFiles,
    this.onPlay,
    this.currentPlayingIndex,
    this.miniPlayer,
    required this.isDarkMode,
    this.audioPlayer,
  });

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  final Map<String, SongMetadata> _metadataCache = {};

  // Grouped by Album Name
  late Map<String, List<FileSystemEntity>> _byAlbum;
  Map<String, List<FileSystemEntity>>? _displayByAlbum;

  late List<FileSystemEntity> _allFiles;

  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  bool _searchActive = false;

  static const String _kViewPref = 'albums_grid_view';
  bool _grid = true;
  bool _metaLoaded = false;

  // Active group (Album name) + index inside that group.
  String? _activeGroupKey;
  int? _activeIndexInGroup;

  @override
  void initState() {
    super.initState();
    _allFiles = widget.audioFiles;
    _prepareAlbums();
    _preloadMetadata();
    LibViewPref.loadGrid(_kViewPref).then((g) {
      if (mounted && g != _grid) setState(() => _grid = g);
    });

    _searchController.addListener(() {
      _onSearchChanged(_searchController.text);
    });

    AlbumNavigator._register(this);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _syncActiveFromPlayingIndex());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    AlbumNavigator._unregister(this);
    super.dispose();
  }

  void _externalNotifyPlayingIndex(int index) {
    if (!mounted) return;
    if (index >= 0 && index < widget.audioFiles.length) {
      _syncActiveFromPlayingIndex(explicitIndex: index);
    }
  }

  @override
  void didUpdateWidget(covariant AlbumsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPlayingIndex != oldWidget.currentPlayingIndex) {
      _syncActiveFromPlayingIndex();
    }
    if (!identical(widget.audioFiles, oldWidget.audioFiles)) {
      _allFiles = widget.audioFiles;
      _prepareAlbums();
      _preloadMetadata();
    }
  }

  void _prepareAlbums() {
    final map = <String, List<FileSystemEntity>>{};

    for (var file in _allFiles) {
      final meta = _metadataCache[file.path];
      String albumName = meta?.album?.trim() ?? "Unknown Album";
      if (albumName.isEmpty) albumName = "Unknown Album";
      map.putIfAbsent(albumName, () => []).add(file);
    }

    final albums = map.keys.toList();
    albums.sort((a, b) {
      if (a == "Unknown Album") return 1;
      if (b == "Unknown Album") return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });

    _byAlbum = {for (var album in albums) album: map[album]!};
    _displayByAlbum = Map.from(_byAlbum);
    if (mounted) setState(() {});
  }

  Future<void> _preloadMetadata() async {
    var n = 0;
    for (var f in _allFiles) {
      if (!_metadataCache.containsKey(f.path)) {
        // readMetadata is synchronous; yield so the skeleton keeps animating.
        if (++n % 8 == 0) await Future<void>.delayed(Duration.zero);
        final meta = await _loadMetadata(f.path);
        if (!mounted) return;
        _metadataCache[f.path] = meta;
      }
    }
    if (!mounted) return;
    _metaLoaded = true;
    _prepareAlbums();
    _syncActiveFromPlayingIndex();
  }

  Future<SongMetadata> _loadMetadata(String path) async {
    try {
      final file = File(path);
      final data = await readMetadata(file, getImage: true);
      Uint8List? art;
      if (data.pictures?.isNotEmpty == true) {
        dynamic raw;
        try {
          raw = (data.pictures!.first as dynamic).bytes;
        } catch (_) {
          raw = null;
        }
        if (raw is Uint8List) art = raw;
      }
      return SongMetadata(
        title: data.title,
        artist: data.artist,
        album: data.album,
        coverArt: art,
        year: data.year?.year,
        duration: data.duration,
      );
    } catch (_) {
      return SongMetadata();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() => _query = value.trim());
      _applySearch();
    });
  }

  void _applySearch() {
    if (_query.isEmpty) {
      _displayByAlbum = Map.from(_byAlbum);
      setState(() {});
      return;
    }

    final q = _query.toLowerCase();
    final result = <String, List<FileSystemEntity>>{};

    for (final file in _allFiles) {
      final meta = _metadataCache[file.path];
      final name = p.basenameWithoutExtension(file.path).toLowerCase();
      final artist = meta?.artist?.toLowerCase() ?? '';
      final album = meta?.album?.toLowerCase() ?? '';
      final title = meta?.title?.toLowerCase() ?? '';

      if ([name, artist, album, title].any((v) => v.contains(q))) {
        String albumKey = meta?.album?.trim() ?? "Unknown Album";
        if (albumKey.isEmpty) albumKey = "Unknown Album";
        result.putIfAbsent(albumKey, () => []).add(file);
      }
    }

    final keys = result.keys.toList();
    keys.sort((a, b) {
      if (a == "Unknown Album") return 1;
      if (b == "Unknown Album") return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });

    _displayByAlbum = {for (var k in keys) k: result[k]!};
    setState(() {});
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchController.clear();
        _query = '';
        _applySearch();
      }
    });
  }

  Future<void> _markRecentlyPlayed(String path) async {
    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }
  }

  // --- Logic Helpers ---

  void _syncActiveFromPlayingIndex({int? explicitIndex}) {
    final curIdx = explicitIndex ?? widget.currentPlayingIndex;
    if (curIdx == null || curIdx < 0 || curIdx >= widget.audioFiles.length) {
      return;
    }
    final curPath = widget.audioFiles[curIdx].path;
    final map = _displayByAlbum ?? _byAlbum;

    for (final entry in map.entries) {
      final list = entry.value;
      final idx = list.indexWhere((f) => f.path == curPath);
      if (idx != -1) {
        setState(() {
          _activeGroupKey = entry.key;
          _activeIndexInGroup = idx;
        });
        return;
      }
    }
    setState(() {
      _activeGroupKey = null;
      _activeIndexInGroup = null;
    });
  }

  String? _nextGroupKey(String current) {
    final keys = (_displayByAlbum ?? _byAlbum).keys.toList();
    final pos = keys.indexOf(current);
    if (pos == -1) return null;
    for (int i = pos + 1; i < keys.length; i++) {
      final list = (_displayByAlbum ?? _byAlbum)[keys[i]];
      if (list != null && list.isNotEmpty) return keys[i];
    }
    return null;
  }

  String? _previousGroupKey(String current) {
    final keys = (_displayByAlbum ?? _byAlbum).keys.toList();
    final pos = keys.indexOf(current);
    if (pos == -1) return null;
    for (int i = pos - 1; i >= 0; i--) {
      final list = (_displayByAlbum ?? _byAlbum)[keys[i]];
      if (list != null && list.isNotEmpty) return keys[i];
    }
    return null;
  }

  Future<void> _playNextInGroup() async {
    final map = _displayByAlbum ?? _byAlbum;
    if (map.isEmpty) return;

    if (_activeGroupKey == null) {
      _syncActiveFromPlayingIndex();
      if (_activeGroupKey == null) return;
    }

    final list = map[_activeGroupKey!] ?? [];
    if (list.isEmpty) return;

    int next = (_activeIndexInGroup ?? -1) + 1;

    if (next < list.length) {
      final file = list[next];
      final globalIndex = widget.audioFiles.indexWhere((x) => x.path == file.path);
      if (globalIndex != -1) {
        await _markRecentlyPlayed(file.path);
        widget.onPlay?.call(file.path, globalIndex);
        setState(() => _activeIndexInGroup = next);
      }
      return;
    }

    // end of group -> move to next group
    final nextGroup = _nextGroupKey(_activeGroupKey!);
    if (nextGroup != null) {
      final nextList = map[nextGroup]!;
      if (nextList.isNotEmpty) {
        final file = nextList.first;
        final globalIndex = widget.audioFiles.indexWhere((x) => x.path == file.path);
        if (globalIndex != -1) {
          await _markRecentlyPlayed(file.path);
          widget.onPlay?.call(file.path, globalIndex);
          setState(() {
            _activeGroupKey = nextGroup;
            _activeIndexInGroup = 0;
          });
        }
      }
    }
  }

  Future<void> _playPreviousInGroup() async {
    final map = _displayByAlbum ?? _byAlbum;
    if (map.isEmpty) return;

    if (_activeGroupKey == null) {
      _syncActiveFromPlayingIndex();
      if (_activeGroupKey == null) return;
    }

    final list = map[_activeGroupKey!] ?? [];
    if (list.isEmpty) return;

    int prev = (_activeIndexInGroup ?? 0) - 1;

    if (prev >= 0) {
      final file = list[prev];
      final globalIndex = widget.audioFiles.indexWhere((x) => x.path == file.path);
      if (globalIndex != -1) {
        await _markRecentlyPlayed(file.path);
        widget.onPlay?.call(file.path, globalIndex);
        setState(() => _activeIndexInGroup = prev);
      }
      return;
    }

    final prevGroup = _previousGroupKey(_activeGroupKey!);
    if (prevGroup != null) {
      final prevList = map[prevGroup]!;
      if (prevList.isNotEmpty) {
        final file = prevList.last;
        final globalIndex = widget.audioFiles.indexWhere((x) => x.path == file.path);
        if (globalIndex != -1) {
          await _markRecentlyPlayed(file.path);
          widget.onPlay?.call(file.path, globalIndex);
          setState(() {
            _activeGroupKey = prevGroup;
            _activeIndexInGroup = prevList.length - 1;
          });
        }
      }
    }
  }

  // --- UI Components ---

  int? _albumYear(List<FileSystemEntity> songs) {
    for (final s in songs) {
      final y = _metadataCache[s.path]?.year;
      if (y != null && y > 0) return y;
    }
    return null;
  }

  Uint8List? _albumCover(List<FileSystemEntity> songs) {
    for (final s in songs) {
      final c = _metadataCache[s.path]?.coverArt;
      if (c != null && c.isNotEmpty) return c;
    }
    return null;
  }

  String _albumMeta(List<FileSystemEntity> songs, {bool withArtist = true}) {
    final firstMeta = songs.isNotEmpty ? _metadataCache[songs.first.path] : null;
    final artist = TitleCleaner.artistOrUnknown(firstMeta?.artist);
    final year = _albumYear(songs);
    final n = songs.length;
    return [
      if (withArtist) artist,
      if (year != null) '$year',
      '$n ${n == 1 ? 'song' : 'songs'}',
    ].join(' · ');
  }

  void _openAlbum(String albumName, List<FileSystemEntity> songs) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AlbumDetailPage(
          albumName: albumName,
          songs: songs,
          metadataCache: _metadataCache,
          isDarkMode: widget.isDarkMode,
          audioPlayer: widget.audioPlayer,
          onPlay: (path, idx) async {
            final globalIdx = widget.audioFiles.indexWhere((f) => f.path == path);
            if (globalIdx != -1) {
              setState(() {
                _activeGroupKey = albumName;
                _activeIndexInGroup = idx;
              });
              await _markRecentlyPlayed(path);
              widget.onPlay?.call(path, globalIdx);
            }
          },
          miniPlayer: widget.miniPlayer,
        ),
      ),
    );
  }

  Widget _albumGridTile(String albumName, List<FileSystemEntity> songs, LibColors c, double tileW, int index) {
    final title = stripTrailingYear(TitleCleaner.title(albumName), yearShownElsewhere: _albumYear(songs) != null);
    final cover = _albumCover(songs);
    final meta = _albumMeta(songs);
    final px = (tileW * MediaQuery.devicePixelRatioOf(context)).round().clamp(120, 700);
    return StaggerIn(
      playKey: 'albums:$albumName',
      index: index,
      child: Semantics(
        button: true,
        label: 'Album $title, $meta',
        excludeSemantics: true,
        onTap: () => _openAlbum(albumName, songs),
        child: PressScale(
          onTap: () => _openAlbum(albumName, songs),
          pressedScale: 0.965,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1,
                child: LibCover(
                  bytes: cover,
                  seed: albumName,
                  radius: 22,
                  cacheSize: px,
                  shadow: true,
                  icon: Icons.album_rounded,
                ),
              ),
              const SizedBox(height: 10),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.sub, fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _albumListRow(String albumName, List<FileSystemEntity> songs, LibColors c, int index) {
    final title = stripTrailingYear(TitleCleaner.title(albumName), yearShownElsewhere: _albumYear(songs) != null);
    final meta = _albumMeta(songs);
    final px = (60 * MediaQuery.devicePixelRatioOf(context)).round();
    return StaggerIn(
      playKey: 'albums:$albumName',
      index: index,
      child: Semantics(
        button: true,
        label: 'Album $title, $meta',
        excludeSemantics: true,
        onTap: () => _openAlbum(albumName, songs),
        child: PressScale(
          passive: true,
          child: InkWell(
            onTap: () => _openAlbum(albumName, songs),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    LibCover(
                        bytes: _albumCover(songs),
                        seed: albumName,
                        size: 60,
                        radius: 14,
                        cacheSize: px,
                        icon: Icons.album_rounded),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.text, fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.sub, fontSize: 13)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right_rounded, color: c.sub),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(LibColors c, Map<String, List<FileSystemEntity>> map) {
    if (!_metaLoaded) return LibSkeleton(grid: _grid, colors: c);
    if (map.isEmpty) {
      return LibEmptyState(
        icon: _query.isEmpty ? Icons.album_rounded : Icons.search_off_rounded,
        title: _query.isEmpty ? 'No albums found' : 'No matches',
        message: _query.isEmpty ? 'Add some music and your albums will show up here.' : 'Nothing matches "$_query".',
        colors: c,
      );
    }
    final entries = map.entries.toList(growable: false);
    final songTotal = entries.fold<int>(0, (s, e) => s + e.value.length);
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Text(
          '${entries.length} ${entries.length == 1 ? 'album' : 'albums'} · $songTotal songs',
          style: TextStyle(color: c.sub, fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    );
    return LayoutBuilder(builder: (context, cons) {
      final tileW = (cons.maxWidth - 32 - 16) / 2;
      return CustomScrollView(
        key: PageStorageKey<String>('albums-${_grid ? 'g' : 'l'}'),
        slivers: [
          header,
          if (_grid)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 18,
                  crossAxisSpacing: 16,
                  mainAxisExtent: tileW + 74,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _albumGridTile(entries[i].key, entries[i].value, c, tileW, i),
                  childCount: entries.length,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _albumListRow(entries[i].key, entries[i].value, c, i),
                childCount: entries.length,
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
        ],
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final map = _displayByAlbum ?? {};
    final c = LibColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppPageBar(
        title: 'Albums',
        backgroundColor: c.bg,
        foregroundColor: c.text,
        actions: [
          ViewToggleButton(
            grid: _grid,
            color: c.text,
            onPressed: () {
              setState(() => _grid = !_grid);
              LibViewPref.saveGrid(_kViewPref, _grid);
            },
          ),
          IconButton(
            tooltip: _searchActive ? 'Close search' : 'Search albums',
            icon: Icon(_searchActive ? Icons.close_rounded : Icons.search_rounded, color: c.text),
            onPressed: _toggleSearch,
          ),
        ],
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
        ],
      ),
      body: Column(
        children: [
          AnimatedSize(
            duration: Motion.of(context, Motion.fast),
            curve: Motion.standard,
            alignment: Alignment.topCenter,
            child: _searchActive
                ? LibSearchField(controller: _searchController, hint: 'Search albums', colors: c)
                : const SizedBox(width: double.infinity),
          ),
          Expanded(child: _body(c, map)),
          const BannerAdWidget2(),
        ],
      ),
    );
  }
}

/// A dedicated page for displaying songs within an album.
class AlbumDetailPage extends StatefulWidget {
  final String albumName;
  final List<FileSystemEntity> songs;
  final Map<String, SongMetadata> metadataCache;
  final bool isDarkMode;
  final Function(String path, int localIndex) onPlay;
  final Widget? miniPlayer;
  final AudioPlayer? audioPlayer;

  const AlbumDetailPage({
    super.key,
    required this.albumName,
    required this.songs,
    required this.metadataCache,
    required this.isDarkMode,
    required this.onPlay,
    this.miniPlayer,
    this.audioPlayer,
  });

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  Future<void> _markRecentlyPlayed(String path) async {
    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }
  }

  /// Plays [files] (default: the album in order) from [startIndex] using the
  /// GLOBAL AudioPlayer, so playback is isolated to this album.
  Future<void> _openFullScreenForAlbum({required int startIndex, List<FileSystemEntity>? files}) async {
    final list = files ?? widget.songs;
    if (list.isEmpty || startIndex < 0 || startIndex >= list.length) return;
    final albumFiles = list.map((fs) => File(fs.path)).toList();

    try {
      final paths = albumFiles.map((f) => f.path).toList();
      try {
        PlaylistContext.setCurrentPlaylist(paths, pageId: widget.albumName);
        await PlaylistService.saveQueue(paths);
      } catch (_) {}

      final player = widget.audioPlayer;

      if (player != null) {
        final audioSources = albumFiles.map((f) {
          return AudioSource.uri(
            Uri.file(f.path),
            tag: <String, dynamic>{'filePath': f.path, 'id': f.path},
          );
        }).toList();

        final playlistSource = ConcatenatingAudioSource(children: audioSources);

        final startPath = albumFiles[startIndex].path;
        await _markRecentlyPlayed(startPath);

        await player.setAudioSource(playlistSource, initialIndex: startIndex);
        await player.play();
      } else {
        await _markRecentlyPlayed(albumFiles[startIndex].path);
        widget.onPlay(albumFiles[startIndex].path, startIndex);
      }
    } catch (e) {
      debugPrint('Open full screen album error: $e');
    }
  }

  Future<void> _shuffleAlbum() async {
    if (widget.songs.isEmpty) return;
    final shuffled = List<FileSystemEntity>.of(widget.songs)..shuffle(Random());
    HapticFeedback.selectionClick();
    await _openFullScreenForAlbum(startIndex: 0, files: shuffled);
  }

  static const double _heroHeight = 330;

  @override
  Widget build(BuildContext context) {
    final c = LibColors.of(context);

    final firstMeta = widget.songs.isNotEmpty ? widget.metadataCache[widget.songs.first.path] : null;
    final artist = TitleCleaner.artistOrUnknown(firstMeta?.artist);
    Uint8List? cover;
    int? year;
    var total = Duration.zero;
    for (final s in widget.songs) {
      final m = widget.metadataCache[s.path];
      if (cover == null && m?.coverArt != null && m!.coverArt!.isNotEmpty) cover = m.coverArt;
      if (year == null && m?.year != null && m!.year! > 0) year = m.year;
      total += m?.duration ?? Duration.zero;
    }
    final cleanAlbum = stripTrailingYear(TitleCleaner.title(widget.albumName), yearShownElsewhere: year != null);
    final n = widget.songs.length;
    final meta = [
      if (year != null) '$year',
      '$n ${n == 1 ? 'song' : 'songs'}',
      if (total.inSeconds > 0) formatDuration(total, words: true),
    ].join(' · ');

    return Scaffold(
      backgroundColor: c.bg,
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      body: ArtTint(
        bytes: cover,
        builder: (context, base) {
          final accent = base != null ? ArtColors.accent(base, dark: c.dark, fallback: c.accent) : c.accent;
          final cc = LibColors.of(context);
          return Stack(
            children: [
              HeroGradient(base: base, colors: cc, height: 560),
              CustomScrollView(
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    expandedHeight: _heroHeight,
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    foregroundColor: c.text,
                    actions: [
                      if (widget.songs.isNotEmpty)
                        QueueMenuButton(paths: widget.songs.map((s) => s.path).toList(), color: c.text),
                    ],
                    flexibleSpace: LayoutBuilder(builder: (context, cons) {
                      final top = MediaQuery.paddingOf(context).top;
                      final maxH = _heroHeight + top;
                      final minH = kToolbarHeight + top;
                      final t = ((cons.maxHeight - minH) / (maxH - minH)).clamp(0.0, 1.0);
                      final px = (240 * MediaQuery.devicePixelRatioOf(context)).round();
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          ColoredBox(color: c.bg.withValues(alpha: (1 - t) * (1 - t))),
                          Padding(
                            padding: EdgeInsets.only(top: top + kToolbarHeight, bottom: 12),
                            child: Center(
                              child: Opacity(
                                opacity: t,
                                child: Transform.scale(
                                  scale: 0.8 + 0.2 * t,
                                  child: Semantics(
                                    label: 'Album art',
                                    image: true,
                                    child: LibCover(
                                      bytes: cover,
                                      seed: widget.albumName,
                                      size: 240,
                                      radius: 22,
                                      cacheSize: px,
                                      shadow: true,
                                      icon: Icons.album_rounded,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 64,
                            right: 64,
                            top: top,
                            height: kToolbarHeight,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Opacity(
                                opacity: ((0.35 - t) / 0.35).clamp(0.0, 1.0),
                                child: Text(cleanAlbum,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(cleanAlbum,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: c.text, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.1)),
                          const SizedBox(height: 6),
                          Text(artist,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: accent, fontSize: 16, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(meta, style: TextStyle(color: c.sub, fontSize: 13.5)),
                          const SizedBox(height: 18),
                          PlayShuffleRow(
                            colors: cc,
                            onPlay: widget.songs.isEmpty ? null : () => _openFullScreenForAlbum(startIndex: 0),
                            onShuffle: widget.songs.isEmpty ? null : _shuffleAlbum,
                          ),
                          const SizedBox(height: 10),
                        ],
                      ),
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _trackRow(context, c, accent, artist, index),
                      childCount: widget.songs.length,
                    ),
                  ),
                  const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _trackRow(BuildContext context, LibColors c, Color accent, String albumArtist, int index) {
    final song = widget.songs[index];
    final meta = widget.metadataCache[song.path];
    final songTitle = TitleCleaner.title(meta?.title, path: song.path);
    final songArtist = TitleCleaner.artistOrUnknown(meta?.artist);
    final showArtist = songArtist != albumArtist;
    final dur = meta?.duration;

    return StaggerIn(
      playKey: 'albumdetail:${song.path}',
      index: index,
      child: ValueListenableBuilder<String?>(
        valueListenable: PlaylistContext.currentPathNotifier,
        builder: (context, contextPath, _) {
          return StreamBuilder<SequenceState?>(
            stream: widget.audioPlayer?.sequenceStateStream,
            builder: (context, snapshot) {
              String? playingPath;
              if (snapshot.hasData) {
                final tag = snapshot.data?.currentSource?.tag;
                if (tag is Map) playingPath = tag['filePath'] as String?;
              }
              playingPath ??= contextPath;
              final isPlaying = playingPath != null && playingPath == song.path;

              return Semantics(
                button: true,
                selected: isPlaying,
                label: '${index + 1}. $songTitle${showArtist ? ', $songArtist' : ''}'
                    '${dur != null ? ', ${formatDuration(dur)}' : ''}${isPlaying ? ', now playing' : ''}',
                excludeSemantics: true,
                onTap: () => _openFullScreenForAlbum(startIndex: index),
                child: InkWell(
                  onTap: () async {
                    HapticFeedback.selectionClick();
                    await _markRecentlyPlayed(song.path);
                    await _openFullScreenForAlbum(startIndex: index);
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 60),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 20, right: 4, top: 6, bottom: 6),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 32,
                            child: isPlaying
                                ? Align(
                                    alignment: Alignment.centerLeft,
                                    child: EqualizerBars(color: accent, playing: true, size: 18))
                                : Text('${index + 1}',
                                    style: TextStyle(color: c.sub, fontSize: 14, fontWeight: FontWeight.w600)),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(songTitle,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isPlaying ? accent : c.text,
                                      fontSize: 16,
                                      fontWeight: isPlaying ? FontWeight.w700 : FontWeight.w500,
                                    )),
                                if (showArtist) ...[
                                  const SizedBox(height: 2),
                                  Text(songArtist,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: c.sub, fontSize: 13)),
                                ],
                              ],
                            ),
                          ),
                          if (dur != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(formatDuration(dur), style: TextStyle(color: c.sub, fontSize: 13)),
                            ),
                          QueueMenuButton(paths: [song.path], color: c.sub),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
