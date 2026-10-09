// lib/list_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import 'playlist_page.dart';
import 'artists_page.dart';
import 'player_screen.dart';
import 'ad_widgets.dart';
import 'banner_ad_widget2.dart';
import 'banner_ad_widget3.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'audio_conversion_sheet.dart' show showAudioConversionSheet;
import 'app_palette.dart';
import 'library_service.dart';
import 'queues_sheet.dart';
import 'favorite_button.dart';

/// Helper to check effective brightness (System or Manual)
bool isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// Simple playback state helpers (UI-facing).
class PlaybackState {
  static final ValueNotifier<String?> current = ValueNotifier<String?>(null);
  static final ValueNotifier<bool> isPlaying = ValueNotifier<bool>(false);

  static void setCurrent(String? path) {
    current.value = path;
  }

  static void setPlaying(bool playing) {
    isPlaying.value = playing;
  }

  static void playFile(String path) {
    current.value = path;
    isPlaying.value = true;
  }

  static void pause() {
    isPlaying.value = false;
  }

  static void stop() {
    current.value = null;
    isPlaying.value = false;
  }
}

/// PlaybackController - manages an in-app playlist and navigation
class PlaybackController {
  PlaybackController._internal();
  static final PlaybackController instance = PlaybackController._internal();

  final ValueNotifier<List<String>> _playlist = ValueNotifier<List<String>>([]);
  final ValueNotifier<int> _index = ValueNotifier<int>(-1);

  List<String> get playlist => List.unmodifiable(_playlist.value);
  int get currentIndex => _index.value;
  String? get currentPath =>
      (currentIndex >= 0 && currentIndex < _playlist.value.length)
          ? _playlist.value[currentIndex]
          : null;
  bool get isPlaying => PlaybackState.isPlaying.value;

  Future<void> setPlaylist(List<String> paths,
      {int startIndex = 0, bool play = false, String? pageId}) async {
    _playlist.value = List<String>.from(paths);
    _index.value =
    (paths.isNotEmpty && startIndex >= 0 && startIndex < paths.length)
        ? startIndex
        : (paths.isNotEmpty ? 0 : -1);

    final String? folderPath =
    (pageId != null && pageId.contains('/')) ? pageId : null;
    PlaylistContext.setCurrentPlaylist(paths,
        pageId: pageId, folderPath: folderPath);

    if (play && _index.value >= 0) {
      await _playIndex(_index.value);
    } else {
      final cur = PlaybackState.current.value;
      if (cur != null && _playlist.value.contains(cur)) {
        _index.value = _playlist.value.indexOf(cur);
      } else if (_index.value >= 0 && _index.value < _playlist.value.length) {
        PlaybackState.setCurrent(_playlist.value[_index.value]);
        PlaybackState.setPlaying(false);
        PlaylistContext.setCurrentPath(PlaybackState.current.value);
      }
    }
  }

  Future<void> playFilePath(String path, {String? pageId}) async {
    final idx = _playlist.value.indexOf(path);
    if (idx >= 0) {
      await _playIndex(idx);
      return;
    }
    await setPlaylist([path], startIndex: 0, play: true, pageId: pageId);
  }

  Future<void> _playIndex(int idx) async {
    if (idx < 0 || idx >= _playlist.value.length) {
      return;
    }
    _index.value = idx;
    PlaybackState.setCurrent(_playlist.value[idx]);
    PlaybackState.setPlaying(true);

    try {
      PlaylistContext.setCurrentPath(_playlist.value[idx]);
    } catch (_) {}

    try {
      RecentlyPlayedNotifier.instance.markPlayed(_playlist.value[idx]);
    } catch (_) {}
  }

  Future<void> pause() async {
    PlaybackState.pause();
  }

  Future<void> resume() async {
    if (PlaybackState.current.value != null) {
      PlaybackState.setPlaying(true);
    } else if (_playlist.value.isNotEmpty && _index.value >= 0) {
      await _playIndex(_index.value);
    }
  }

  Future<void> next() async {
    final nextIndex = _index.value + 1;
    if (nextIndex < _playlist.value.length) {
      await _playIndex(nextIndex);
      return;
    } else {
      PlaybackState.stop();
      _index.value = -1;
      PlaylistContext.setCurrentPath(null);
    }
  }

  Future<void> previous() async {
    final prev = _index.value - 1;
    if (prev >= 0) {
      await _playIndex(prev);
    } else {
      if (_index.value >= 0 && _index.value < _playlist.value.length) {
        await _playIndex(0);
      }
    }
  }

  ValueListenable<List<String>> get playlistListenable => _playlist;
  ValueListenable<int> get indexListenable => _index;
}

//////////////////////
/// Notifiers
//////////////////////

class RecentlyPlayedNotifier extends ChangeNotifier {
  RecentlyPlayedNotifier._();
  static final RecentlyPlayedNotifier instance = RecentlyPlayedNotifier._();

  static const String _kRecentPlayedKey = 'recently_played_paths';
  static const int _maxItems = 50;

  final ValueNotifier<List<String>> paths = ValueNotifier<List<String>>(<String>[]);
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_kRecentPlayedKey) ?? <String>[];
    paths.value = saved;
    _initialized = true;
    notifyListeners();
  }

  Future<void> addPath(String path) async {
    await init();

    final updated = List<String>.from(paths.value);
    updated.remove(path);
    updated.insert(0, path);

    if (updated.length > _maxItems) {
      updated.removeRange(_maxItems, updated.length);
    }

    paths.value = updated;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kRecentPlayedKey, updated);
  }

  Future<void> markPlayed(String path) async {
    await addPath(path);
  }
}

class FavoritesNotifier extends ChangeNotifier {
  FavoritesNotifier._internal();
  static final FavoritesNotifier instance = FavoritesNotifier._internal();

  static const String _boxName = 'favorites_box';
  static const String _keyPaths = 'paths';

  Box<dynamic>? _box;
  final Set<String> _favorites = {};
  Future<void>? _initFuture;
  bool _isWriting = false;

  bool get initialized => _box != null;
  Set<String> get favoritesSet => Set.unmodifiable(_favorites);

  ValueListenable? get boxListenable => _box?.listenable();

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    if (_box != null) return;
    try {
      if (!Hive.isBoxOpen(_boxName)) {
        await Hive.initFlutter();
        _box = await Hive.openBox<dynamic>(_boxName);
      } else {
        _box = Hive.box<dynamic>(_boxName);
      }

      final stored = _box!.get(_keyPaths);
      _favorites
        ..clear()
        ..addAll((stored is List ? stored : []).map((e) => e.toString()));

      notifyListeners();
    } catch (e) {
      debugPrint('FavoritesNotifier.init error: $e');
    }
  }

  bool contains(String path) {
    return _favorites.contains(path);
  }

  Future<void> add(String path) async {
    await init();
    final didAdd = _favorites.add(path);
    if (didAdd) {
      notifyListeners();
      await _persist();
    }
  }

  Future<void> remove(String path) async {
    await init();
    final didRemove = _favorites.remove(path);
    if (didRemove) {
      notifyListeners();
      await _persist();
    }
  }

  Future<void> toggle(String path) async {
    await init();
    if (_favorites.contains(path)) {
      _favorites.remove(path);
      notifyListeners();
      await _persist();
    } else {
      _favorites.add(path);
      notifyListeners();
      await _persist();
    }
  }

  Future<void> _persist() async {
    try {
      await init();
      if (_isWriting) return;
      _isWriting = true;
      await _box!.put(_keyPaths, _favorites.toList());
    } catch (e) {
      debugPrint('FavoritesNotifier._persist error: $e');
    } finally {
      _isWriting = false;
    }
  }
}

//////////////////////
/// Pages
//////////////////////

class ListPage extends StatefulWidget {
  final List<File> audioFiles;
  final void Function(File file)? onPlay;
  final FutureOr<void> Function(File file)? onPause;
  final FutureOr<void> Function(File file)? onToggleFavorite;

  final VoidCallback? onOpenAlbums;
  final VoidCallback? onOpenGenres;
  final VoidCallback? onOpenSmartMix;

  /// When true, renders just the card-list body with no own Scaffold/AppBar
  /// — used when this page is embedded as a sub-tab of the merged Library
  /// destination (see songs_page.dart's _buildLibraryBody), whose parent
  /// Scaffold/AppBar already provides the surrounding chrome.
  final bool embedded;

  const ListPage({
    super.key,
    required this.audioFiles,
    this.onPlay,
    this.onPause,
    this.onToggleFavorite,
    this.onOpenAlbums,
    this.onOpenGenres,
    this.onOpenSmartMix,
    this.embedded = false,
  });

  @override
  State<ListPage> createState() => _ListPageState();
}

class _ListPageState extends State<ListPage> {
  List<File> _recentlyPlayed = [];
  List<File> _favoriteSongs = [];
  Set<String> _favoritePaths = {};
  final Map<String, Uint8List?> _coverCache = {};

  final Color _primaryColor = AppPalette.accent;
  String? _lastMarkedPath;
  bool _hasPlaylists = false;

  @override
  void initState() {
    super.initState();
    _initRecentlyPlayed();
    _syncFromWidget();
    _initFavoritesNotifier();
    _checkPlaylists();

    PlaybackState.current.addListener(_onPlaybackChange);
    PlaybackState.isPlaying.addListener(_onPlaybackChange);
    RecentlyPlayedNotifier.instance.paths.addListener(_onRecentlyPlayedChanged);

    PlaybackState.current.addListener(_maybeMarkPlayedFromPlaybackState);
    PlaybackState.isPlaying.addListener(_maybeMarkPlayedFromPlaybackState);

    try {
      PlaylistContext.currentPathNotifier
          .addListener(_maybeMarkPlayedFromPlaylistContext);
    } catch (_) {}
  }

  Future<void> _checkPlaylists() async {
    try {
      final names = await PlaylistService.getPlaylistNames();
      final filteredNames = names.where((n) => n != 'current_queue').toList();
      if (mounted) {
        setState(() {
          _hasPlaylists = filteredNames.isNotEmpty;
        });
      }
    } catch (e) {
      debugPrint('Error checking playlists: $e');
    }
  }

  void _onRecentlyPlayedChanged() {
    _rebuildRecentlyPlayedFromNotifier();
    if (mounted) setState(() {});
  }

  Future<void> _initRecentlyPlayed() async {
    await RecentlyPlayedNotifier.instance.init();
    _rebuildRecentlyPlayedFromNotifier();
    if (mounted) setState(() {});
  }

  void _rebuildRecentlyPlayedFromNotifier() {
    final paths = RecentlyPlayedNotifier.instance.paths.value;
    _recentlyPlayed =
        paths.map((p) => File(p)).where((f) => f.existsSync()).toList();
  }

  @override
  void didUpdateWidget(covariant ListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioFiles != widget.audioFiles) {
      _syncFromWidget();
    }
  }

  @override
  void dispose() {
    FavoritesNotifier.instance.removeListener(_onFavoritesChanged);
    PlaybackState.current.removeListener(_onPlaybackChange);
    PlaybackState.isPlaying.removeListener(_onPlaybackChange);
    RecentlyPlayedNotifier.instance.paths
        .removeListener(_onRecentlyPlayedChanged);

    PlaybackState.current.removeListener(_maybeMarkPlayedFromPlaybackState);
    PlaybackState.isPlaying.removeListener(_maybeMarkPlayedFromPlaybackState);
    try {
      PlaylistContext.currentPathNotifier
          .removeListener(_maybeMarkPlayedFromPlaylistContext);
    } catch (_) {}

    super.dispose();
  }

  void _onPlaybackChange() {
    if (mounted) setState(() {});
  }

  Future<void> _maybeMarkPlayedFromPlaybackState() async {
    try {
      final cur = PlaybackState.current.value;
      final playing = PlaybackState.isPlaying.value;

      if (cur != null && playing) {
        if (_lastMarkedPath != cur) {
          await RecentlyPlayedNotifier.instance.markPlayed(cur);
          _lastMarkedPath = cur;
          await _savePersistedData();
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      debugPrint('Error in _maybeMarkPlayedFromPlaybackState: $e');
    }
  }

  Future<void> _maybeMarkPlayedFromPlaylistContext() async {
    try {
      String? cur;
      try {
        cur = PlaylistContext.currentPathNotifier.value;
      } catch (_) {}
      final playing = PlaybackState.isPlaying.value;

      if (cur != null && playing) {
        if (_lastMarkedPath != cur) {
          await RecentlyPlayedNotifier.instance.markPlayed(cur);
          _lastMarkedPath = cur;
          await _savePersistedData();
          if (mounted) setState(() {});
        }
      }
    } catch (e) {
      debugPrint('Error in _maybeMarkPlayedFromPlaylistContext: $e');
    }
  }

  Future<void> _initFavoritesNotifier() async {
    await FavoritesNotifier.instance.init();
    _favoritePaths = FavoritesNotifier.instance.favoritesSet;
    _rebuildFavoriteSongs();
    if (mounted) setState(() {});
    FavoritesNotifier.instance.addListener(_onFavoritesChanged);
  }

  void _onFavoritesChanged() {
    if (!mounted) return;
    setState(() {
      _favoritePaths = FavoritesNotifier.instance.favoritesSet;
      _rebuildFavoriteSongs();
    });
  }

  void _syncFromWidget() {
    _recentlyPlayed =
        _recentlyPlayed.where((f) => File(f.path).existsSync()).toList();
    _rebuildFavoriteSongs();
    if (mounted) setState(() {});
  }

  void _rebuildFavoriteSongs() {
    _favoriteSongs = widget.audioFiles
        .where((f) => _favoritePaths.contains(f.path))
        .toList();
  }

  Future<Uint8List?> _getExternalCover(String songPath) async {
    try {
      final directory = p.dirname(songPath);
      final dir = Directory(directory);

      if (await dir.exists()) {
        final files = await dir.list().toList();
        for (final file in files) {
          if (file is File) {
            final filename = p.basename(file.path).toLowerCase();
            if ([
              'cover.jpg',
              'cover.jpeg',
              'folder.jpg',
              'album.jpg',
              'artwork.jpg',
              'cover.png',
              'folder.png'
            ].any((n) => filename.contains(n))) {
              try {
                return await file.readAsBytes();
              } catch (_) {}
            }
          }
        }
      }
    } catch (e) {
      debugPrint('Error reading external cover art: $e');
    }
    return null;
  }

  Future<Uint8List?> _loadCoverForFile(File file) async {
    final key = file.path;
    if (_coverCache.containsKey(key)) return _coverCache[key];

    try {
      final meta = await readMetadata(file, getImage: true);
      Uint8List? cover;

      if (meta != null && meta.pictures != null && meta.pictures!.isNotEmpty) {
        final firstPic = meta.pictures!.first;
        try {
          final bytes = firstPic.bytes;
          if (bytes != null) {
            if (bytes is Uint8List) {
              cover = bytes;
            } else if (bytes is List<int>) {
              cover = Uint8List.fromList(bytes);
            }
          }
        } catch (e) {
          debugPrint('Error extracting picture bytes: $e');
        }
      }

      if (cover == null) {
        cover = await _getExternalCover(file.path);
      }

      _coverCache[key] = cover;
      return cover;
    } catch (e) {
      debugPrint('Cover load error for ${file.path}: $e');
      final ext = await _getExternalCover(file.path);
      _coverCache[file.path] = ext;
      return ext;
    }
  }

  Future<void> _markPlayed(File file) async {
    await RecentlyPlayedNotifier.instance.markPlayed(file.path);
    await _savePersistedData();
    if (mounted) setState(() {});
  }

  Future<void> _savePersistedData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final recentPaths =
      _recentlyPlayed.take(50).map((file) => file.path).toList();
      await prefs.setStringList('recentlyPlayed', recentPaths);
      RecentlyPlayedNotifier.instance.paths.value = recentPaths;
    } catch (e) {
      debugPrint('Error saving persisted data: $e');
    }
  }

  Future<void> _toggleFavoriteAndShowSnack(
      BuildContext context, File file) async {
    final path = file.path;
    try {
      if (widget.onToggleFavorite != null) {
        await Future.sync(() => widget.onToggleFavorite!(file));
      } else {
        await FavoritesNotifier.instance.toggle(path);
      }

      await Future.delayed(const Duration(milliseconds: 60));
      final nowFav = FavoritesNotifier.instance.contains(path);

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(nowFav
            ? '${p.basenameWithoutExtension(path)} added to favorites'
            : '${p.basenameWithoutExtension(path)} removed from favorites'),
        backgroundColor: _primaryColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 900),
      ));

      _favoritePaths = FavoritesNotifier.instance.favoritesSet;
      _rebuildFavoriteSongs();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error toggling favorite: $e');
    }
  }

  Future<void> _handlePlay(File file,
      {List<File>? pageFiles, int? indexInPage, String? pageId}) async {
    try {
      await _markPlayed(file);

      if (pageFiles != null && indexInPage != null) {
        final paths = pageFiles.map((f) => f.path).toList();
        await PlaybackController.instance.setPlaylist(paths,
            startIndex: indexInPage,
            play: true,
            pageId: pageId ??
                (pageFiles.isNotEmpty
                    ? p.dirname(pageFiles.first.path)
                    : null));
      } else {
        await PlaybackController.instance
            .playFilePath(file.path, pageId: pageId);
      }

      if (widget.onPlay != null) {
        try {
          await Future.sync(() => widget.onPlay!(file));
        } catch (e) {
          debugPrint('Error calling external onPlay: $e');
        }
      }
    } catch (e) {
      debugPrint('Error in onPlay wrapper: $e');
    }
  }

  Future<void> _handlePause(File file) async {
    try {
      if (widget.onPause != null) {
        await Future.sync(() => widget.onPause!(file));
      }
    } catch (e) {
      debugPrint('Error calling pause handler: $e');
    } finally {
      await PlaybackController.instance.pause();
      PlaybackState.pause();
    }
  }

  Color get _pageBackground =>
      isDark(context) ? AppPalette.darkBackground : Colors.white;
  Color get _cardColor =>
      isDark(context) ? AppPalette.darkCard : Colors.white;
  Color get _pageTextColor => isDark(context) ? Colors.white : Colors.black;
  Color get _pageSubtitleColor =>
      isDark(context) ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
  Color get _pageShadowColor => isDark(context)
      ? Colors.black.withOpacity(0.3)
      : Colors.black.withOpacity(0.06);

  @override
  Widget build(BuildContext context) {
    final folders = _getFolders();
    final artistsMap = _getArtistsMap();
    final dark = isDark(context);

    final bgColor = dark ? AppPalette.darkBackground : Colors.white;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;
    final txtColor = dark ? Colors.white : Colors.black;
    final subColor = dark ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
    final shadowColor = dark
        ? Colors.black.withOpacity(0.3)
        : Colors.black.withOpacity(0.06);

    final body = Container(
      color: bgColor,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildSection(
            title: 'Recently Played',
            icon: Icons.history,
            count: _recentlyPlayed.length,
            color: Colors.blue,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => RecentlyPlayedPage(
                    recentlyPlayed: _recentlyPlayed,
                    onPlay: (file) => Future.sync(() => _handlePlay(file,
                        pageFiles: _recentlyPlayed,
                        indexInPage: _recentlyPlayed
                            .indexWhere((f) => f.path == file.path),
                        pageId: 'recently_played')),
                    onToggleFavorite: (file) =>
                        _toggleFavoriteAndShowSnack(context, file),
                    loadCoverForFile: _loadCoverForFile,
                    onPause: (f) => Future.sync(() => _handlePause(f)),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildSection(
            title: 'Recently Added',
            icon: Icons.new_releases_outlined,
            count: widget.audioFiles.length > 50 ? 50 : widget.audioFiles.length,
            color: Colors.cyan,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () => _openSmartList(SmartListKind.recentlyAdded),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<int>(
            valueListenable: PlayStats.changes,
            builder: (context, _, __) => _buildSection(
              title: 'Most Played',
              icon: Icons.trending_up_rounded,
              count: PlayStats.mostPlayed(widget.audioFiles).length,
              color: Colors.amber.shade700,
              bgColor: cardColor,
              textColor: txtColor,
              subColor: subColor,
              shadowColor: shadowColor,
              dark: dark,
              onTap: () => _openSmartList(SmartListKind.mostPlayed),
            ),
          ),
          const SizedBox(height: 12),
          _buildSection(
            title: 'Folder List',
            icon: Icons.folder,
            count: folders.length,
            color: Colors.purple,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => FolderListPage(
                    folders: folders,
                    onPlay: (file,
                        {List<File>? pageFiles, int? indexInPage}) async {
                      final pid = pageFiles != null && pageFiles.isNotEmpty
                          ? p.dirname(pageFiles.first.path)
                          : null;
                      await _handlePlay(file,
                          pageFiles: pageFiles,
                          indexInPage: indexInPage,
                          pageId: pid);
                    },
                    onToggleFavorite: (file) =>
                        _toggleFavoriteAndShowSnack(context, file),
                    loadCoverForFile: _loadCoverForFile,
                    onPause: (f) => Future.sync(() => _handlePause(f)),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildSection(
            title: 'Artists',
            icon: Icons.person,
            count: artistsMap.length,
            color: Colors.teal,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ArtistsPage(
                    audioFiles: widget.audioFiles,
                    onPlay: (path, index) {
                      final file = File(path);

                      _handlePlay(
                        file,
                        pageFiles: null,
                        indexInPage: 0,
                        pageId: null,
                      );
                    },

                    themeNotifier: null,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          _buildStaticSection(
            title: 'Albums',
            icon: Icons.album,
            subtitle: 'Browse your music by album',
            color: Colors.deepOrange,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () => widget.onOpenAlbums?.call(),
          ),
          const SizedBox(height: 12),
          _buildStaticSection(
            title: 'Genres',
            icon: Icons.category,
            subtitle: 'Browse your music by genre',
            color: Colors.indigo,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () => widget.onOpenGenres?.call(),
          ),
          const SizedBox(height: 12),
          _buildStaticSection(
            title: 'Smart Mix',
            icon: Icons.auto_awesome,
            subtitle: 'AI-ranked playlist by mood and tempo',
            color: Colors.pink,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () => widget.onOpenSmartMix?.call(),
          ),
          const SizedBox(height: 20),
          _buildStaticSection(
            title: _hasPlaylists ? 'Playlists' : 'New Playlist',
            icon: Icons.playlist_add,
            subtitle: 'Create your custom playlist',
            color: Colors.green,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
          ),
          const SizedBox(height: 12),
          _buildSection(
            title: 'My Favorites',
            icon: Icons.favorite,
            count: _favoriteSongs.length,
            color: Colors.red,
            bgColor: cardColor,
            textColor: txtColor,
            subColor: subColor,
            shadowColor: shadowColor,
            dark: dark,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => MyFavoritesPage(
                    audioFiles: widget.audioFiles,
                    onPlay: (file) => Future.sync(() => _handlePlay(file,
                        pageFiles: _favoriteSongs,
                        indexInPage: _favoriteSongs
                            .indexWhere((f) => f.path == file.path),
                        pageId: 'favorites')),
                    onToggleFavorite: (file) =>
                        _toggleFavoriteAndShowSnack(context, file),
                    loadCoverForFile: _loadCoverForFile,
                    onPause: (f) => Future.sync(() => _handlePause(f)),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('Library'),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        centerTitle: true,
        foregroundColor: txtColor,
        iconTheme: IconThemeData(color: txtColor),
        systemOverlayStyle:
        dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      body: body,
    );
  }

  void _openSmartList(SmartListKind kind) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SmartLibraryListPage(
          kind: kind,
          audioFiles: widget.audioFiles,
          onPlay: (file, pageFiles) => Future.sync(() => _handlePlay(file,
              pageFiles: pageFiles,
              indexInPage: pageFiles.indexWhere((f) => f.path == file.path),
              pageId: kind.pageId)),
          onToggleFavorite: (file) => _toggleFavoriteAndShowSnack(context, file),
          loadCoverForFile: _loadCoverForFile,
          onPause: (f) => Future.sync(() => _handlePause(f)),
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required IconData icon,
    required int count,
    required Color color,
    required VoidCallback onTap,
    required Color bgColor,
    required Color textColor,
    required Color subColor,
    required Color shadowColor,
    required bool dark,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$count item${count != 1 ? 's' : ''}',
                        style: TextStyle(
                          color: subColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: dark ? Colors.grey[800] : Colors.grey[100],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.arrow_forward_ios,
                      color: subColor, size: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStaticSection({
    required String title,
    required IconData icon,
    required String subtitle,
    required Color color,
    required Color bgColor,
    required Color textColor,
    required Color subColor,
    required Color shadowColor,
    required bool dark,
    VoidCallback? onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap ?? () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => CreatePlaylistPage(
                  audioFiles: widget.audioFiles,
                  onPlay: (path, playlistPaths) {
                    final file = widget.audioFiles.firstWhere(
                          (f) => f.path == path,
                      orElse: () => File(path),
                    );
                    final indexInPlaylist =
                    playlistPaths.indexWhere((p) => p == path);

                    _handlePlay(
                      file,
                      pageFiles: playlistPaths.map((p) => File(p)).toList(),
                      indexInPage: indexInPlaylist,
                      pageId: 'custom_playlist',
                    );
                  },
                  loadCoverForFile: _loadCoverForFile,
                  miniPlayer: const GlobalMiniPlayer(),
                  onNavTap: null,
                  themeController: null, pageId: '',
                ),
              ),
            );

            await _checkPlaylists();

            if (result != null && result is Map) {
              final name = result['name'] ?? 'Playlist';
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Playlist "$name" created'),
                  backgroundColor: _primaryColor,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: shadowColor,
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Container(
                  width: 54,
                  height: 54,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: color, size: 28),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: subColor,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: dark ? Colors.grey[800] : Colors.grey[100],
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.arrow_forward_ios,
                      color: subColor, size: 16),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Map<String, List<File>> _getFolders() {
    final Map<String, List<File>> folders = {};
    for (final f in widget.audioFiles) {
      final dir = p.dirname(f.path);
      folders.putIfAbsent(dir, () => []).add(f);
    }
    return folders;
  }

  Map<String, List<File>> _getArtistsMap() {
    final Map<String, List<File>> map = {};

    for (final f in widget.audioFiles) {
      final folderPath = p.dirname(f.path);
      final artist = p.basename(folderPath).trim().isEmpty
          ? 'Unknown Artist'
          : p.basename(folderPath).trim();

      map.putIfAbsent(artist, () => []).add(f);
    }

    return map;
  }
}
//////////////////////
/// Audio Converter Page
//////////////////////

class AudioConverterPage extends StatefulWidget {
  final List<File> audioFiles;

  const AudioConverterPage({super.key, required this.audioFiles});

  @override
  State<AudioConverterPage> createState() => _AudioConverterPageState();
}

class _AudioConverterPageState extends State<AudioConverterPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _query = _searchController.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _pickAndConvert(File file) async {
    final dark = isDark(context);
    int? bitrate;
    try {
      final meta = await readMetadata(file, getImage: false);
      bitrate = meta.bitrate;
    } catch (_) {}

    if (!mounted) return;
    if (bitrate != null && bitrate > 0 && bitrate <= 128000) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'This file is about ${(bitrate / 1000).round()} kbps. 320 kbps sources '
              'give better 4D/8D results, but conversion will still proceed.',
        ),
        backgroundColor: AppPalette.accent,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ));
    }

    if (!mounted) return;
    await showAudioConversionSheet(
      context: context,
      song: file,
      title: p.basenameWithoutExtension(file.path),
      isDark: dark,
      onConverted: (record) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${p.basenameWithoutExtension(file.path)} converted'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    final bgColor = dark ? AppPalette.darkBackground : Colors.white;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;
    final txtColor = dark ? Colors.white : Colors.black;
    final subColor = dark ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
    final primary = AppPalette.accent;

    final files = _query.isEmpty
        ? widget.audioFiles
        : widget.audioFiles
        .where((f) => p.basenameWithoutExtension(f.path).toLowerCase().contains(_query))
        .toList();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('Audio Converter'),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        foregroundColor: txtColor,
        iconTheme: IconThemeData(color: txtColor),
        systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      // REMOVED: bottomNavigationBar containing GlobalMiniPlayer()
      // because the parent tab screen already provides it.
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: primary.withOpacity(dark ? 0.16 : 0.08),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: primary.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.headphones, color: primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Best Experience',
                          style: TextStyle(fontWeight: FontWeight.w700, color: txtColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'For the best 4D and 8D audio experience, use headphones.',
                  style: TextStyle(color: subColor, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.high_quality, color: primary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('Quality Recommendation',
                          style: TextStyle(fontWeight: FontWeight.w700, color: txtColor)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '320 kbps audio files are recommended for 4D and 8D conversion. '
                      'Compared with 128 kbps files, 320 kbps source audio can provide '
                      'better results and a more detailed listening experience.',
                  style: TextStyle(color: subColor, fontSize: 13),
                ),
                const SizedBox(height: 6),
                Text(
                  'This is informational only — you can still convert any supported file.',
                  style: TextStyle(color: subColor.withOpacity(0.85), fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: txtColor),
              decoration: InputDecoration(
                hintText: 'Search songs to convert...',
                hintStyle: TextStyle(color: subColor),
                prefixIcon: Icon(Icons.search, color: subColor),
                filled: true,
                fillColor: cardColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: widget.audioFiles.isEmpty
                ? Center(
              child: Text('No songs available to convert', style: TextStyle(color: subColor)),
            )
                : files.isEmpty
                ? Center(child: Text('No matching songs', style: TextStyle(color: subColor)))
                : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: files.length,
              itemBuilder: (context, index) {
                final file = files[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _pickAndConvert(file),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(dark ? 0.3 : 0.06),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                color: primary.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.graphic_eq, color: primary),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                p.basenameWithoutExtension(file.path),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: txtColor, fontWeight: FontWeight.w500),
                              ),
                            ),
                            Icon(Icons.chevron_right, color: subColor),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

//////////////////////
/// Current Queue Page
//////////////////////
class CurrentQueuePage extends StatefulWidget {
  final List<File> queue;
  final FutureOr<void> Function(File file, int index) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  static const String kQueuePageId = 'current_queue';

  const CurrentQueuePage({
    super.key,
    required this.queue,
    required this.onPlay,
    required this.onPause,
    required this.onToggleFavorite,
    required this.loadCoverForFile,
  });

  @override
  State<CurrentQueuePage> createState() => _CurrentQueuePageState();
}

class _QueueItem {
  final String id;
  final File file;

  _QueueItem(this.file) : id = UniqueKey().toString();
}

class _CurrentQueuePageState extends State<CurrentQueuePage> {
  late List<_QueueItem> _currentList;

  @override
  void initState() {
    super.initState();
    _currentList = widget.queue.map((f) => _QueueItem(f)).toList();
    PlaylistContext.currentPlaylistNotifier.addListener(_onExternalQueueChange);
    PlaylistContext.currentPathNotifier.addListener(_onPlaybackChange);
  }

  @override
  void dispose() {
    PlaylistContext.currentPlaylistNotifier.removeListener(_onExternalQueueChange);
    PlaylistContext.currentPathNotifier.removeListener(_onPlaybackChange);
    super.dispose();
  }

  void _onPlaybackChange() {
    if (mounted) setState(() {});
  }

  void _onExternalQueueChange() {
    final updatedPaths = PlaylistContext.getCurrentPlaylist();

    if (updatedPaths != null && mounted) {
      setState(() {
        _currentList = updatedPaths
            .map((p) => _QueueItem(File(p)))
            .toList();
      });
    }
  }

  void _syncToContext() {
    final paths = _currentList.map((e) => e.file.path).toList();
    PlaylistContext.setCurrentPlaylist(
      paths,
      pageId: CurrentQueuePage.kQueuePageId,
    );
  }

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);

    final currentPath = PlaylistContext.currentPathNotifier.value;
    final isPlayingGlobal = PlaybackState.isPlaying.value;

    return Scaffold(
      backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
      appBar: AppBar(
        title: const Text('Current Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.layers_rounded),
            tooltip: 'Queues',
            onPressed: () => showQueuesSheet(context),
          ),
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded),
            tooltip: 'Save queue as playlist',
            onPressed: () => showSaveQueueAsPlaylistDialog(context, _currentList.map((e) => e.file.path).toList()),
          ),
        ],
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        foregroundColor: dark ? Colors.white : Colors.black,
        systemOverlayStyle:
        dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      body: _currentList.isEmpty
          ? Center(
        child: Text(
          'Queue is empty',
          style: TextStyle(
            color: dark ? Colors.grey[400] : Colors.grey[600],
          ),
        ),
      )
          : ReorderableListView.builder(
        itemCount: _currentList.length,

        onReorder: (oldIndex, newIndex) {
          setState(() {
            if (newIndex > oldIndex) newIndex--;
            final item = _currentList.removeAt(oldIndex);
            _currentList.insert(newIndex, item);
          });
          _syncToContext();
        },

        itemBuilder: (context, index) {
          final item = _currentList[index];
          final file = item.file;

          final isCurrent = currentPath == file.path;
          final isRowPlaying = isCurrent && isPlayingGlobal;

          return Dismissible(
            key: ValueKey(item.id),
            direction: DismissDirection.endToStart,
            background: Container(
              color: Colors.red,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              child: const Icon(Icons.delete, color: Colors.white),
            ),
            onDismissed: (_) {
              setState(() => _currentList.removeAt(index));
              _syncToContext();
            },
            child: Container(
              color: isCurrent
                  ? (dark ? Colors.grey[800] : Colors.blue[50])
                  : Colors.transparent,
              child: ListTile(
                leading: Icon(
                  isRowPlaying ? Icons.pause : (isCurrent ? Icons.play_arrow : Icons.drag_handle),
                  color: isCurrent ? Colors.blue : Colors.grey,
                ),
                title: Text(
                  p.basenameWithoutExtension(file.path),
                  style: TextStyle(
                    color: isCurrent ? Colors.blue : null,
                    fontWeight:
                    isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  'Queue item ${index + 1}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () {
                    setState(() => _currentList.removeAt(index));
                    _syncToContext();
                  },
                ),
                onTap: () {
                  if (isCurrent && isPlayingGlobal) {
                    widget.onPause(file);
                  } else {
                    widget.onPlay(file, index);
                  }
                },
              ),
            ),
          );
        },
      ),
    );
  }
}

//////////////////////
/// Recently Played Page
//////////////////////

enum SmartListKind { recentlyAdded, mostPlayed }

extension SmartListKindX on SmartListKind {
  String get title => this == SmartListKind.recentlyAdded ? 'Recently Added' : 'Most Played';
  String get pageId => this == SmartListKind.recentlyAdded ? 'recently_added' : 'most_played';
}

/// Automatic lists built from the library: the 50 newest additions (by
/// MediaStore date added) or the 50 most-played songs (play counts are
/// recorded each time a song starts).
class SmartLibraryListPage extends StatelessWidget {
  final SmartListKind kind;
  final List<File> audioFiles;
  final FutureOr<void> Function(File file, List<File> pageFiles) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  const SmartLibraryListPage({
    super.key,
    required this.kind,
    required this.audioFiles,
    required this.onPlay,
    required this.onPause,
    required this.onToggleFavorite,
    required this.loadCoverForFile,
  });

  String _ago(int secs) {
    if (secs <= 0) return 'Added';
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(secs * 1000));
    if (d.inDays >= 365) return 'Added ${d.inDays ~/ 365}y ago';
    if (d.inDays >= 30) return 'Added ${d.inDays ~/ 30}mo ago';
    if (d.inDays >= 1) return 'Added ${d.inDays}d ago';
    if (d.inHours >= 1) return 'Added ${d.inHours}h ago';
    return 'Added just now';
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: PlayStats.changes,
      builder: (context, _, __) {
        final items = kind == SmartListKind.recentlyAdded
            ? PlayStats.recentlyAdded(audioFiles)
            : PlayStats.mostPlayed(audioFiles);
        return _BaseListPage(
          title: kind.title,
          icon: kind == SmartListKind.recentlyAdded ? Icons.new_releases_outlined : Icons.trending_up_rounded,
          color: kind == SmartListKind.recentlyAdded ? Colors.cyan : Colors.amber.shade700,
          items: items,
          onPlay: (file) async {
            final idx = items.indexWhere((f) => f.path == file.path);
            await PlaybackController.instance.setPlaylist(
              items.map((f) => f.path).toList(),
              startIndex: idx < 0 ? 0 : idx,
              play: true,
              pageId: kind.pageId,
            );
            await Future.sync(() => onPlay(file, items));
          },
          onPause: (f) async => await Future.sync(() => onPause(f)),
          onToggleFavorite: (f) async => await Future.sync(() => onToggleFavorite(f)),
          emptyMessage: kind == SmartListKind.recentlyAdded ? 'No songs yet' : 'Nothing played yet',
          emptySubtitle: kind == SmartListKind.mostPlayed ? 'Songs you play most will show up here' : null,
          getSubtitle: (file, index) {
            if (kind == SmartListKind.mostPlayed) {
              final n = PlayStats.countFor(file.path);
              return 'Played $n time${n == 1 ? '' : 's'}';
            }
            return _ago(LibraryInfo.dateAddedFor(file.path));
          },
          loadCoverForFile: loadCoverForFile,
          pageId: kind.pageId,
          bannerWidget: const BannerAdWidget3(),
          enableSearch: true,
          searchHint: 'Search ${kind.title.toLowerCase()}...',
        );
      },
    );
  }
}

class RecentlyPlayedPage extends StatefulWidget {
  final List<File> recentlyPlayed;
  final void Function(File) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  const RecentlyPlayedPage({
    super.key,
    required this.recentlyPlayed,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.loadCoverForFile,
    required this.onPause,
  });

  @override
  State<RecentlyPlayedPage> createState() => _RecentlyPlayedPageState();
}

class _RecentlyPlayedPageState extends State<RecentlyPlayedPage> {
  late List<File> _displayList;

  @override
  void initState() {
    super.initState();
    _displayList = <File>[];
    FavoritesNotifier.instance.addListener(_onFavoritesChanged);
    PlaybackState.current.addListener(_onPlaybackChanged);
    PlaybackState.isPlaying.addListener(_onPlaybackChanged);
    RecentlyPlayedNotifier.instance.paths.addListener(_rebuildFromNotifier);
    _initRecentList();
    unawaited(RecentlyPlayedNotifier.instance.init());
  }

  Future<void> _initRecentList() async {
    await RecentlyPlayedNotifier.instance.init();
    if (!mounted) return;
    _rebuildFromNotifier();
  }

  void _rebuildFromNotifier() {
    final notifierPaths = RecentlyPlayedNotifier.instance.paths.value;

    final filesFromNotifier = notifierPaths
        .map((path) => File(path))
        .where((f) => f.existsSync())
        .toList();

    final constructorFiles = widget.recentlyPlayed
        .where((f) => f.existsSync())
        .toList();

    final merged = <File>[];
    for (final f in filesFromNotifier) {
      if (!merged.any((m) => m.path == f.path)) {
        merged.add(f);
      }
    }
    for (final f in constructorFiles) {
      if (!merged.any((m) => m.path == f.path)) {
        merged.add(f);
      }
    }

    if (!mounted) return;
    setState(() {
      _displayList = merged;
    });
  }

  @override
  void dispose() {
    FavoritesNotifier.instance.removeListener(_onFavoritesChanged);
    PlaybackState.current.removeListener(_onPlaybackChanged);
    PlaybackState.isPlaying.removeListener(_onPlaybackChanged);
    RecentlyPlayedNotifier.instance.paths.removeListener(_rebuildFromNotifier);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _recordRecent(File file) async {
    await RecentlyPlayedNotifier.instance.addPath(file.path);
  }

  @override
  Widget build(BuildContext context) {
    return _BaseListPage(
      title: 'Recently Played',
      icon: Icons.history,
      color: Colors.blue,
      items: _displayList,
      onPlay: (file) async {
        await _recordRecent(file);

        final idx = _displayList.indexWhere((f) => f.path == file.path);
        if (idx >= 0) {
          await PlaybackController.instance.setPlaylist(
            _displayList.map((f) => f.path).toList(),
            startIndex: idx,
            play: true,
            pageId: 'recently_played',
          );
        } else {
          await PlaybackController.instance.playFilePath(
            file.path,
            pageId: 'recently_played',
          );
        }

        await Future.sync(() => widget.onPlay(file));
      },
      onPause: (f) async => await Future.sync(() => widget.onPause(f)),
      onToggleFavorite: (f) async => await Future.sync(() => widget.onToggleFavorite(f)),
      emptyMessage: 'No recently played songs',
      getSubtitle: (file, index) => 'Played recently',
      loadCoverForFile: widget.loadCoverForFile,
      pageId: 'recently_played',
      bannerWidget: const BannerAdWidget3(),
      enableSearch: true,
      searchHint: 'Search recently played...',
    );
  }
}

//////////////////////
/// Folder List Page
//////////////////////
class FolderListPage extends StatefulWidget {
  final Map<String, List<File>> folders;
  final FutureOr<void> Function(File file, {List<File>? pageFiles, int? indexInPage}) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  const FolderListPage({
    super.key,
    required this.folders,
    required this.onPlay,
    required this.onPause,
    required this.onToggleFavorite,
    required this.loadCoverForFile,
  });

  @override
  State<FolderListPage> createState() => _FolderListPageState();
}

class _FolderListPageState extends State<FolderListPage> {
  Color get _pageBackground =>
      isDark(context) ? AppPalette.darkBackground : Colors.white;
  Color get _cardColor =>
      isDark(context) ? AppPalette.darkCard : Colors.white;
  Color get _pageTextColor => isDark(context) ? Colors.white : Colors.black;
  Color get _pageSubtitleColor =>
      isDark(context) ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
  Color get _pageShadowColor =>
      isDark(context) ? Colors.black.withOpacity(0.3) : Colors.black.withOpacity(0.06);

  final Color _highlightColor = AppPalette.accent;

  @override
  Widget build(BuildContext context) {
    final entries = widget.folders.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final dark = isDark(context);

    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: AppBar(
        title: const Text('Folders'),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        foregroundColor: dark ? Colors.white : Colors.black,
        iconTheme: IconThemeData(color: dark ? Colors.white : Colors.black),
        systemOverlayStyle: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      body: entries.isEmpty
          ? Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.folder, size: 64, color: Colors.purple),
            const SizedBox(height: 16),
            Text(
              'No folders found',
              style: TextStyle(
                color: _pageTextColor,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your music files will appear here',
              style: TextStyle(color: _pageSubtitleColor),
            ),
          ],
        ),
      )
          : Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final entry = entries[i];
                final folderPath = entry.key;
                final folderName = p.basename(folderPath);
                final songs = entry.value;

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => FolderSongsPage(
                              folderName: folderName,
                              folderPath: folderPath,
                              songs: songs,
                              onPlay: (file) async {
                                final idx = songs.indexWhere((f) => f.path == file.path);
                                await PlaybackController.instance.setPlaylist(
                                  songs.map((f) => f.path).toList(),
                                  startIndex: idx >= 0 ? idx : 0,
                                  play: true,
                                  pageId: folderPath,
                                );
                                await Future.sync(() => widget.onPlay(
                                  file,
                                  pageFiles: songs,
                                  indexInPage: idx,
                                ));
                              },
                              onToggleFavorite: (f) async =>
                              await Future.sync(() => widget.onToggleFavorite(f)),
                              loadCoverForFile: widget.loadCoverForFile,
                              onPause: (f) async {
                                await PlaybackController.instance.pause();
                                PlaybackState.pause();
                                await Future.sync(() => widget.onPause(f));
                              },
                            ),
                          ),
                        );
                      },
                      borderRadius: BorderRadius.circular(16),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _cardColor,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: _pageShadowColor,
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 54,
                              height: 54,
                              decoration: BoxDecoration(
                                color: _highlightColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.folder, color: _highlightColor, size: 28),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    folderName,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: _pageTextColor,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${songs.length} song${songs.length != 1 ? 's' : ''}',
                                    style: TextStyle(
                                      color: _pageSubtitleColor,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    folderPath,
                                    style: TextStyle(
                                      color: _pageSubtitleColor,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: dark ? Colors.grey[800] : Colors.grey[100],
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.arrow_forward_ios,
                                color: _pageSubtitleColor,
                                size: 16,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

//////////////////////
/// Folder Songs Page
//////////////////////

class FolderSongsPage extends StatefulWidget {
  final String folderName;
  final String folderPath;
  final List<File> songs;
  final FutureOr<void> Function(File) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  const FolderSongsPage({
    super.key,
    required this.folderName,
    required this.folderPath,
    required this.songs,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onPause,
    required this.loadCoverForFile,
  });

  @override
  State<FolderSongsPage> createState() => _FolderSongsPageState();
}

class _FolderSongsPageState extends State<FolderSongsPage> {
  final Color _highlightColor = AppPalette.accent;

  @override
  void initState() {
    super.initState();
    try {
      FavoritesNotifier.instance.addListener(_onFavoritesChanged);
      PlaybackState.current.addListener(_onPlaybackChanged);
      PlaybackState.isPlaying.addListener(_onPlaybackChanged);
    } catch (_) {}
  }

  @override
  void dispose() {
    try {
      FavoritesNotifier.instance.removeListener(_onFavoritesChanged);
      PlaybackState.current.removeListener(_onPlaybackChanged);
      PlaybackState.isPlaying.removeListener(_onPlaybackChanged);
    } catch (_) {}
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return _BaseListPage(
      title: widget.folderName,
      icon: Icons.folder,
      color: _highlightColor,
      items: widget.songs,
      onPlay: (f) async {
        final idx = widget.songs.indexWhere((s) => s.path == f.path);
        if (idx >= 0) {
          await PlaybackController.instance.setPlaylist(
            widget.songs.map((s) => s.path).toList(),
            startIndex: idx,
            play: true,
            pageId: widget.folderPath,
          );
        } else {
          await PlaybackController.instance.playFilePath(f.path, pageId: widget.folderPath);
        }
        await Future.sync(() => widget.onPlay(f));
      },
      onPause: (f) async {
        await PlaybackController.instance.pause();
        PlaybackState.pause();
        await Future.sync(() => widget.onPause(f));
      },
      onToggleFavorite: (f) async {
        await Future.sync(() => widget.onToggleFavorite(f));
      },
      emptyMessage: 'No songs in this folder',
      getSubtitle: (file, index) => 'Track ${index + 1}',
      header: Container(
        padding: const EdgeInsets.all(20),
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark(context) ? AppPalette.darkCard : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: isDark(context)
                  ? Colors.black.withOpacity(0.3)
                  : Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                color: _highlightColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.folder, color: Colors.purple, size: 32),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.folderName,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: isDark(context) ? Colors.white : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${widget.songs.length} song${widget.songs.length != 1 ? 's' : ''}',
                    style: TextStyle(
                      color: isDark(context)
                          ? const Color(0xFFB3B3B3)
                          : Colors.grey.shade700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.folderPath,
                    style: TextStyle(
                      color: isDark(context)
                          ? const Color(0xFFB3B3B3)
                          : Colors.grey.shade700,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      loadCoverForFile: widget.loadCoverForFile,
      pageId: widget.folderPath,
      enableSearch: true,
      searchHint: 'Search in this folder...',
    );
  }
}

//////////////////////
/// My Favorites Page
//////////////////////

class MyFavoritesPage extends StatefulWidget {
  final List<File> audioFiles;
  final void Function(File) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  const MyFavoritesPage({
    super.key,
    required this.audioFiles,
    required this.onPlay,
    required this.onToggleFavorite,
    required this.onPause,
    required this.loadCoverForFile,
  });

  @override
  State<MyFavoritesPage> createState() => _MyFavoritesPageState();
}

class _MyFavoritesPageState extends State<MyFavoritesPage> {
  @override
  void initState() {
    super.initState();
    FavoritesNotifier.instance.addListener(_onFavoritesChanged);
    PlaybackState.current.addListener(_onPlaybackChanged);
    PlaybackState.isPlaying.addListener(_onPlaybackChanged);
  }

  @override
  void dispose() {
    FavoritesNotifier.instance.removeListener(_onFavoritesChanged);
    PlaybackState.current.removeListener(_onPlaybackChanged);
    PlaybackState.isPlaying.removeListener(_onPlaybackChanged);
    super.dispose();
  }

  void _onFavoritesChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final favoritePaths = FavoritesNotifier.instance.favoritesSet;
    final favoriteSongs = widget.audioFiles
        .where((f) => favoritePaths.contains(f.path))
        .toList();

    return _BaseListPage(
      title: 'My Favorites',
      icon: Icons.favorite,
      color: Colors.red,
      items: favoriteSongs,
      onPlay: (file) async {
        final idx = favoriteSongs.indexWhere((f) => f.path == file.path);
        if (idx >= 0) {
          await PlaybackController.instance.setPlaylist(
              favoriteSongs.map((f) => f.path).toList(),
              startIndex: idx,
              play: true,
              pageId: 'favorites');
        } else {
          await PlaybackController.instance
              .playFilePath(file.path, pageId: 'favorites');
        }
        await Future.sync(() => widget.onPlay(file));
      },
      onPause: (f) async => await Future.sync(() => widget.onPause(f)),
      onToggleFavorite: (f) async =>
      await Future.sync(() => widget.onToggleFavorite(f)),
      emptyMessage: 'No favorite songs yet',
      emptySubtitle: 'Tap the heart icon to add songs',
      getSubtitle: (file, index) => 'Favorite song',
      loadCoverForFile: widget.loadCoverForFile,
      pageId: 'favorites',
      bannerWidget: const BannerAdWidget2(),
    );
  }
}

//////////////////////
/// Base List Page
//////////////////////

class _BaseListPage extends StatefulWidget {
  final String title;
  final IconData icon;
  final Color color;
  final List<File> items;
  final FutureOr<void> Function(File) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final String emptyMessage;
  final String? emptySubtitle;
  final String Function(File file, int index) getSubtitle;
  final Widget? header;
  final Future<Uint8List?> Function(File file) loadCoverForFile;
  final String pageId;
  final Widget? bannerWidget;

  // generic search support
  final bool enableSearch;
  final String? searchHint;

  const _BaseListPage({
    required this.title,
    required this.icon,
    required this.color,
    required this.items,
    required this.onPlay,
    required this.onPause,
    required this.onToggleFavorite,
    required this.emptyMessage,
    this.emptySubtitle,
    required this.getSubtitle,
    this.header,
    required this.loadCoverForFile,
    required this.pageId,
    this.bannerWidget,
    this.enableSearch = false,
    this.searchHint,
    Key? key,
  }) : super(key: key);

  @override
  State<_BaseListPage> createState() => _BaseListPageState();
}

class _BaseListPageState extends State<_BaseListPage> {
  final Map<String, Uint8List?> _coverCache = {};

  late List<File> _allItems;
  late List<File> _filteredItems;
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  void initState() {
    super.initState();
    FavoritesNotifier.instance.addListener(_onFavChanged);

    PlaybackState.isPlaying.addListener(_onPlaybackChanged);
    try {
      PlaylistContext.currentPathNotifier.addListener(_onPlaybackChanged);
    } catch (_) {}
    try {
      PlaylistContext.currentPageIdNotifier.addListener(_onPlaybackChanged);
    } catch (_) {}

    _allItems = List<File>.from(widget.items);
    _filteredItems = List<File>.from(_allItems);

    if (widget.enableSearch) {
      _searchController.addListener(_applySearch);
    }
  }

  @override
  void didUpdateWidget(covariant _BaseListPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _allItems = List<File>.from(widget.items);
      _applySearch();
    }
  }

  @override
  void dispose() {
    FavoritesNotifier.instance.removeListener(_onFavChanged);
    PlaybackState.isPlaying.removeListener(_onPlaybackChanged);
    try {
      PlaylistContext.currentPathNotifier.removeListener(_onPlaybackChanged);
    } catch (_) {}
    try {
      PlaylistContext.currentPageIdNotifier.removeListener(_onPlaybackChanged);
    } catch (_) {}
    _searchController.dispose();
    super.dispose();
  }

  void _onFavChanged() {
    if (mounted) setState(() {});
  }

  void _onPlaybackChanged() {
    if (mounted) setState(() {});
  }

  void _applySearch() {
    if (!widget.enableSearch) {
      _filteredItems = List<File>.from(_allItems);
      setState(() {});
      return;
    }

    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      _filteredItems = List<File>.from(_allItems);
    } else {
      _filteredItems = _allItems.where((file) {
        final name = p.basenameWithoutExtension(file.path).toLowerCase();
        return name.contains(query);
      }).toList();
    }
    if (mounted) setState(() {});
  }

  Color get _pageBackground =>
      isDark(context) ? AppPalette.darkBackground : Colors.white;
  Color get _cardColor =>
      isDark(context) ? AppPalette.darkCard : Colors.white;
  Color get _pageTextColor => isDark(context) ? Colors.white : Colors.black;
  Color get _pageSubtitleColor =>
      isDark(context) ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
  Color get _pageShadowColor => isDark(context)
      ? Colors.black.withOpacity(0.3)
      : Colors.black.withOpacity(0.06);

  Widget _buildCoverImage(File file, bool isFav) {
    final key = file.path;
    if (_coverCache.containsKey(key)) {
      final cached = _coverCache[key];
      if (cached != null && cached.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child:
          Image.memory(cached, width: 44, height: 44, fit: BoxFit.cover),
        );
      }
    }

    return FutureBuilder<Uint8List?>(
      future: widget.loadCoverForFile(file),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.done &&
            snap.hasData &&
            snap.data != null) {
          final bytes = snap.data!;
          _coverCache[key] = bytes;
          if (bytes.isNotEmpty) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(bytes,
                  width: 44, height: 44, fit: BoxFit.cover),
            );
          }
        }
        final placeholderColor =
        isDark(context) ? Colors.grey[800] : Colors.grey[100];
        final iconColor = isFav ? widget.color : _pageSubtitleColor;

        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: placeholderColor,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.music_note, color: iconColor, size: 20),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final dark = isDark(context);
    return AppBar(
      // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
      backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
      elevation: 0,
      foregroundColor: dark ? Colors.white : Colors.black,
      iconTheme: IconThemeData(color: dark ? Colors.white : Colors.black),
      systemOverlayStyle:
      dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      title: widget.enableSearch && _isSearching
          ? TextField(
        controller: _searchController,
        autofocus: true,
        cursorColor: widget.color,
        style: TextStyle(
          color: dark ? Colors.white : Colors.black,
          fontSize: 16,
        ),
        decoration: InputDecoration(
          hintText: widget.searchHint ?? 'Search...',
          hintStyle: TextStyle(
            color: dark ? Colors.grey.shade400 : Colors.grey.shade500,
          ),
          border: InputBorder.none,
        ),
      )
          : Text(widget.title),
      actions: [
        if (widget.enableSearch)
          IconButton(
            icon: Icon(_isSearching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _isSearching = !_isSearching;
                if (!_isSearching) {
                  _searchController.clear();
                  _applySearch();
                }
              });
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<File> items =
    widget.enableSearch ? _filteredItems : widget.items;

    return Scaffold(
      backgroundColor: _pageBackground,
      appBar: _buildAppBar(),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
        ],
      ),
      body: items.isEmpty
          ? _EmptyWidget(
        icon: widget.icon,
        title: widget.emptyMessage,
        subtitle: widget.emptySubtitle,
      )
          : Column(
        children: [
          if (widget.header != null) widget.header!,
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final file = items[index];
                final isFav = FavoritesNotifier.instance.contains(file.path);
                final currentPath = PlaylistContext.currentPathNotifier.value ?? PlaybackState.current.value;
                final isPlaying = PlaybackState.isPlaying.value;

                final isCurrent = (currentPath != null && currentPath == file.path);
                final showPause = isCurrent && isPlaying;
                final highlightColor = isCurrent ? widget.color.withOpacity(0.08) : _cardColor;
                final borderColor = isCurrent ? widget.color : null;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () async {
                        if (isCurrent) {
                          if (isPlaying) {
                            await PlaybackController.instance.pause();
                            if (widget.onPause != null) await Future.sync(() => widget.onPause(file));
                          } else {
                            await PlaybackController.instance.resume();
                            if (widget.onPlay != null) await Future.sync(() => widget.onPlay(file));
                          }
                        } else {
                          await PlaybackController.instance.setPlaylist(
                              items.map((f) => f.path).toList(),
                              startIndex: index,
                              play: true,
                              pageId: widget.pageId);
                          try {
                            await Future.sync(() => widget.onPlay(file));
                          } catch (_) {}
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: highlightColor,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [
                            BoxShadow(
                              color: _pageShadowColor,
                              blurRadius: 4,
                              offset: const Offset(0, 1),
                            ),
                          ],
                          border: borderColor != null
                              ? Border.all(
                              color: borderColor, width: 1)
                              : null,
                        ),
                        child: Row(
                          children: [
                            _buildCoverImage(file, isFav),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.basenameWithoutExtension(file.path),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: isCurrent
                                          ? widget.color
                                          : _pageTextColor,
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    widget.getSubtitle(file, index),
                                    style: TextStyle(
                                      color: isCurrent
                                          ? widget.color.withOpacity(0.9)
                                          : _pageSubtitleColor,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            AnimatedFavoriteButton(
                              isFavorite: isFav,
                              inactiveColor: _pageSubtitleColor,
                              size: 20,
                              onPressed: () async {
                                await Future.sync(
                                        () => widget.onToggleFavorite(file));
                                setState(() {});
                              },
                            ),
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: isDark(context)
                                    ? Colors.grey[800]
                                    : Colors.grey[100],
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.play_arrow, size: 18),
                                onPressed: () async {
                                  if (isCurrent) {
                                    if (isPlaying) {
                                      await PlaybackController.instance.pause();
                                      if (widget.onPause != null) await Future.sync(() => widget.onPause(file));
                                    } else {
                                      await PlaybackController.instance.resume();
                                      if (widget.onPlay != null) await Future.sync(() => widget.onPlay(file));
                                    }
                                  } else {
                                    await PlaybackController.instance
                                        .setPlaylist(
                                        items
                                            .map((f) => f.path)
                                            .toList(),
                                        startIndex: index,
                                        play: true,
                                        pageId: widget.pageId);
                                    await Future.sync(
                                            () => widget.onPlay(file));
                                  }
                                },
                                color: widget.color,
                                padding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (widget.bannerWidget != null)
            widget.bannerWidget!
          else
            const BannerAdWidget(),
        ],
      ),
    );
  }
}

class _EmptyWidget extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;

  const _EmptyWidget({
    required this.icon,
    required this.title,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    final surfaceColor = dark ? Colors.grey[800]! : Colors.grey[100]!;
    final primaryTextColor = dark ? Colors.white : Colors.black;
    final secondaryTextColor =
    dark ? Colors.grey.shade700 : const Color(0xFFB3B3B3);

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: surfaceColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 40, color: secondaryTextColor),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: primaryTextColor,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  subtitle!,
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}