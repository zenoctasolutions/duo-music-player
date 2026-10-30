// lib/artists_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:music/list_page.dart';
import 'package:music/player_screen.dart';
import 'package:path/path.dart' as p;
import 'ad_widgets.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'library/title_cleaner.dart';
import 'library/library_motion.dart';
import 'library/widgets/library_widgets.dart';
import 'motion/motion_kit.dart';
import 'player/art_colors.dart';
import 'ui/app_page_bar.dart';
import 'library/queue_menu.dart';

// Helper to check system/app theme brightness
bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// Song data model
class Song {
  final String title;
  final String artist;
  final String album;
  final String filePath;
  final String? duration;
  final Uint8List? coverArt;
  final String folderPath;

  Song({
    required this.title,
    required this.artist,
    required this.album,
    required this.filePath,
    this.duration,
    this.coverArt,
    required this.folderPath,
  });

  @override
  String toString() {
    return 'Song(title: $title, artist: $artist, album: $album, folder: $folderPath)';
  }
}

/// Artist data model - groups by metadata artist but preserves folder information
class Artist {
  final String name;
  final Map<String, List<Song>> songsByFolder;
  final Uint8List? coverImage;

  Artist({
    required this.name,
    required this.songsByFolder,
    this.coverImage,
  });

  List<Song> get allSongs {
    return songsByFolder.values.expand((songs) => songs).toList();
  }

  int get songCount => allSongs.length;
  int get folderCount => songsByFolder.length;

  int get albumCount {
    final albums = allSongs.map((song) => song.album).toSet();
    return albums.length;
  }

  @override
  String toString() {
    return 'Artist(name: $name, songs: $songCount, folders: $folderCount, albums: $albumCount)';
  }
}

class ArtistsPage extends StatefulWidget {
  final List<FileSystemEntity> audioFiles;
  final void Function(String path, int index)? onPlay;
  final ThemeNotifier? themeNotifier;

  const ArtistsPage({
    Key? key,
    required this.audioFiles,
    this.onPlay,
    this.themeNotifier,
  }) : super(key: key);

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  static const String _kViewPref = 'artists_grid_view';
  bool _grid = true;
  bool _searchActive = false;
  String _query = '';
  final TextEditingController _searchController = TextEditingController();

  static const _supportedExtensions = [
    '.mp3',
    '.m4a',
    '.flac',
    '.wav',
    '.aac',
    '.ogg',
    '.opus',
    '.mp4',
    '.m4b',
    '.aiff',
    '.aif'
  ];

  bool _isLoading = true;
  List<Artist> _artists = [];
  String _loadingProgress = 'Initializing...';

  final Map<String, Song> _tempSongCache = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      final q = _searchController.text.trim().toLowerCase();
      if (q != _query && mounted) setState(() => _query = q);
    });
    LibViewPref.loadGrid(_kViewPref).then((g) {
      if (mounted && g != _grid) setState(() => _grid = g);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadArtistsAndSongs();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _artistFromMetadata(dynamic metadata) {
    try {
      final artist = TitleCleaner.artist(metadata?.artist?.toString());
      if (artist != null) return artist;
    } catch (_) {}

    try {
      final dynamic md = metadata;
      final alternatives = [
        md.albumArtist,
        md.albumartist,
        md.performer,
        md.author,
        md.band,
        md.composer,
        md.interpret,
      ];

      for (final value in alternatives) {
        final s = TitleCleaner.artist(value?.toString());
        if (s != null) return s;
      }
    } catch (_) {}

    return 'Unknown Artist';
  }

  Future<void> _loadArtistsAndSongs() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _loadingProgress = 'Scanning files...';
      _artists = [];
      _tempSongCache.clear();
    });

    try {
      final audioFiles = widget.audioFiles.where((e) => e is File).cast<File>().where((file) {
        final extension = p.extension(file.path).toLowerCase();
        return _supportedExtensions.contains(extension);
      }).toList();

      if (!mounted) return;
      setState(() => _loadingProgress = 'Found ${audioFiles.length} audio files');

      final List<Song> allSongs = [];
      const int batchSize = 12;

      for (int i = 0; i < audioFiles.length; i += batchSize) {
        if (!mounted) return;
        final end = (i + batchSize > audioFiles.length) ? audioFiles.length : i + batchSize;
        final batch = audioFiles.sublist(i, end);

        setState(() => _loadingProgress = 'Processing $end of ${audioFiles.length} files');

        final batchSongs = await Future.wait(batch.map((f) => _extractSongMetadata(f)));
        final cleaned = batchSongs.where((s) => s != null).cast<Song>().toList();
        allSongs.addAll(cleaned);

        if (mounted) _updateArtistsList(allSongs);
      }

      if (mounted) {
        _updateArtistsList(allSongs);
        setState(() {
          _isLoading = false;
          _loadingProgress = 'Completed';
        });
      }
    } catch (e) {
      debugPrint('Error loading artists: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingProgress = 'Error: $e';
        });
      }
    }
  }

  Future<Song?> _extractSongMetadata(File file) async {
    try {
      final metadata = await readMetadata(file, getImage: true);

      String title = TitleCleaner.title(metadata?.title, path: file.path);
      String artist = _artistFromMetadata(metadata);
      String album = metadata?.album?.trim() ?? '';
      final String folderPath = p.dirname(file.path);

      if (title.isEmpty) {
        title = TitleCleaner.title(null, path: file.path);
      }

      // Do not guess artist from filename.
      // This avoids hero/heroine or movie names being shown as artist names.
      if (artist.isEmpty) {
        artist = 'Unknown Artist';
      }

      if (album.isEmpty) {
        album = p.basename(folderPath);
      }

      Uint8List? coverArt;
      if (metadata?.pictures != null && metadata!.pictures!.isNotEmpty) {
        try {
          final pic = metadata.pictures!.first;
          dynamic raw;
          try {
            raw = (pic as dynamic).bytes ?? (pic as dynamic).buffer ?? (pic as dynamic).data;
          } catch (_) {
            raw = null;
          }
          if (raw is Uint8List) {
            coverArt = raw;
          } else if (raw is List<int>) {
            coverArt = Uint8List.fromList(raw);
          }
        } catch (_) {}
      }

      final song = Song(
        title: title,
        artist: artist,
        album: album,
        filePath: file.path,
        coverArt: coverArt,
        folderPath: folderPath,
        duration: (metadata?.duration != null && metadata!.duration!.inSeconds > 0)
            ? formatDuration(metadata.duration!)
            : null,
      );

      _tempSongCache[file.path] = song;
      return song;
    } catch (e) {
      debugPrint('Error extracting metadata for ${file.path}: $e');
      final fallback = Song(
        title: TitleCleaner.title(null, path: file.path),
        artist: 'Unknown Artist',
        album: p.basename(p.dirname(file.path)),
        filePath: file.path,
        folderPath: p.dirname(file.path),
      );
      _tempSongCache[file.path] = fallback;
      return fallback;
    }
  }

  void _updateArtistsList(List<Song> allSongs) {
    final Map<String, Map<String, List<Song>>> artistsMap = {};

    for (final song in allSongs) {
      final artistName = (song.artist.isEmpty || song.artist.toLowerCase() == 'unknown artist')
          ? 'Unknown Artist'
          : song.artist;

      if (!artistsMap.containsKey(artistName)) {
        artistsMap[artistName] = {};
      }

      final folderPath = song.folderPath;
      artistsMap[artistName]!.putIfAbsent(folderPath, () => []).add(song);
    }

    final List<Artist> artists = [];

    for (final entry in artistsMap.entries) {
      final artistName = entry.key;
      final foldersMap = entry.value;

      for (final folderEntry in foldersMap.entries) {
        folderEntry.value.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      }

      Uint8List? coverImage;
      for (final folderSongs in foldersMap.values) {
        for (final song in folderSongs) {
          if (song.coverArt != null && song.coverArt!.isNotEmpty) {
            coverImage = song.coverArt;
            break;
          }
        }
        if (coverImage != null) break;
      }

      artists.add(Artist(
        name: artistName,
        songsByFolder: foldersMap,
        coverImage: coverImage,
      ));
    }

    artists.sort((a, b) {
      if (a.name == 'Unknown Artist' && b.name != 'Unknown Artist') return 1;
      if (b.name == 'Unknown Artist' && a.name != 'Unknown Artist') return -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    setState(() => _artists = artists);
  }

  void _refreshArtists() {
    setState(() {
      _isLoading = true;
      _artists.clear();
      _loadingProgress = 'Refreshing...';
    });
    _loadArtistsAndSongs();
  }

  void _toggleSearch() {
    setState(() {
      _searchActive = !_searchActive;
      if (!_searchActive) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  List<Artist> get _filtered {
    if (_query.isEmpty) return _artists;
    return _artists.where((a) => a.name.toLowerCase().contains(_query)).toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final c = LibColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppPageBar(
        title: 'Artists',
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
            tooltip: _searchActive ? 'Close search' : 'Search artists',
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
                ? LibSearchField(controller: _searchController, hint: 'Search artists', colors: c)
                : const SizedBox(width: double.infinity),
          ),
          Expanded(
            child: _isLoading
                ? _buildLoadingIndicator(c)
                : _loadingProgress.startsWith('Error')
                    ? LibEmptyState(
                        icon: Icons.error_outline_rounded,
                        title: 'Could not load artists',
                        message: _loadingProgress,
                        colors: c,
                        actionLabel: 'Try again',
                        onAction: _refreshArtists,
                      )
                    : _artists.isEmpty
                        ? LibEmptyState(
                            icon: Icons.people_outline_rounded,
                            title: 'No artists found',
                            message: 'No music files with artist information were found.',
                            colors: c,
                            actionLabel: 'Try again',
                            onAction: _refreshArtists,
                          )
                        : _buildArtistsList(c),
          ),
          const BannerAdWidget(),
        ],
      ),
    );
  }

  Widget _buildLoadingIndicator(LibColors c) {
    return Stack(
      children: [
        LibSkeleton(grid: _grid, circle: true, colors: c),
        Positioned(
          left: 24,
          right: 24,
          bottom: 20,
          child: Semantics(
            liveRegion: true,
            child: Text(_loadingProgress,
                textAlign: TextAlign.center, style: TextStyle(color: c.sub, fontSize: 13)),
          ),
        ),
      ],
    );
  }

  Widget _buildArtistsList(LibColors c) {
    final list = _filtered;
    if (list.isEmpty) {
      return LibEmptyState(
          icon: Icons.search_off_rounded, title: 'No matches', message: 'No artist matches "$_query".', colors: c);
    }
    final songTotal = list.fold<int>(0, (s, a) => s + a.songCount);
    final header = SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Text(
          '${list.length} ${list.length == 1 ? 'artist' : 'artists'} · $songTotal songs',
          style: TextStyle(color: c.sub, fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ),
    );
    return LayoutBuilder(builder: (context, cons) {
      final tileW = (cons.maxWidth - 32 - 16) / 2;
      return CustomScrollView(
        key: PageStorageKey<String>('artists-${_grid ? 'g' : 'l'}'),
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
                  mainAxisExtent: tileW * 0.9 + 78,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _artistGridTile(list[i], c, tileW * 0.9, i),
                  childCount: list.length,
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, i) => _artistListRow(list[i], c, i),
                childCount: list.length,
              ),
            ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 12)),
        ],
      );
    });
  }

  String _artistMeta(Artist a) {
    final al = a.albumCount;
    return '$al ${al == 1 ? 'album' : 'albums'} · ${a.songCount} ${a.songCount == 1 ? 'song' : 'songs'}';
  }

  Widget _artistGridTile(Artist artist, LibColors c, double avatar, int index) {
    final meta = _artistMeta(artist);
    final px = (avatar * MediaQuery.devicePixelRatioOf(context)).round().clamp(120, 600);
    return StaggerIn(
      playKey: 'artists:${artist.name}',
      index: index,
      child: Semantics(
        button: true,
        label: 'Artist ${artist.name}, $meta',
        excludeSemantics: true,
        onTap: () => _navigateToArtistDetail(artist),
        child: PressScale(
          onTap: () => _navigateToArtistDetail(artist),
          pressedScale: 0.96,
          child: Column(
            children: [
              LibCover(
                bytes: artist.coverImage,
                seed: artist.name,
                size: avatar,
                circle: true,
                shadow: true,
                cacheSize: px,
                initial: artist.name == 'Unknown Artist' ? null : artist.name.trim().characters.first.toUpperCase(),
                icon: Icons.person_rounded,
              ),
              const SizedBox(height: 12),
              Text(artist.name,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(meta,
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.sub, fontSize: 12.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _artistListRow(Artist artist, LibColors c, int index) {
    final meta = _artistMeta(artist);
    final px = (60 * MediaQuery.devicePixelRatioOf(context)).round();
    return StaggerIn(
      playKey: 'artists:${artist.name}',
      index: index,
      child: Semantics(
        button: true,
        label: 'Artist ${artist.name}, $meta',
        excludeSemantics: true,
        onTap: () => _navigateToArtistDetail(artist),
        child: PressScale(
          passive: true,
          child: InkWell(
            onTap: () => _navigateToArtistDetail(artist),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    LibCover(
                      bytes: artist.coverImage,
                      seed: artist.name,
                      size: 60,
                      circle: true,
                      cacheSize: px,
                      initial: artist.name == 'Unknown Artist' ? null : artist.name.trim().characters.first.toUpperCase(),
                      icon: Icons.person_rounded,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(artist.name,
                              maxLines: 1,
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

  void _navigateToArtistDetail(Artist artist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ArtistDetailPage(
          artist: artist,
          onPlay: (path, idx) {
            if (widget.onPlay != null) widget.onPlay!(path, idx);
          },
        ),
      ),
    );
  }
}

////////////////////////////////////////////////////////////////////////////////
/// Artist Detail Page
////////////////////////////////////////////////////////////////////////////////

class ArtistDetailPage extends StatefulWidget {
  final Artist artist;
  final void Function(String path, int index)? onPlay;

  const ArtistDetailPage({
    Key? key,
    required this.artist,
    this.onPlay,
  }) : super(key: key);

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  /// Album currently filtering the song list (null = all songs).
  String? _albumFilter;
  late final List<Song> _allSongs;
  late final Map<String, List<Song>> _byAlbum;

  String? _currentPath;
  bool _isPlaying = false;

  late final VoidCallback _playbackListener;
  late final VoidCallback _isPlayingListener;

  List<Song> get _songs => _albumFilter == null ? _allSongs : (_byAlbum[_albumFilter] ?? const <Song>[]);

  String get _pageId => _albumFilter == null
      ? 'artist:${widget.artist.name}'
      : 'artist:${widget.artist.name}:album:${Uri.encodeComponent(_albumFilter!)}';

  @override
  void initState() {
    super.initState();

    _allSongs = widget.artist.allSongs;
    _byAlbum = <String, List<Song>>{};
    for (final s in _allSongs) {
      _byAlbum.putIfAbsent(s.album, () => []).add(s);
    }

    _playbackListener = () {
      if (!mounted) return;
      setState(() => _currentPath = PlaybackState.current.value);
    };

    _isPlayingListener = () {
      if (!mounted) return;
      setState(() => _isPlaying = PlaybackState.isPlaying.value);
    };

    try {
      PlaybackState.current.addListener(_playbackListener);
      PlaybackState.isPlaying.addListener(_isPlayingListener);
    } catch (_) {}

    _currentPath = PlaybackState.current.value;
    _isPlaying = PlaybackState.isPlaying.value;
  }

  @override
  void dispose() {
    try {
      PlaybackState.current.removeListener(_playbackListener);
      PlaybackState.isPlaying.removeListener(_isPlayingListener);
    } catch (_) {}
    super.dispose();
  }

  String _normalizePath(String pth) {
    try {
      return p.normalize(pth).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      return pth.toLowerCase();
    }
  }

  bool _isCurrent(Song s) {
    final cur = _currentPath;
    return cur != null && _normalizePath(s.filePath) == _normalizePath(cur);
  }

  Future<void> _playList(List<Song> list, int index, {String? pageId}) async {
    if (index < 0 || index >= list.length) return;

    final paths = list.map((s) => s.filePath).toList(growable: false);
    final currentPath = paths[index];
    final id = pageId ?? _pageId;

    try {
      try {
        PlaylistContext.setCurrentPlaylist(paths, pageId: id);
      } catch (_) {}

      await PlaybackController.instance.setPlaylist(
        paths,
        startIndex: index,
        play: true,
        pageId: id,
      );

      try {
        PlaylistContext.setCurrentPath(currentPath);
      } catch (_) {}

      if (!mounted) return;
      setState(() {
        _currentPath = currentPath;
        _isPlaying = true;
      });

      widget.onPlay?.call(currentPath, index);
    } catch (e) {
      debugPrint('Error playing song: $e');
    }
  }

  Future<void> _setCurrentPlaylistAndPlay(int index) => _playList(_songs, index);

  Future<void> _playAll() async {
    if (_songs.isEmpty) return;
    await _setCurrentPlaylistAndPlay(0);
  }

  Future<void> _shuffleAll() async {
    if (_songs.isEmpty) return;
    HapticFeedback.selectionClick();
    final shuffled = List<Song>.of(_songs)..shuffle(Random());
    await _playList(shuffled, 0, pageId: '$_pageId:shuffle');
  }

  Future<void> _toggleOrPlayIndex(int index) async {
    final song = _songs[index];
    final isSamePath = _isCurrent(song);
    final isPlayingHere = isSamePath && _isPlaying;

    if (isPlayingHere) {
      try {
        await PlaybackController.instance.pause();
      } catch (e) {
        debugPrint('Pause failed: $e');
      }
    } else if (isSamePath && !_isPlaying) {
      try {
        await PlaybackController.instance.resume();
        widget.onPlay?.call(song.filePath, index);
      } catch (e) {
        debugPrint('Resume failed: $e');
      }
    } else {
      await _setCurrentPlaylistAndPlay(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = LibColors.of(context);
    final artist = widget.artist;
    final songs = _songs;
    final albums = _byAlbum.entries.toList(growable: false);
    final meta = '${albums.length} ${albums.length == 1 ? 'album' : 'albums'} · '
        '${artist.songCount} ${artist.songCount == 1 ? 'song' : 'songs'}';
    final initial = artist.name == 'Unknown Artist' ? null : artist.name.trim().characters.first.toUpperCase();
    final dpr = MediaQuery.devicePixelRatioOf(context);

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
        bytes: artist.coverImage,
        builder: (context, base) {
          final accent = base != null ? ArtColors.accent(base, dark: c.dark, fallback: c.accent) : c.accent;
          return Stack(
            children: [
              HeroGradient(base: base, colors: c, height: 520),
              CustomScrollView(
                slivers: [
                  SliverAppBar(
                    pinned: true,
                    backgroundColor: Colors.transparent,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    scrolledUnderElevation: 0,
                    foregroundColor: c.text,
                    title: Text(artist.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.text, fontSize: 18, fontWeight: FontWeight.w700)),
                    actions: [
                      if (_allSongs.isNotEmpty)
                        QueueMenuButton(paths: _allSongs.map((s) => s.filePath).toList(), color: c.text),
                    ],
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Column(
                        children: [
                          Semantics(
                            image: true,
                            label: 'Artist image',
                            child: LibCover(
                              bytes: artist.coverImage,
                              seed: artist.name,
                              size: 168,
                              circle: true,
                              shadow: true,
                              cacheSize: (168 * dpr).round(),
                              initial: initial,
                              icon: Icons.person_rounded,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(artist.name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: c.text, fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
                          const SizedBox(height: 4),
                          Text(meta, style: TextStyle(color: c.sub, fontSize: 14)),
                          const SizedBox(height: 18),
                          PlayShuffleRow(
                            colors: c,
                            onPlay: songs.isEmpty ? null : _playAll,
                            onShuffle: songs.isEmpty ? null : _shuffleAll,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (albums.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
                        child: Text('Albums',
                            style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 196,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: albums.length,
                          itemBuilder: (context, i) => _albumCard(albums[i].key, albums[i].value, c, accent, dpr),
                        ),
                      ),
                    ),
                  ],
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 18, 12, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _albumFilter == null ? 'Songs' : TitleCleaner.title(_albumFilter),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w800),
                            ),
                          ),
                          if (_albumFilter != null)
                            TextButton(
                              onPressed: () => setState(() => _albumFilter = null),
                              style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: accent),
                              child: const Text('Show all'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (songs.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Center(child: Text('No songs', style: TextStyle(color: c.sub, fontSize: 16))),
                      ),
                    )
                  else
                    SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final song = songs[index];
                          return StaggerIn(
                            playKey: 'artistsongs:${song.filePath}',
                            index: index,
                            child: _buildSongItem(song, index, c, accent, dpr),
                          );
                        },
                        childCount: songs.length,
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

  Widget _albumCard(String name, List<Song> songs, LibColors c, Color accent, double dpr) {
    final selected = _albumFilter == name;
    Uint8List? cover;
    for (final s in songs) {
      if (s.coverArt != null && s.coverArt!.isNotEmpty) {
        cover = s.coverArt;
        break;
      }
    }
    final title = TitleCleaner.title(name);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Semantics(
        button: true,
        selected: selected,
        label: 'Album $title, ${songs.length} songs',
        excludeSemantics: true,
        onTap: () => setState(() => _albumFilter = selected ? null : name),
        child: PressScale(
          onTap: () => setState(() => _albumFilter = selected ? null : name),
          pressedScale: 0.96,
          child: SizedBox(
            width: 132,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AnimatedContainer(
                  duration: Motion.of(context, Motion.fast),
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: selected ? accent : Colors.transparent, width: 2),
                  ),
                  child: LibCover(
                    bytes: cover,
                    seed: name,
                    size: 120,
                    radius: 18,
                    cacheSize: (120 * dpr).round(),
                    icon: Icons.album_rounded,
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: selected ? accent : c.text, fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text('${songs.length} ${songs.length == 1 ? 'song' : 'songs'}',
                      style: TextStyle(color: c.sub, fontSize: 12.5)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSongItem(Song song, int index, LibColors c, Color accent, double dpr) {
    final isCurrent = _isCurrent(song);
    final isPlayingHere = isCurrent && _isPlaying;

    return Semantics(
      button: true,
      selected: isCurrent,
      label: '${index + 1}. ${song.title}, ${song.album}${isPlayingHere ? ', now playing' : ''}',
      excludeSemantics: true,
      onTap: () => _setCurrentPlaylistAndPlay(index),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          _setCurrentPlaylistAndPlay(index);
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.only(left: 20, right: 4, top: 6, bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  child: isCurrent
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: EqualizerBars(color: accent, playing: isPlayingHere, size: 18))
                      : Text('${index + 1}',
                          style: TextStyle(color: c.sub, fontSize: 14, fontWeight: FontWeight.w600)),
                ),
                LibCover(
                  bytes: song.coverArt,
                  seed: song.album,
                  size: 48,
                  radius: 10,
                  cacheSize: (48 * dpr).round(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(song.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isCurrent ? accent : c.text,
                            fontSize: 16,
                            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                          )),
                      const SizedBox(height: 2),
                      Text(
                        song.duration != null ? '${song.album} · ${song.duration}' : song.album,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.sub, fontSize: 13),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: isPlayingHere ? 'Pause' : 'Play',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(isPlayingHere ? Icons.pause_rounded : Icons.play_arrow_rounded, color: accent),
                  onPressed: () => _toggleOrPlayIndex(index),
                ),
                QueueMenuButton(paths: [song.filePath], color: c.sub),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Dummy ThemeNotifier for compatibility
class ThemeNotifier {
  ThemeNotifier();
}
