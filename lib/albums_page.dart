// lib/albums_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music/player_screen.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'list_page.dart';
import 'songs_page.dart' show GlobalMiniPlayer; // Import GlobalMiniPlayer
import 'banner_ad_widget2.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';


class SongMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? coverArt;

  SongMetadata({this.title, this.artist, this.album, this.coverArt});

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
  final Color _primaryColor = AppPalette.accent;

  final Map<String, SongMetadata> _metadataCache = {};

  // Grouped by Album Name
  late Map<String, List<FileSystemEntity>> _byAlbum;
  Map<String, List<FileSystemEntity>>? _displayByAlbum;

  late List<FileSystemEntity> _allFiles;

  final TextEditingController _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';

  bool _searchActive = false;

  // Active group (Album name) + index inside that group.
  String? _activeGroupKey;
  int? _activeIndexInGroup;

  @override
  void initState() {
    super.initState();
    _allFiles = widget.audioFiles;
    _prepareAlbums();
    _preloadMetadata();

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
    for (var f in _allFiles) {
      if (!_metadataCache.containsKey(f.path)) {
        final meta = await _loadMetadata(f.path);
        _metadataCache[f.path] = meta;
      }
    }
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
      );
    } catch (_) {
      return SongMetadata();
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
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

  Widget _albumArtSmall(Uint8List? bytes, bool isDark) {
    if (bytes != null) {
      return Image.memory(bytes, fit: BoxFit.cover);
    }
    return Container(
      color: isDark ? Colors.grey.shade800 : Colors.grey.shade300,
      child: Icon(
        Icons.album,
        color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
        size: 24,
      ),
    );
  }

  Widget _albumListTile(
      String albumName,
      List<FileSystemEntity> songs,
      bool isDark,
      Color textColor,
      Color subColor,
      Color cardColor,
      ) {
    final firstSongMeta = songs.isNotEmpty ? _metadataCache[songs.first.path] : null;
    final artist = firstSongMeta?.artist ?? "Unknown Artist";
    final coverArt = firstSongMeta?.coverArt;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: cardColor,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _albumArtSmall(coverArt, isDark),
        ),
      ),
      title: Text(
        albumName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: textColor,
          fontSize: 16,
          fontWeight: FontWeight.w500,
        ),
      ),
      subtitle: Text(
        artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: subColor, fontSize: 14),
      ),
      onTap: () {
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
      },
    );
  }

  Widget _empty(bool isDark) {
    return Center(
      child: Text(
        "No Albums Found",
        style: TextStyle(color: isDark ? Colors.white : Colors.black),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final map = _displayByAlbum ?? {};
    final isDark = widget.isDarkMode;

    final bgColor = isDark ? AppPalette.darkBackground : Colors.white;
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    final subColor = isDark ? Colors.grey.shade400 : Colors.grey.shade700;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        centerTitle: false,
        title: Text(
          "Albums",
          style: TextStyle(
            color: textColor,
            fontSize: 28,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _searchActive ? Icons.close : Icons.search,
              color: textColor,
              size: 28,
            ),
            onPressed: _toggleSearch,
          )
        ],
      ),
      // FIX: Wrapped GlobalMiniPlayer in a Column with MainAxisSize.min
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
        ],
      ),
      body: Column(
        children: [
          if (_searchActive)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "Search albums...",
                  hintStyle: TextStyle(color: subColor),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade100,
                  prefixIcon: Icon(Icons.search, color: subColor),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: TextStyle(color: textColor),
              ),
            ),
          Expanded(
            child: map.isEmpty
                ? _empty(isDark)
                : ListView.separated(
              padding: const EdgeInsets.only(top: 10, bottom: 16),
              itemCount: map.length,
              separatorBuilder: (ctx, i) => Divider(
                color: isDark ? Colors.white10 : Colors.grey.shade200,
                height: 1,
                indent: 82,
              ),
              itemBuilder: (context, index) {
                final albumName = map.keys.elementAt(index);
                final songs = map[albumName] ?? [];
                return _albumListTile(
                  albumName,
                  songs,
                  isDark,
                  textColor,
                  subColor,
                  cardColor,
                );
              },
            ),
          ),
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

  /// Open the full-screen player for this album.
  /// Uses the GLOBAL AudioPlayer to isolate playback to this specific album
  Future<void> _openFullScreenForAlbum({required int startIndex}) async {
    final albumFiles = widget.songs.map((fs) => File(fs.path)).toList();

    final metaMap = <String, dynamic>{};
    for (final f in widget.songs) {
      final m = widget.metadataCache[f.path];
      metaMap[f.path] = {
        'title': m?.title,
        'artist': m?.artist,
        'album': m?.album,
        'cover': m?.coverArt,
      };
    }

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

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isDarkMode ? Colors.black : Colors.white;
    final textColor = widget.isDarkMode ? Colors.white : Colors.black;
    final subColor = widget.isDarkMode ? Colors.grey.shade400 : Colors.grey.shade600;
    final primaryColor = AppPalette.accent;

    final firstMeta =
    widget.songs.isNotEmpty ? widget.metadataCache[widget.songs.first.path] : null;
    final artist = firstMeta?.artist ?? "Unknown Artist";
    final coverArt = firstMeta?.coverArt;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: widget.isDarkMode ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(artist, style: TextStyle(color: textColor, fontSize: 16)),
        centerTitle: true,
      ),
      // FIX: Wrapped GlobalMiniPlayer in a Column with MainAxisSize.min
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 140,
                    height: 140,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: widget.isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 10,
                          offset: const Offset(0, 5),
                        )
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: coverArt != null
                          ? Image.memory(coverArt, fit: BoxFit.cover)
                          : Icon(
                        Icons.album,
                        size: 60,
                        color: widget.isDarkMode ? Colors.grey.shade600 : Colors.grey.shade400,
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.albumName,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          artist,
                          style: TextStyle(color: subColor, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          "${widget.songs.length} songs",
                          style: TextStyle(color: subColor, fontSize: 14),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
              child: Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      if (widget.songs.isNotEmpty) {
                        await _openFullScreenForAlbum(startIndex: 0);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2D3047),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    ),
                    icon: const Icon(Icons.play_arrow),
                    label: const Text("Play all"),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(top: 10)),
          SliverList(
            delegate: SliverChildBuilderDelegate(
                  (context, index) {
                final song = widget.songs[index];
                final meta = widget.metadataCache[song.path];
                final songTitle = meta?.title ?? p.basenameWithoutExtension(song.path);
                final songSubtitle = meta?.artist ?? "Unknown Artist";

                return ValueListenableBuilder<String?>(
                  valueListenable: PlaylistContext.currentPathNotifier,
                  builder: (context, contextPath, _) {
                    return StreamBuilder<SequenceState?>(
                      stream: widget.audioPlayer?.sequenceStateStream,
                      builder: (context, snapshot) {
                        String? playingPath;

                        if (snapshot.hasData) {
                          final tag = snapshot.data?.currentSource?.tag;
                          if (tag is Map) {
                            playingPath = tag['filePath'] as String?;
                          }
                        }
                        playingPath ??= contextPath;

                        final isPlaying = playingPath != null && playingPath == song.path;

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                          title: Text(
                            songTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isPlaying ? primaryColor : textColor,
                              fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            songSubtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: subColor, fontSize: 13),
                          ),
                          onTap: () async {
                            await _markRecentlyPlayed(song.path);
                            await _openFullScreenForAlbum(startIndex: index);
                          },
                        );
                      },
                    );
                  },
                );
              },
              childCount: widget.songs.length,
            ),
          ),
          const SliverPadding(padding: EdgeInsets.only(bottom: 16)),
        ],
      ),
    );
  }
}