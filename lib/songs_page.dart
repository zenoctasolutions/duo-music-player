// lib/songs_page.dart
import 'l10n/l10n.dart';
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:audio_session/audio_session.dart' show AudioSession, AudioInterruptionType;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';
import 'albums_page.dart';
import 'constants.dart';
import 'genres_page.dart';
import 'list_page.dart' hide PlaybackState;
import 'settings_page.dart';
import 'player_screen.dart';
import 'equalizer_screen.dart';
import 'ad_widgets.dart';
import 'audio_conversion_service.dart';
import 'audio_conversion_sheet.dart';
import 'audio_cutter.dart';
import 'audio_cutter_service.dart';
import 'radio_service.dart';
import 'radio_page.dart';
import 'media_store_service.dart';
import 'smart_mix_page.dart';
import 'home_widget_service.dart';
import 'duo_page.dart';
import 'duo_service.dart';
import 'app_palette.dart';
import 'library_service.dart';
import 'audio_effects_service.dart';
import 'crossfade_service.dart';
import 'tag_editor_page.dart';
import 'tag_editor_service.dart';
import 'auto_browse.dart';
import 'position_memory_service.dart';
import 'eq_profile_service.dart';
import 'queue_manager.dart';
import 'artwork_service.dart';
import 'lastfm_service.dart';
import 'cast_service.dart';
import 'favorite_button.dart';
import 'library/title_cleaner.dart';
import 'search/search_page.dart';
import 'shortcuts/shortcut_actions.dart';
import 'library/library_motion.dart';
import 'library/queue_actions.dart';
import 'player/now_playing_route.dart';
import 'ui/animated_nav_bar.dart';
import 'ui/app_page_bar.dart';
import 'ui/tab_body_switcher.dart';

const int kMaxTitleLength = 30;
const String kDefaultArt = 'images/music.png';
const String _kCachedAudioPathsKey = 'cached_audio_paths';
const String _prefKeyDark = 'settings_dark_mode';
const String _prefKeyFollowSystem = 'settings_follow_system';

class SongMeta {
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final Duration? duration;
  final Uint8List? cover;

  SongMeta({this.title, this.artist, this.album, this.year, this.duration, this.cover});
}

class _SongListItem {
  final bool isHeader;
  final String? letter;
  final File? file;
  final int? originalIndex;

  const _SongListItem.header(this.letter)
      : isHeader = true,
        file = null,
        originalIndex = null;

  const _SongListItem.song(this.file, this.originalIndex)
      : isHeader = false,
        letter = null;
}

class _NotificationAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  static Future<void> Function()? onPlay;
  static Future<void> Function()? onPause;
  static Future<void> Function()? onSkipNext;
  static Future<void> Function()? onSkipPrevious;
  static Future<void> Function()? onFastForward;
  static Future<void> Function()? onRewind;
  static Future<void> Function(Duration)? onSeek;
  static Future<void> Function()? onNotificationDismissed;
  static Future<void> Function()? onAppTaskRemoved;
  static Future<void> Function()? onStop;
  static Future<void> Function(String name)? onCustomAction;

  /// Android Auto / MediaBrowser support (see auto_browse.dart).
  static Future<AutoLibrary> Function()? autoLibrary;
  static Future<void> Function(List<String> queue, int index)? onPlayQueue;

  _NotificationAudioHandler() : super();

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    await onCustomAction?.call(name);
    return null;
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    final lib = await autoLibrary?.call();
    return lib == null ? const [] : AutoBrowse.children(parentMediaId, lib);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    final lib = await autoLibrary?.call();
    if (lib == null) return;
    final r = AutoBrowse.resolvePlay(mediaId, lib);
    if (r != null) await onPlayQueue?.call(r.$1, r.$2);
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    final lib = await autoLibrary?.call();
    return lib == null ? const [] : AutoBrowse.searchItems(query, lib);
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    final lib = await autoLibrary?.call();
    if (lib == null) return;
    final results = AutoBrowse.search(query, lib);
    if (results.isNotEmpty) await onPlayQueue?.call(results, 0);
  }

  @override
  Future<void> play() async {
    if (onPlay != null) await onPlay!();
  }

  @override
  Future<void> pause() async {
    if (onPause != null) await onPause!();
  }

  @override
  Future<void> stop() async {
    if (onStop != null) await onStop!();
  }

  @override
  Future<void> onNotificationDeleted() async {
    if (onNotificationDismissed != null) await onNotificationDismissed!();
  }

  @override
  Future<void> skipToNext() async {
    if (onSkipNext != null) await onSkipNext!();
  }

  @override
  Future<void> skipToPrevious() async {
    if (onSkipPrevious != null) await onSkipPrevious!();
  }

  @override
  Future<void> fastForward() async {
    if (onFastForward != null) await onFastForward!();
  }

  @override
  Future<void> rewind() async {
    if (onRewind != null) await onRewind!();
  }

  @override
  Future<void> seek(Duration position) async {
    if (onSeek != null) await onSeek!(position);
  }

  @override
  Future<void> onTaskRemoved() async {
    if (onAppTaskRemoved != null) await onAppTaskRemoved!();
  }
}

class AudioPlayerScreen extends StatefulWidget {
  const AudioPlayerScreen({super.key});

  @override
  _AudioPlayerScreenState createState() => _AudioPlayerScreenState();
}

class _AudioPlayerScreenState extends State<AudioPlayerScreen> with WidgetsBindingObserver, TickerProviderStateMixin {
  static _AudioPlayerScreenState? _current;

  final AudioPlayer _audioPlayer = AudioPlayer();
  List<File> _audioFiles = [];
  List<File> _filteredSongs = [];
  List<_SongListItem> _songDisplayItems = [];
  final Map<String, int> _audioIndexByPath = <String, int>{};

  bool _isLoading = false;
  int _currentIndex = -1;
  bool _isPlaying = false;
  Duration _currentPosition = Duration.zero;
  Duration _totalDuration = Duration.zero;
  // Opens on the user's chosen start screen (Settings → Appearance);
  // Library (merged List+Songs) by default.
  int _selectedTabIndex = AppPalette.startTab;
  late final TabController _libraryTabController;
  Set<String> _favorites = <String>{};
  double _playbackSpeed = 1.0;
  String _currentPlaylistSource = 'songs';

  StreamSubscription? _sleepSub;
  bool _sleepActive = false;
  Duration _sleepRemaining = Duration.zero;

  bool _followSystem = true;
  bool _userIsDark = false;

  final TextEditingController _songsSearchController = TextEditingController();
  final FocusNode _songsSearchFocusNode = FocusNode();
  bool _isSearchingInSongs = false;

  final Map<String, SongMeta> _metaCache = {};
  final Map<String, Uint8List?> _coverCache = {};
  final Map<String, String> _tempCoverFilePath = {};
  final Set<String> _loadingMetadataPaths = <String>{};

  Timer? _scanProgressTimer;
  int _lastScannedCount = 0;

  AudioHandler? _audioHandler;

  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<ProcessingState>? _processingStateSub;
  StreamSubscription<SequenceState?>? _sequenceStateSub;
  StreamSubscription<int?>? _currentIndexSub;
  String? _lastNotifiedMediaId;
  DateTime _lastPositionUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _lastPositionValue = Duration.zero;

  // Gapless playback: when attached, _audioPlayer.audioSource is exactly
  // this object (set via setAudioSource singular, never setAudioSources
  // plural — see _loadAndPlayNativeQueue) so the pre-existing
  // `audioSource is ConcatenatingAudioSource` check in _handleTrackComplete
  // reflects native-queue mode. Only entered for sequential playback
  // (shuffle/repeat-one/radio keep using the single-track _loadAndPlayFile
  // path unchanged).
  ConcatenatingAudioSource? _concatQueueSource;
  List<String>? _lastSyncedQueueSnapshot;

  bool get _shuffleEnabled => PlaylistContext.shuffleEnabledNotifier.value;
  bool get _isRepeatOne => _audioPlayer.loopMode == LoopMode.one;

  bool _loadedCacheOnStartup = false;
  int _playRequestSeq = 0;
  Timer? _searchDebounce;

  Color get _primaryColor => AppPalette.accent;
  Color get _secondaryColor => AppPalette.accentDark;

  @override
  void initState() {
    super.initState();
    _current = this;
    WidgetsBinding.instance.addObserver(this);

    _libraryTabController = TabController(length: 2, vsync: this, initialIndex: 0); // Overview first
    int lastLibrarySubTabIndex = _libraryTabController.index;
    _libraryTabController.addListener(() {
      // TabController's listener fires on every animation frame during a
      // swipe between sub-tabs, not just on settle — only rebuild (to
      // swap the AppBar's actions) when the rounded index actually flips.
      final current = _libraryTabController.index;
      if (current != lastLibrarySubTabIndex) {
        lastLibrarySubTabIndex = current;
        if (mounted) setState(() {});
      }
    });

    LibraryFilter.changes.addListener(_onLibraryFilterChanged);
    TagEditorService.edited.addListener(_onTagsEdited);
    SongSort.changes.addListener(_rebuildSongDisplayList);
    AppPalette.changes.addListener(_onPaletteChanged);
    unawaited(PlayStats.load());

    _setupAudioPlayer();
    _initFavorites();
    _loadThemePref();
    _songsSearchController.addListener(() => _filterSongsInSongsPage(_songsSearchController.text));
    _handlerReady = _initNotificationAudioHandler();

    _loadCachedAudioList().then((_) {
      unawaited(_consumeWidgetLaunchAction());
      // Launcher shortcuts ('Shuffle all' / 'Search'); the cached library is
      // loaded by now, so a cold-start shortcut has songs to work with.
      ShortcutActions.instance.attach(_onShortcutAction);
      if (_audioFiles.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _requestPermissionAndLoadSongs());
      } else {
        unawaited(_backgroundRescanIfPermitted());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Material You: the wallpaper accent may have changed while away.
    if (state == AppLifecycleState.resumed) unawaited(AppPalette.refreshSystemAccent());
  }

  /// Snapshot of the library for Android Auto's browse tree.
  Future<AutoLibrary> _buildAutoLibrary() async {
    await PlayStats.load();
    await RecentlyPlayedNotifier.instance.init();
    final playlists = <String, List<String>>{};
    try {
      for (final name in await PlaylistService.getPlaylistNames()) {
        playlists[name] = await PlaylistService.getPlaylist(name);
      }
    } catch (_) {}
    return AutoLibrary(
      allPaths: _audioFiles.map((f) => f.path).toList(),
      title: (path) {
        return TitleCleaner.title(_metaCache[path]?.title, path: path);
      },
      artist: (path) => TitleCleaner.artist(_metaCache[path]?.artist),
      favorites: FavoritesNotifier.instance.favoritesSet,
      recent: RecentlyPlayedNotifier.instance.paths.value,
      mostPlayed: PlayStats.mostPlayed(_audioFiles).map((f) => f.path).toList(),
      recentlyAdded: PlayStats.recentlyAdded(_audioFiles).map((f) => f.path).toList(),
      playlists: playlists,
    );
  }

  void _onCurrentPathForEffects() {
    final path = PlaylistContext.currentPathNotifier.value;
    unawaited(AudioEffectsService.instance.onTrackChanged(path));
    unawaited(PositionMemoryService.instance.onTrackChanged(path));
    unawaited(LastFmService.instance.onTrackChanged(path));
  }

  void _onPositionResumed() {
    final msg = PositionMemoryService.instance.resumed.value;
    if (msg == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 4),
      // Flutter keeps snackbars with an action on screen until dismissed
      // unless told otherwise; this one should time out.
      persist: false,
      action: SnackBarAction(
        label: 'Start over',
        onPressed: () {
          final path = PlaylistContext.currentPathNotifier.value;
          if (path != null) unawaited(PositionMemoryService.instance.forget(path));
          _audioPlayer.seek(Duration.zero);
        },
      ),
    ));
  }

  /// A song's tags were edited: drop its cached metadata/cover and reload.
  Future<void> _onTagsEdited() async {
    final path = TagEditorService.edited.value;
    if (path == null) return;
    _metaCache.remove(path);
    _coverCache.remove(path);
    _tempCoverFilePath.remove(path);
    try {
      final meta = await _loadFullMetadata(File(path));
      // The notification / home-screen widget show the playing song's
      // tags too — refresh them when that's the song that was edited.
      if (path == PlaylistContext.currentPathNotifier.value && !RadioPlaybackContext.isActive) {
        final item = await _buildMediaItem(File(path), meta);
        await _updateNotificationForMediaItem(item, playing: _isPlaying);
      }
    } catch (_) {}
    if (mounted) _rebuildSongDisplayList();
  }

  void _onLibraryFilterChanged() {
    // Excluded folders / minimum length changed: rescan so hidden songs drop
    // out (or come back) everywhere that uses the library list.
    unawaited(_loadAudioFilesIncremental());
  }

  void _onPaletteChanged() {
    if (!mounted) return;
    setState(() {});
    _applySystemUiOverlay();
  }

  Future<void> _backgroundRescanIfPermitted() async {
    if (!await _hasMusicPermission()) return;
    await _loadAudioFilesIncremental();
  }

  Future<bool> _hasMusicPermission() async {
    for (final permission in [
      Permission.storage,
      Permission.photos,
      Permission.mediaLibrary,
      Permission.audio,
    ]) {
      try {
        final status = await permission.status;
        if (status.isGranted || status.isLimited) return true;
      } catch (_) {}
    }
    return false;
  }

  bool get _effectiveIsDark {
    if (_followSystem) {
      final pb = WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return pb == Brightness.dark;
    }
    return _userIsDark;
  }

  Color get _backgroundColor => _effectiveIsDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _cardColor => _effectiveIsDark ? AppPalette.darkCard : Colors.white;
  Color get _textColor => _effectiveIsDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _subtitleColor => _effectiveIsDark ? Colors.white70 : const Color(0xFF8C8A9D);
  Color get _bottomNavBackground => _effectiveIsDark ? Colors.black : const Color(0xFFF8F9FD);
  Color get _bottomNavCardColor => _cardColor;
  bool get _useLogoNavGradient => _effectiveIsDark && !AppPalette.amoled && AppPalette.isLogoTheme;
  Color get _bottomNavSubtitleColor => _subtitleColor;

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    if (_followSystem && mounted) setState(() {});
  }

  Future<void> _loadThemePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _followSystem = prefs.getBool(_prefKeyFollowSystem) ?? true;
      _userIsDark = prefs.getBool(_prefKeyDark) ?? false;
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _onExternalThemeChange() async {
    await _loadThemePref();
    _applySystemUiOverlay();
  }

  Future<void> _saveThemePref({bool? followSystem, bool? isDark}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (followSystem != null) {
        await prefs.setBool(_prefKeyFollowSystem, followSystem);
        _followSystem = followSystem;
      }
      if (isDark != null) {
        await prefs.setBool(_prefKeyDark, isDark);
        _userIsDark = isDark;
      }
    } catch (_) {}
  }

  Future<void> _markRecentlyPlayed(String path) async {
    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(path);
      await PlayStats.recordPlay(path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }
  }

  void _applySystemUiOverlay() {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: _effectiveIsDark ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: _bottomNavCardColor,
      systemNavigationBarIconBrightness: _effectiveIsDark ? Brightness.light : Brightness.dark,
    ));
  }

  Future<void> _initNotificationAudioHandler() async {
    try {
      if (_audioHandler != null) return;

      _audioHandler = await AudioService.init(
        builder: () => _NotificationAudioHandler(),
        config: const AudioServiceConfig(
          androidNotificationChannelId: 'com.yourcompany.audio.channel',
          androidNotificationChannelName: 'Audio Playback',
          androidNotificationOngoing: true,
        ),
      );

      _NotificationAudioHandler.onPlay = _resumeAudioAndNotify;
      _NotificationAudioHandler.onPause = _pauseAudioAndNotify;
      _NotificationAudioHandler.onSkipNext = _playNextAndNotify;
      _NotificationAudioHandler.onSkipPrevious = _playPreviousAndNotify;
      _NotificationAudioHandler.onSeek = (position) async {
        await _audioPlayer.seek(position);
        _updatePlaybackState(playing: _isPlaying);
      };
      _NotificationAudioHandler.onFastForward = () async {
        await _audioPlayer.seek(_audioPlayer.position + const Duration(seconds: 30));
      };
      _NotificationAudioHandler.onRewind = () async {
        await _audioPlayer.seek(_audioPlayer.position - const Duration(seconds: 10));
      };
      _NotificationAudioHandler.onNotificationDismissed = _onNotificationDismissedAndNotify;
      _NotificationAudioHandler.onAppTaskRemoved = _onAppTaskRemoved;
      _NotificationAudioHandler.onStop = _stopRadio;
      _NotificationAudioHandler.onCustomAction = _onNotificationCustomAction;
      PlaylistContext.shuffleEnabledNotifier.removeListener(_scheduleNotificationRefresh);
      PlaylistContext.shuffleEnabledNotifier.addListener(_scheduleNotificationRefresh);
      _NotificationAudioHandler.autoLibrary = _buildAutoLibrary;
      _NotificationAudioHandler.onPlayQueue = (queue, index) async {
        if (queue.isEmpty) return;
        PlaylistContext.setCurrentPlaylist(queue, pageId: 'auto', folderPath: null);
        await PlaylistService.saveQueue(queue);
        await _playAudioByPath(queue[index.clamp(0, queue.length - 1)], source: 'auto');
      };
    } catch (e) {
      debugPrint('AudioService init error (notification handler): $e');
    }
  }

  Future<void> _resumeAudioAndNotify() async {
    if (await _restoreLastSessionIfIdle(play: true)) return;
    await _resumeAudio();
    await _updatePlaybackState(playing: true);
  }

  /// A home-screen widget button tapped while the app process was dead:
  /// NowPlayingWidgetProvider opened the app with that action instead of
  /// firing a media button into an engine that no longer exists. Run it
  /// now that the handler and cached library are ready.
  Future<void>? _handlerReady;

  Future<void> _consumeWidgetLaunchAction() async {
    String? action;
    try {
      await _handlerReady;
      action = await const MethodChannel('music_app/system').invokeMethod<String>('takeWidgetAction');
    } catch (_) {}
    switch (action) {
      case 'play':
        await _resumeAudioAndNotify();
      case 'next':
        await _playNextAndNotify();
      case 'previous':
        await _playPreviousAndNotify();
    }
  }

  /// Nothing is loaded in the player — a fresh process started from the
  /// home-screen widget / a headset button, or the player was stopped when
  /// the app was swiped away. A bare `play()` then does nothing audible
  /// while the UI/widget flip to "playing", so bring back the last queue
  /// and song instead. With [play] false only the queue context is
  /// restored (so next/previous move relative to the last song).
  /// Returns true when it started playback itself.
  bool _restoringSession = false;

  Future<bool> _restoreLastSessionIfIdle({required bool play}) async {
    if (RadioPlaybackContext.isActive) return false;
    // A second play arriving mid-restore must not start the song again.
    if (_restoringSession) return play;
    if (_audioPlayer.processingState != ProcessingState.idle) return false;
    _restoringSession = true;
    try {
      return await _restoreLastSession(play: play);
    } finally {
      _restoringSession = false;
    }
  }

  Future<bool> _restoreLastSession({required bool play}) async {

    String? path = PlaylistContext.currentPathNotifier.value;
    if (path == null) {
      try {
        await RecentlyPlayedNotifier.instance.init();
        final recent = RecentlyPlayedNotifier.instance.paths.value;
        if (recent.isNotEmpty) path = recent.first;
      } catch (_) {}
    }
    path ??= _audioFiles.isNotEmpty ? _audioFiles.first.path : null;
    if (path == null || !File(path).existsSync()) return false;

    var queue = PlaylistContext.getCurrentPlaylist();
    if (queue == null || !queue.contains(path)) {
      try {
        queue = await PlaylistService.getQueue();
      } catch (_) {
        queue = null;
      }
    }
    final source = PlaylistContext.getCurrentPageId() ?? 'restored';
    if (queue != null && queue.contains(path)) {
      PlaylistContext.setCurrentPlaylist(queue, pageId: source);
    }

    if (!play) {
      PlaylistContext.setCurrentPath(path);
      return false;
    }
    await _playAudioByPath(path, source: queue != null && queue.contains(path) ? source : 'songs');
    await _updatePlaybackState(playing: _isPlaying);
    return true;
  }

  Future<void> _pauseAudioAndNotify() async {
    await _pauseAudio();
    await _updatePlaybackState(playing: false);
  }

  Future<void> _onNotificationDismissedAndNotify() async {
    if (!_isPlaying) return;
    await _pauseAudioAndNotify();
  }

  Future<void> _onAppTaskRemoved() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint('Error stopping player on task removed: $e');
    }
    if (mounted) {
      setState(() => _isPlaying = false);
    } else {
      _isPlaying = false;
    }
    unawaited(HomeWidgetService.instance.updatePlayingState(false));
    try {
      await _audioHandler?.stop();
    } catch (e) {
      debugPrint('Error stopping audio handler on task removed: $e');
    }
  }

  Future<void> _playNextAndNotify() async {
    await _restoreLastSessionIfIdle(play: false);
    await _playNext();
    await _updatePlaybackState(playing: _isPlaying);
  }

  Future<void> _playPreviousAndNotify() async {
    await _restoreLastSessionIfIdle(play: false);
    await _playPrevious();
    await _updatePlaybackState(playing: _isPlaying);
  }

  // Notification controls: [favorite][prev][play/pause][next][shuffle]; the
  // compact view keeps the three standard ones (indices 1..3). Radio keeps
  // its stop/play layout (no favorite/shuffle).
  (List<MediaControl>, List<int>) _notificationControls(bool playing) {
    if (RadioPlaybackContext.isActive) {
      return (
        <MediaControl>[
          MediaControl.stop,
          if (playing) MediaControl.pause else MediaControl.play,
        ],
        const [0, 1],
      );
    }
    final mediaId = _audioHandler?.mediaItem.value?.id;
    if (mediaId == null) {
      return (
        <MediaControl>[
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        const [0, 1, 2],
      );
    }
    final isFav = FavoritesNotifier.instance.contains(mediaId);
    final shuffleOn = PlaylistContext.shuffleEnabledNotifier.value;
    return (
      <MediaControl>[
        MediaControl.custom(
          androidIcon: isFav ? 'drawable/ic_notif_favorite_filled' : 'drawable/ic_notif_favorite',
          label: isFav ? 'Remove from favorites' : 'Add to favorites',
          name: 'toggle_favorite',
        ),
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
        MediaControl.custom(
          androidIcon: shuffleOn ? 'drawable/ic_notif_shuffle_on' : 'drawable/ic_notif_shuffle',
          label: shuffleOn ? 'Shuffle on' : 'Shuffle off',
          name: 'toggle_shuffle',
        ),
      ],
      const [1, 2, 3],
    );
  }

  Timer? _notifRefreshTimer;

  /// Coalesced refresh of the notification buttons (favorite/shuffle state).
  void _scheduleNotificationRefresh() {
    _notifRefreshTimer?.cancel();
    _notifRefreshTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted || _audioHandler == null) return;
      unawaited(_updatePlaybackState(playing: _isPlaying));
    });
  }

  Future<void> _onNotificationCustomAction(String name) async {
    if (name == 'toggle_favorite') {
      final id = _audioHandler?.mediaItem.value?.id;
      if (id == null || RadioPlaybackContext.isActive) return;
      try {
        if (!FavoritesNotifier.instance.initialized) await FavoritesNotifier.instance.init();
        await FavoritesNotifier.instance.toggle(id);
      } catch (e) {
        debugPrint('Notification favorite toggle failed: $e');
      }
      _scheduleNotificationRefresh();
    } else if (name == 'toggle_shuffle') {
      final newVal = !PlaylistContext.shuffleEnabledNotifier.value;
      PlaylistContext.setShuffleEnabled(newVal);
      try {
        await _audioPlayer.setShuffleModeEnabled(newVal);
      } catch (e) {
        debugPrint('setShuffleModeEnabled error: $e');
      }
      _scheduleNotificationRefresh();
    }
  }

  Future<void> _updateNotificationForMediaItem(MediaItem item, {bool playing = true}) async {
    unawaited(HomeWidgetService.instance.updateNowPlaying(
      title: item.title,
      artist: item.artist ?? '',
      isPlaying: playing,
      coverPath: item.artUri?.toFilePath(),
    ));
    try {
      if (_audioHandler == null) return;
      _lastNotifiedMediaId = item.id;
      try {
        (_audioHandler as dynamic).mediaItem.add(item);
      } catch (e) {
        debugPrint('Warning: could not call mediaItem.add via dynamic cast: $e');
      }

      final (controls, compactIndices) = _notificationControls(playing);

      final pbState = PlaybackState(
        controls: controls,
        androidCompactActionIndices: compactIndices,
        systemActions: const {MediaAction.seek},
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: _currentPosition,
        bufferedPosition: _audioPlayer.bufferedPosition,
        speed: _playbackSpeed,
      );

      try {
        (_audioHandler as dynamic).playbackState.add(pbState);
      } catch (e) {
        debugPrint('Warning: could not call playbackState.add via dynamic cast: $e');
      }
    } catch (e) {
      debugPrint('Error updating notification media item: $e');
    }
  }

  Future<void> _updatePlaybackState({required bool playing}) async {
    unawaited(HomeWidgetService.instance.updatePlayingState(playing));
    try {
      if (_audioHandler == null) return;

      final (controls, compactIndices) = _notificationControls(playing);

      final pbState = PlaybackState(
        controls: controls,
        androidCompactActionIndices: compactIndices,
        systemActions: const {MediaAction.seek},
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: _currentPosition,
        bufferedPosition: _audioPlayer.bufferedPosition,
        speed: _playbackSpeed,
      );

      try {
        (_audioHandler as dynamic).playbackState.add(pbState);
      } catch (e) {
        debugPrint('Warning: could not call playbackState.add via dynamic cast: $e');
      }
    } catch (e) {
      debugPrint('Error updating playback state: $e');
    }
  }

  Future<void> _initFavorites() async {
    try {
      await FavoritesNotifier.instance.init();
      if (!mounted) return;
      setState(() {
        _favorites = Set<String>.from(FavoritesNotifier.instance.favoritesSet);
      });
      FavoritesNotifier.instance.addListener(_onFavoritesChanged);
    } catch (e) {
      debugPrint('Error init favorites: $e');
    }
  }

  void _onFavoritesChanged() {
    if (!mounted) return;
    _scheduleNotificationRefresh();
    setState(() {
      _favorites = Set<String>.from(FavoritesNotifier.instance.favoritesSet);
    });
  }

  StreamSubscription? _interruptionSub;
  StreamSubscription? _noisySub;
  DateTime? _interruptedPlayingAt;

  /// Logs every audio-focus interruption (so an unexplained pause can be
  /// traced) and resumes after a transient loss that just_audio's own
  /// handling missed. Permanent loss (another music app took over) is never
  /// resumed, and ducking never pauses.
  Future<void> _watchAudioInterruptions() async {
    try {
      final session = await AudioSession.instance;
      _interruptionSub?.cancel();
      _noisySub?.cancel();
      _interruptionSub = session.interruptionEventStream.listen((e) {
        debugPrint('AudioFocus interruption begin=${e.begin} type=${e.type} playing=${_audioPlayer.playing}');
        if (e.begin) {
          if (e.type == AudioInterruptionType.pause && _audioPlayer.playing) {
            _interruptedPlayingAt = DateTime.now();
          }
          return;
        }
        final at = _interruptedPlayingAt;
        _interruptedPlayingAt = null;
        if (at == null || e.type != AudioInterruptionType.pause) return;
        if (DateTime.now().difference(at) < const Duration(minutes: 2)) {
          Future.delayed(const Duration(milliseconds: 400), () {
            if (mounted && !_audioPlayer.playing && !DuoService.instance.lastState.anyPlaying) {
              debugPrint('AudioFocus: resuming after transient loss');
              _audioPlayer.play();
            }
          });
        }
      });
      _noisySub = session.becomingNoisyEventStream.listen((_) {
        debugPrint('AudioFocus: becoming noisy (output route lost) playing=${_audioPlayer.playing}');
      });
    } catch (e) {
      debugPrint('AudioSession watch failed: $e');
    }
  }

  void _setupAudioPlayer() {
    unawaited(_watchAudioInterruptions());
    // Duo Mode and the main player/radio never play at the same time: Duo
    // pauses this player before it starts, and this player starting pauses Duo.
    DuoService.instance.onBeforePlay = () {
      if (_audioPlayer.playing) _audioPlayer.pause();
    };
    // Sound effects + volume normalization follow the player's audio
    // session and the currently playing file.
    unawaited(AudioEffectsService.instance.attach(_audioPlayer));
    unawaited(CrossfadeService.instance.attach(_audioPlayer, advance: _playNextAndNotify));
    unawaited(PositionMemoryService.instance.attach(_audioPlayer));
    unawaited(EqProfileService.instance.attach(_audioPlayer));
    unawaited(QueueManager.instance.attach(_audioPlayer));
    CastService.instance.attach(_audioPlayer, (path) async {
      final m = _metaCache[path] ?? await _loadFullMetadata(File(path));
      return (title: m.title, artist: m.artist, album: m.album, coverPath: _tempCoverFilePath[path]);
    });
    unawaited(LastFmService.instance.attach(_audioPlayer, (path) async {
      final m = _metaCache[path] ?? await _loadFullMetadata(File(path));
      return (artist: m.artist, title: m.title, album: m.album);
    }));
    QueueManager.instance.onLoad = (q) async {
      final existing = q.paths.where((path) => File(path).existsSync()).toList();
      if (existing.isEmpty) return;
      final start = (q.currentPath != null && existing.contains(q.currentPath)) ? q.currentPath! : existing.first;
      PlaylistContext.setCurrentPlaylist(existing, pageId: 'queue', folderPath: null);
      await PlaylistService.saveQueue(existing);
      await _playAudioByPath(start, source: 'queue');
      if (start == q.currentPath && q.positionMs > 3000) {
        await _audioPlayer.seek(Duration(milliseconds: q.positionMs));
      }
    };
    PositionMemoryService.instance.resumed.removeListener(_onPositionResumed);
    PositionMemoryService.instance.resumed.addListener(_onPositionResumed);
    PlaylistContext.currentPathNotifier.removeListener(_onCurrentPathForEffects);
    PlaylistContext.currentPathNotifier.addListener(_onCurrentPathForEffects);
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _processingStateSub?.cancel();
    _sequenceStateSub?.cancel();
    _currentIndexSub?.cancel();
    PlaylistContext.currentPlaylistNotifier.removeListener(_onQueueContextChanged);
    PlaylistContext.currentPlaylistNotifier.addListener(_onQueueContextChanged);

    _sequenceStateSub = _audioPlayer.sequenceStateStream.listen((seqState) {
      final tag = seqState?.currentSource?.tag;
      if (tag is MediaItem && tag.id != _lastNotifiedMediaId) {
        _updateNotificationForMediaItem(tag, playing: _audioPlayer.playing);
      }
    });

    // Gapless (native-queue) track transitions never carry a MediaItem tag
    // (see _loadAndPlayNativeQueue — light {'filePath': path} tags only, so
    // entering native mode never has to eagerly read metadata for an entire
    // queue), so the sequenceStateStream listener above never fires for them.
    // This is the index/PlaylistContext/notification-refresh path for that case.
    _currentIndexSub = _audioPlayer.currentIndexStream.listen((index) {
      if (_concatQueueSource == null || index == null) return;
      unawaited(_onNativeIndexChanged(index));
    });

    _playerStateSub = _audioPlayer.playerStateStream.listen((playerState) {
      if (!mounted) return;
      final playing = playerState.playing;

      if (!playing) {
        try {
          _currentPosition = _audioPlayer.position;
        } catch (_) {}
      }

      if (playing) unawaited(DuoService.instance.pauseIfActive());

      if (_isPlaying != playing) {
        setState(() => _isPlaying = playing);
        _updatePlaybackState(playing: playing);
      }
    });

    _positionSub = _audioPlayer.positionStream.listen((position) {
      final playingNow = _audioPlayer.playing;
      final now = DateTime.now();
      final msDiff = (position - _lastPositionValue).inMilliseconds.abs();
      final timeSinceLast = now.difference(_lastPositionUpdate).inMilliseconds;

      if (playingNow) {
        _lastPositionUpdate = now;
        _lastPositionValue = position;
        _currentPosition = position;
      } else if (msDiff > 500 && timeSinceLast > 800) {
        _lastPositionUpdate = now;
        _lastPositionValue = position;
        _currentPosition = position;
      }
    });

    _processingStateSub = _audioPlayer.processingStateStream.listen((processingState) {
      if (processingState == ProcessingState.completed) {
        _handleTrackComplete();
      }
    });

    _audioPlayer.durationStream.listen((duration) {
      if (!mounted) return;
      final d = duration ?? Duration.zero;
      if (_totalDuration != d) {
        setState(() => _totalDuration = d);
      }
    });
  }

  Future<void> _loadCachedAudioList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getStringList(_kCachedAudioPathsKey) ?? [];
      if (cached.isEmpty) {
        _loadedCacheOnStartup = true;
        return;
      }
      final List<File> files = [];
      for (final path in cached.toSet()) {
        try {
          final f = File(path);
          if (await f.exists()) files.add(f);
        } catch (_) {}
      }
      if (files.isNotEmpty) {
        _audioFiles = files;
        _filteredSongs = List<File>.from(_audioFiles);
        _isLoading = false;
        _rebuildAudioIndexMap();
        _rebuildSongDisplayList();
        unawaited(_preloadBasicMetadata());
      }
    } catch (e) {
      debugPrint('Error loading cached audio list: $e');
    } finally {
      _loadedCacheOnStartup = true;
    }
  }

  Future<void> _saveCachedAudioList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final paths = _audioFiles.map((f) => f.path).toList();
      await prefs.setStringList(_kCachedAudioPathsKey, paths);
    } catch (e) {
      debugPrint('Error saving cached audio list: $e');
    }
  }

  Future<void> _requestPermissionAndLoadSongs({bool forceRescan = false}) async {
    if (!forceRescan && _audioFiles.isNotEmpty && _loadedCacheOnStartup) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    setState(() => _isLoading = true);

    final statuses = await [
      Permission.storage,
      Permission.photos,
      Permission.mediaLibrary,
      Permission.audio,
    ].request();

    final granted = statuses.values.any((s) => s.isGranted || s.isLimited);

    if (granted) {
      unawaited(_loadAudioFilesIncremental());
    } else {
      setState(() => _isLoading = false);
      _showPermissionDeniedDialog();
    }
  }

  Future<String> _canonicalPath(File f) async {
    try {
      final resolved = await f.resolveSymbolicLinks();
      return p.normalize(resolved).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      try {
        return p.normalize(f.absolute.path).replaceAll('\\', '/').toLowerCase();
      } catch (_) {
        return f.path.toLowerCase();
      }
    }
  }

  void _rebuildAudioIndexMap() {
    _audioIndexByPath.clear();
    for (int i = 0; i < _audioFiles.length; i++) {
      _audioIndexByPath[_audioFiles[i].path] = i;
    }
  }

  String _sortKeyText(File file) {
    switch (SongSort.field) {
      case SongSortField.artist:
        return TitleCleaner.artist(_metaCache[file.path]?.artist) ?? 'Unknown artist';
      case SongSortField.album:
        final a = _metaCache[file.path]?.album?.trim();
        return (a != null && a.isNotEmpty) ? a : 'Unknown album';
      case SongSortField.fileName:
        return p.basename(file.path);
      default:
        return _songTitleForSort(file);
    }
  }

  int _durationMsFor(File file) =>
      LibraryInfo.durationMs[file.path] ?? _metaCache[file.path]?.duration?.inMilliseconds ?? 0;

  String _sectionLetterFor(File file) {
    final text = _sortKeyText(file).trim();
    if (text.isEmpty) return '#';

    // Digits, symbols and non-Latin scripts all share one '#' group.
    return TitleCleaner.sectionLetter(text);
  }

  String _songTitleForSort(File file) {
    return TitleCleaner.title(_metaCache[file.path]?.title, path: file.path);
  }

  void _rebuildSongDisplayList() {
    final source = _isSearchingInSongs ? _filteredSongs : _audioFiles;
    // Never show the same path twice (stale cache / double-added conversions).
    final seenPaths = <String>{};
    final sorted = source.where((f) => seenPaths.add(f.path)).toList();

    final field = SongSort.field;
    final dir = SongSort.ascending ? 1 : -1;
    int byTitle(File a, File b) {
      final c = _songTitleForSort(a).toLowerCase().compareTo(_songTitleForSort(b).toLowerCase());
      if (c != 0) return c;
      return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
    }

    sorted.sort((a, b) {
      int c;
      switch (field) {
        case SongSortField.dateAdded:
          c = LibraryInfo.dateAddedFor(a.path).compareTo(LibraryInfo.dateAddedFor(b.path));
          break;
        case SongSortField.duration:
          c = _durationMsFor(a).compareTo(_durationMsFor(b));
          break;
        case SongSortField.title:
          c = 0;
          break;
        default:
          c = _sortKeyText(a).toLowerCase().compareTo(_sortKeyText(b).toLowerCase());
      }
      if (c == 0) c = byTitle(a, b);
      return c * dir;
    });

    final items = <_SongListItem>[];
    String? currentLetter;
    final letterHeaders = SongSort.usesLetterHeaders(field);

    if (letterHeaders) {
      // Keep every '#' title (digits, symbols, non-Latin) in one block so it
      // gets a single header: before A when ascending, after Z when descending.
      final hash = <File>[];
      final letters = <File>[];
      for (final f in sorted) {
        (_sectionLetterFor(f) == '#' ? hash : letters).add(f);
      }
      sorted
        ..clear()
        ..addAll(SongSort.ascending ? [...hash, ...letters] : [...letters, ...hash]);
    }

    for (final file in sorted) {
      final idx = _audioIndexByPath[file.path] ?? _audioFiles.indexWhere((f) => f.path == file.path);
      if (letterHeaders) {
        final letter = _sectionLetterFor(file);
        if (letter != currentLetter) {
          items.add(_SongListItem.header(letter));
          currentLetter = letter;
        }
      }
      items.add(_SongListItem.song(file, idx));
    }

    _songDisplayItems = items;
    if (mounted) setState(() {});
  }

  Future<void> _loadAudioFilesIncremental() async {
    _scanProgressTimer?.cancel();
    _lastScannedCount = 0;
    _scanProgressTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });

    final bool hadExistingSongs = _audioFiles.isNotEmpty;

    setState(() {
      _isLoading = true;
      if (!hadExistingSongs) {
        _audioFiles = [];
        _filteredSongs = [];
        _songDisplayItems = [];
        _audioIndexByPath.clear();
      }
    });

    try {
      // Prefer the OS's already-indexed MediaStore over a manual recursive
      // directory walk — MediaStore.Audio.Media is kept current by the
      // system media scanner, so this is a fast indexed query (and always
      // includes newly-added files) rather than a filesystem crawl across a
      // dozen+ storage roots on every single app open. Only fall back to
      // the manual walk if MediaStore is unavailable (non-Android) or the
      // query itself fails.
      await LibraryFilter.load();
      final mediaStorePaths = await MediaStoreService.instance.queryAudioFilePaths(onEntries: LibraryInfo.ingest);
      final rawPaths = mediaStorePaths ?? await _scanFilesystemForAudio(hadExistingSongs: hadExistingSongs);

      await _applyScannedPaths(rawPaths);
      debugPrint('Loaded ${_audioFiles.length} unique audio files'
          '${mediaStorePaths != null ? ' via MediaStore' : ' via filesystem walk'}.');
    } catch (e) {
      debugPrint('Error loading audio files: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } finally {
      _scanProgressTimer?.cancel();
      _scanProgressTimer = null;
      _lastScannedCount = _audioFiles.length;
      if (mounted) setState(() {});
    }
  }

  /// Manual recursive directory walk — the pre-MediaStore scan strategy,
  /// kept only as a fallback for platforms/devices where the MediaStore
  /// query isn't available. Returns raw candidate paths (not yet deduped —
  /// [_applyScannedPaths] handles that for both scan strategies).
  Future<List<String>> _scanFilesystemForAudio({required bool hadExistingSongs}) async {
    final seen = <String>{};
    final extensions = ['.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.opus'];
    final List<String> candidatePaths = [];
    final List<File> scannedFiles = <File>[];

    try {
      final musicDirs = await getExternalStorageDirectories(type: StorageDirectory.music);
      if (musicDirs != null && musicDirs.isNotEmpty) {
        for (final d in musicDirs) {
          if (d != null && d.path.isNotEmpty) candidatePaths.add(d.path);
        }
      }
    } catch (_) {}

    candidatePaths.addAll([
      '/storage/emulated/0/Music',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Downloads',
      '/storage/emulated/0/Movies',
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/Android/media',
      '/storage/emulated/0/Android/data',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Audio',
      '/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes',
      '/storage/emulated/0/Telegram/Telegram Audio',
      '/storage/emulated/0/Ringtones',
      '/storage/emulated/0/Notifications',
      '/storage/emulated/0/Alarms',
      '/storage/emulated/0/Bluetooth',
      '/storage/emulated/0/ShareMe',
      '/storage/emulated/0/.hidden',
    ]);

    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null && ext.path.isNotEmpty) candidatePaths.add(ext.path);
    } catch (_) {}

    final normalizedRoots = <String>{};
    for (final cp in candidatePaths) {
      try {
        final np = p.normalize(cp).replaceAll(RegExp(r'[/\\]+$'), '');
        if (np.trim().isNotEmpty) normalizedRoots.add(np);
      } catch (_) {}
    }

    const int batchSize = 10;
    int batchCounter = 0;
    bool firstUpdateDone = false;

    for (final root in normalizedRoots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;

      try {
        final stream = dir.list(recursive: true, followLinks: false);
        await for (final entity in stream) {
          if (entity is File) {
            final lower = entity.path.toLowerCase();
            if (!extensions.any((ext) => lower.endsWith(ext))) continue;

            try {
              final fstat = await entity.stat();
              if (fstat.size == 0) continue;
            } catch (_) {
              continue;
            }

            final baseName = p.basename(entity.path);
            if (baseName.startsWith('.') || baseName.startsWith('._') || baseName.contains('tmp')) continue;

            final canonical = await _canonicalPath(entity);

            if (seen.contains(canonical)) continue;
            seen.add(canonical);

            scannedFiles.add(File(entity.path));
            batchCounter++;
            _lastScannedCount = scannedFiles.length;

            if (!hadExistingSongs &&
                (batchCounter % batchSize == 0 || (!firstUpdateDone && scannedFiles.isNotEmpty))) {
              firstUpdateDone = true;
              if (!mounted) return scannedFiles.map((f) => f.path).toList();
              setState(() {
                _audioFiles = List<File>.from(scannedFiles);
                _filteredSongs = List<File>.from(_audioFiles);
              });
            }
          }
        }
      } catch (e) {
        debugPrint('Error scanning $root: $e');
      }
    }

    return scannedFiles.map((f) => f.path).toList();
  }

  /// Common tail for both scan strategies: extension/name filtering, an
  /// existence check (MediaStore rows can briefly lag a deletion), dedup by
  /// canonical path, then applying the result to app state.
  Future<void> _applyScannedPaths(List<String> rawPaths) async {
    final extensions = ['.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.opus'];
    final Map<String, File> uniqueMap = {};

    for (final path in rawPaths) {
      final lower = path.toLowerCase();
      if (!extensions.any((ext) => lower.endsWith(ext))) continue;

      final baseName = p.basename(path);
      if (baseName.startsWith('.') || baseName.startsWith('._') || baseName.contains('tmp')) continue;

      // User library filters (Settings → Library filters).
      if (!LibraryFilter.allows(path, knownDurationMs: _metaCache[path]?.duration?.inMilliseconds)) continue;

      final file = File(path);
      try {
        if (!await file.exists()) continue;
      } catch (_) {
        continue;
      }

      String canonical;
      try {
        canonical = await _canonicalPath(file);
      } catch (_) {
        canonical = p.normalize(path).toLowerCase();
      }
      uniqueMap.putIfAbsent(canonical, () => file);
    }

    final finalList = _dropDuplicateCopies(uniqueMap.values.toList());
    // Same key as the Songs tab (cleaned title), so the queue the player
    // builds from this list follows the order the user sees.
    finalList.sort((a, b) {
      final c = _songTitleForSort(a).toLowerCase().compareTo(_songTitleForSort(b).toLowerCase());
      if (c != 0) return c;
      return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
    });

    final newPaths = finalList.map((f) => f.path).toSet();
    _metaCache.removeWhere((path, _) => !newPaths.contains(path));
    _coverCache.removeWhere((path, _) => !newPaths.contains(path));
    _tempCoverFilePath.removeWhere((path, _) => !newPaths.contains(path));

    if (mounted) {
      setState(() {
        _audioFiles = finalList;
        _filteredSongs = List<File>.from(_audioFiles);
        _isLoading = false;
      });
    } else {
      _audioFiles = finalList;
      _filteredSongs = List<File>.from(_audioFiles);
    }

    _rebuildAudioIndexMap();
    await _saveCachedAudioList();

    unawaited(_preloadBasicMetadata());
    _rebuildSongDisplayList();
  }

  /// Removes byte-for-byte copies of the same file kept in different folders
  /// (e.g. Music + Download). Two files merge only when their cleaned file
  /// names match, their sizes are identical and their durations are within
  /// 1s (both known) — anything else is kept. The copy in the main Music
  /// folder wins, otherwise the first one found.
  List<File> _dropDuplicateCopies(List<File> files) {
    final groups = <String, List<File>>{};
    final out = <File>[];
    for (final f in files) {
      final size = LibraryInfo.sizeBytes[f.path] ?? 0;
      final dur = LibraryInfo.durationMs[f.path] ?? 0;
      if (size <= 0 || dur <= 0) {
        out.add(f);
        continue;
      }
      final name = TitleCleaner.title(null, path: f.path).toLowerCase();
      groups.putIfAbsent('$size|$name', () => []).add(f);
    }
    bool inMusic(File f) => f.path.toLowerCase().contains('/music/');
    for (final g in groups.values) {
      final clusters = <List<File>>[];
      for (final f in g) {
        final d = LibraryInfo.durationMs[f.path]!;
        final c = clusters.firstWhere(
          (c) => (LibraryInfo.durationMs[c.first.path]! - d).abs() <= 1000,
          orElse: () {
            final n = <File>[];
            clusters.add(n);
            return n;
          },
        );
        c.add(f);
      }
      for (final c in clusters) {
        out.add(c.firstWhere(inMusic, orElse: () => c.first));
      }
    }
    return out;
  }

  Future<void> _preloadBasicMetadata() async {
    for (final file in _audioFiles) {
      if (_metaCache.containsKey(file.path)) continue;
      try {
        SongMeta sm;
        try {
          final meta = await readMetadata(File(file.path), getImage: false);
          sm = _fromRawMeta(meta, cover: null);
        } catch (e) {
          debugPrint('metadata preload error for ${file.path}: $e');
          sm = SongMeta(title: p.basenameWithoutExtension(file.path), artist: null, album: null, year: null, duration: null, cover: null);
        }
        if (!mounted) return;
        _metaCache[file.path] = sm;
      } catch (e) {
        debugPrint('metadata preload unexpected error for ${file.path}: $e');
      }
    }
    if (mounted) {
      setState(() {});
      _rebuildSongDisplayList();
    }
  }

  SongMeta _fromRawMeta(dynamic meta, {Uint8List? cover}) {
    try {
      String? title;
      String? artist;
      String? album;
      int? year;
      Duration? duration;

      if (meta == null) {
        return SongMeta(title: null, artist: null, album: null, year: null, duration: null, cover: cover);
      }

      try {
        if (meta.title != null && (meta.title is String && (meta.title as String).isNotEmpty)) title = meta.title as String;
      } catch (_) {}
      try {
        if (meta.artist != null && (meta.artist is String && (meta.artist as String).isNotEmpty)) artist = meta.artist as String;
      } catch (_) {}
      try {
        if (meta.album != null && (meta.album is String && (meta.album as String).isNotEmpty)) album = meta.album as String;
      } catch (_) {}

      try {
        if (meta.year != null) {
          final v = meta.year;
          if (v is int) year = v;
          else if (v is String) year = int.tryParse(v);
        } else if (meta.date != null) {
          final v = meta.date;
          if (v is DateTime) year = v.year;
          else if (v is String) {
            final parsed = DateTime.tryParse(v);
            if (parsed != null) year = parsed.year;
          }
        }
      } catch (_) {}

      try {
        if (meta.duration != null) {
          final d = meta.duration;
          if (d is int) duration = Duration(milliseconds: d);
          else if (d is double) duration = Duration(milliseconds: d.toInt());
          else if (d is Duration) duration = d;
        }
      } catch (_) {}

      Uint8List? cov = cover;
      if (cov == null) {
        try {
          if (meta.picture != null) {
            final p0 = meta.picture;
            if (p0 is Uint8List) cov = p0;
            else if (p0 is List<int>) cov = Uint8List.fromList(p0);
            else if (p0 is Map && p0['data'] != null) {
              final d = p0['data'];
              if (d is List<int>) cov = Uint8List.fromList(d);
            }
          }
        } catch (_) {}
      }

      if (cov == null) {
        try {
          if (meta.albumArt != null) {
            final a = meta.albumArt;
            if (a is Uint8List) cov = a;
            else if (a is List<int>) cov = Uint8List.fromList(a.cast<int>());
          }
        } catch (_) {}
      }

      if (cov == null) {
        try {
          if (meta.images != null && meta.images is List && meta.images.isNotEmpty) {
            final first = meta.images[0];
            if (first is Uint8List) cov = first;
            else if (first is List<int>) cov = Uint8List.fromList(first.cast<int>());
            else if (first is Map && first['data'] != null) {
              final d = first['data'];
              if (d is List<int>) cov = Uint8List.fromList(d.cast<int>());
            }
          }
        } catch (_) {}
      }

      if (cov == null) {
        try {
          if (meta.pictures != null && meta.pictures is List && meta.pictures.isNotEmpty) {
            final first = meta.pictures[0];
            try {
              if (first is Map && first['bytes'] != null && first['bytes'] is List<int>) cov = Uint8List.fromList(List<int>.from(first['bytes']));
              else if (first is Uint8List) cov = first;
              else if (first is List<int>) cov = Uint8List.fromList(first);
              else {
                final dynamic dyn = first;
                final b = dyn.bytes;
                if (b != null) {
                  if (b is Uint8List) cov = b;
                  else if (b is List<int>) cov = Uint8List.fromList(b.cast<int>());
                }
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      return SongMeta(title: title, artist: artist, album: album, year: year, duration: duration, cover: cov);
    } catch (e) {
      debugPrint('Error parsing metadata: $e');
      return SongMeta(cover: cover);
    }
  }

  Future<SongMeta> _loadFullMetadata(File file) async {
    try {
      final cached = _metaCache[file.path];
      if (cached != null && cached.cover != null) return cached;

      dynamic raw;
      try {
        raw = await readMetadata(File(file.path), getImage: true);
      } catch (e) {
        debugPrint('Error reading metadata (file may not be parsable): $e');
      }

      Uint8List? cover;
      if (raw != null) {
        try {
          final pics = raw.pictures;
          if (pics is List && pics.isNotEmpty) {
            final first = pics.first;
            if (first is Uint8List) cover = first;
            else if (first is List<int>) cover = Uint8List.fromList(first.cast<int>());
            else if (first is dynamic) {
              final b = first.bytes;
              if (b is Uint8List) cover = b;
              else if (b is List<int>) cover = Uint8List.fromList(b.cast<int>());
            }
          }
        } catch (e) {
          debugPrint('No pictures field or extraction error: $e');
        }

        if (cover == null) {
          final fallbackFields = ['image', 'picture', 'album_image', 'cover', 'artwork', 'thumbnail'];
          for (final field in fallbackFields) {
            try {
              final data = raw[field];
              if (data is Uint8List) {
                cover = data;
                break;
              } else if (data is List<int>) {
                cover = Uint8List.fromList(data.cast<int>());
                break;
              }
            } catch (_) {}
          }
        }
      }

      cover ??= await _getExternalCover(file.path);
      if (cover == null) {
        // Previously downloaded album art (Settings → Appearance), else
        // look it up in the background when that option is on.
        final tags = _fromRawMeta(raw, cover: null);
        cover = await ArtworkService.instance.cached(artist: tags.artist, album: tags.album, title: tags.title);
        if (cover == null) _fetchArtworkInBackground(file.path, tags);
      }
      final meta = _fromRawMeta(raw, cover: cover);

      _metaCache[file.path] = meta;
      if (cover != null) _coverCache[file.path] = cover;

      return meta;
    } catch (e) {
      debugPrint('Error loading full metadata for ${file.path}: $e');
      final fallback = _metaCache[file.path] ?? SongMeta(title: p.basenameWithoutExtension(file.path));
      return fallback;
    }
  }

  void _fetchArtworkInBackground(String path, SongMeta tags) {
    unawaited(() async {
      final bytes = await ArtworkService.instance.fetch(artist: tags.artist, album: tags.album, title: tags.title);
      if (bytes == null || !mounted) return;
      final m = _metaCache[path] ?? tags;
      _metaCache[path] = SongMeta(title: m.title, artist: m.artist, album: m.album, year: m.year, duration: m.duration, cover: bytes);
      _coverCache[path] = bytes;
      _tempCoverFilePath.remove(path);
      setState(() {});
      ArtworkService.instance.downloaded.value = null;
      ArtworkService.instance.downloaded.value = path;
      // The playing song got its cover: refresh notification / widget art.
      if (path == PlaylistContext.currentPathNotifier.value && !RadioPlaybackContext.isActive) {
        final item = await _buildMediaItem(File(path), _metaCache[path]!);
        await _updateNotificationForMediaItem(item, playing: _isPlaying);
      }
    }());
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
              'cover.png',
              'folder.jpg',
              'folder.jpeg',
              'album.jpg',
              'album.jpeg',
              'artwork.jpg',
              'artwork.png',
              'front.jpg',
              'front.jpeg'
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

  Future<String?> _getOrCreateTempCoverFile(String songPath, Uint8List? bytes) async {
    try {
      if (bytes == null) return null;
      final existing = _tempCoverFilePath[songPath];
      if (existing != null) {
        final f = File(existing);
        if (await f.exists()) return existing;
      }

      final tmpDir = await getTemporaryDirectory();
      final coverDir = Directory(p.join(tmpDir.path, 'audio_covers'));
      if (!await coverDir.exists()) {
        await coverDir.create(recursive: true);
      }

      final safeName = p.basename(songPath).replaceAll(RegExp(r'[^A-Za-z0-9_\-\.]'), '_');
      final filePath = p.join(coverDir.path, '${safeName}_${songPath.hashCode}.jpg');

      final file = File(filePath);
      await file.writeAsBytes(bytes, flush: true);
      _tempCoverFilePath[songPath] = filePath;
      return filePath;
    } catch (e) {
      debugPrint('Error writing temp cover file: $e');
      return null;
    }
  }

  String _displayArtist(String? artist) => TitleCleaner.artistOrUnknown(artist);

  String _albumAndYear(SongMeta? meta) {
    if (meta == null) return '';
    final album = meta.album?.trim();
    final year = meta.year;
    if ((album == null || album.isEmpty) && year == null) return '';
    if (album == null || album.isEmpty) return '${year ?? ''}'.trim();
    if (year == null) return album;
    return '$album • $year';
  }

  bool _listPathsEqual(List<String>? a, List<String> b) {
    if (a == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _playAudio(int index, {String source = 'songs'}) async {
    if (_audioFiles.isEmpty || index < 0 || index >= _audioFiles.length) return;

    RadioPlaybackContext.clear();

    final myReq = ++_playRequestSeq;
    final file = _audioFiles[index];

    unawaited(_markRecentlyPlayed(file.path));

    if (source == 'songs') {
      final paths = _audioFiles.map((f) => f.path).toList();
      final alreadyQueued = PlaylistContext.getCurrentPageId() == 'songs' &&
          _listPathsEqual(PlaylistContext.getCurrentPlaylist(), paths);
      PlaylistContext.setCurrentPlaylist(paths, pageId: 'songs');
      if (!alreadyQueued) await PlaylistService.saveQueue(paths);
    } else {
      final currentContextPlaylist = PlaylistContext.getCurrentPlaylist();
      if (currentContextPlaylist == null || !currentContextPlaylist.contains(file.path)) {
        PlaylistContext.setCurrentPlaylist([file.path], pageId: source);
        await PlaylistService.saveQueue([file.path]);
      } else {
        final pageId = PlaylistContext.getCurrentPageId() ?? source;
        PlaylistContext.currentPageIdNotifier.value = pageId;
      }
    }

    if (myReq != _playRequestSeq) return;

    _currentPlaylistSource = source;
    _currentIndex = index;
    _currentPosition = Duration.zero;
    if (mounted) {
      setState(() => _isPlaying = true);
    } else {
      _isPlaying = true;
    }

    await _startPlaybackForFile(file, myReq: myReq);
  }

  Future<void> _playAudioByPath(String path, {String source = 'songs'}) async {
    final idx = _audioIndexByPath[path] ?? _audioFiles.indexWhere((f) => f.path == path);
    if (idx != -1) return _playAudio(idx, source: source);

    RadioPlaybackContext.clear();

    final myReq = ++_playRequestSeq;
    final file = File(path);

    unawaited(_markRecentlyPlayed(path));

    final alreadyQueued = PlaylistContext.getCurrentPageId() == source &&
        _listPathsEqual(PlaylistContext.getCurrentPlaylist(), [path]);
    PlaylistContext.setCurrentPlaylist([path], pageId: source);
    if (!alreadyQueued) await PlaylistService.saveQueue([path]);

    if (myReq != _playRequestSeq) return;

    _currentPlaylistSource = source;
    _currentIndex = -1;
    _currentPosition = Duration.zero;
    if (mounted) {
      setState(() => _isPlaying = true);
    } else {
      _isPlaying = true;
    }

    await _startPlaybackForFile(file, myReq: myReq);
  }

  Future<MediaItem> _buildMediaItem(File file, SongMeta meta) async {
    final title = TitleCleaner.title(meta.title, path: file.path);
    final artistForDisplay = _displayArtist(meta.artist);
    final albumForDisplay = meta.album ?? p.basename(p.dirname(file.path));

    Uri? artUri;
    final coverBytes = meta.cover;
    if (coverBytes != null && coverBytes.isNotEmpty) {
      final tmpPath = await _getOrCreateTempCoverFile(file.path, coverBytes);
      if (tmpPath != null) artUri = Uri.file(tmpPath);
    }

    final albumWithYear = _albumAndYear(meta);

    return MediaItem(
      id: file.path,
      album: albumWithYear.isNotEmpty ? albumWithYear : albumForDisplay,
      title: title,
      artist: artistForDisplay,
      duration: meta.duration,
      artUri: artUri,
      extras: {'filePath': file.path},
    );
  }

  Future<void> _loadAndPlayFile(File file, {required int myReq}) async {
    // Single-track fallback path (shuffle/repeat-one/radio-adjacent, or a
    // queue too short to benefit from gapless) — always clears any
    // previously-attached native queue so the queue-sync listener doesn't
    // try to patch a source that's no longer attached.
    _concatQueueSource = null;
    _lastHandledNativeIndex = null;
    try {
      if (!await file.exists()) {
        throw StateError('File not found: ${file.path}');
      }
      if (myReq != _playRequestSeq) return;

      final meta = await _loadFullMetadata(file);
      if (myReq != _playRequestSeq) return;

      final mediaItem = await _buildMediaItem(file, meta);
      if (myReq != _playRequestSeq) return;

      final audioSource = AudioSource.uri(Uri.file(file.path), tag: mediaItem);

      if (myReq != _playRequestSeq) return;
      await _setSourceWithRecovery(() => _audioPlayer.setAudioSource(audioSource), myReq: myReq);
      if (myReq != _playRequestSeq) return;
      await _audioPlayer.setSpeed(_playbackSpeed);
      PlaylistContext.setCurrentPath(file.path);
      await _audioPlayer.play();
      if (myReq != _playRequestSeq) return;

      final pos = _audioPlayer.position;
      if (mounted) {
        setState(() {
          _isPlaying = true;
          _currentPosition = pos;
        });
      } else {
        _isPlaying = true;
        _currentPosition = pos;
      }

      _updateNotificationForMediaItem(mediaItem, playing: true);
    } catch (e, st) {
      if (myReq != _playRequestSeq) return;

      debugPrint('Error playing "${file.path}": $e\n$st');
      // Only blame the file when it's really gone; otherwise it was the
      // player (a stuck/failed load), which the retry couldn't recover.
      final missing = !await file.exists();
      if (mounted) {
        setState(() => _isPlaying = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(missing
              ? 'File not found: "${p.basename(file.path)}" was moved or deleted.'
              : 'Couldn\'t play "${p.basename(file.path)}". The format may be unsupported — try again or pick another song.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      } else {
        _isPlaying = false;
      }
      _updatePlaybackState(playing: false);
    }
  }

  /// Loads a source with a time limit. A load that fails or never finishes
  /// (the native player occasionally wedges, after which *every* song
  /// failed until the app was restarted) resets the player with stop() and
  /// is tried once more. A newer play request superseding this one is not
  /// an error and is rethrown untouched.
  Future<void> _setSourceWithRecovery(Future<Duration?> Function() load, {required int myReq}) async {
    const limit = Duration(seconds: 12);
    try {
      await load().timeout(limit);
      return;
    } on PlayerInterruptedException {
      rethrow;
    } catch (e) {
      if (myReq != _playRequestSeq) rethrow;
      debugPrint('Audio load failed ($e) — resetting the player and retrying once');
    }
    try {
      await _audioPlayer.stop().timeout(const Duration(seconds: 5));
    } catch (_) {}
    if (myReq != _playRequestSeq) throw PlayerInterruptedException('superseded');
    await load().timeout(limit);
  }

  /// Entry point shared by _playAudio and _playAudioByPath's foreign-path
  /// branch: decides whether the file being played can start a gapless
  /// native queue (sequential playback, a real multi-track queue, no
  /// shuffle/repeat-one) or falls back to the single-track path.
  Future<void> _startPlaybackForFile(File file, {required int myReq}) async {
    final queuePaths = PlaylistContext.getCurrentPlaylist() ?? _audioFiles.map((f) => f.path).toList();
    final idxInQueue = queuePaths.indexOf(file.path);

    if (!_shuffleEnabled && !_isRepeatOne && idxInQueue != -1 && queuePaths.length > 1) {
      await _loadAndPlayNativeQueue(queuePaths, idxInQueue, myReq: myReq);
    } else {
      await _loadAndPlayFile(file, myReq: myReq);
    }
  }

  /// Builds (or rebuilds) a ConcatenatingAudioSource for [queuePaths] and
  /// attaches it via a *singular* setAudioSource call — required so
  /// `_audioPlayer.audioSource is ConcatenatingAudioSource` stays true (the
  /// pre-existing guard in _handleTrackComplete depends on this). Light
  /// {'filePath': path} tags only, so building the queue never has to
  /// eagerly read metadata for every track — see _onNativeIndexChanged for
  /// the JIT notification refresh.
  bool _nativeQueueLoading = false;

  Future<void> _loadAndPlayNativeQueue(
    List<String> queuePaths,
    int startIndex, {
    required int myReq,
    Duration initialPosition = Duration.zero,
    bool autoplay = true,
  }) async {
    // Same queue already attached (the usual case: tapping another song in
    // the list you're playing from): jump to it instead of rebuilding and
    // re-sending the whole queue — for a large library that rebuild took
    // many seconds per tap and could leave the player stuck.
    final attached = _concatQueueSource;
    if (attached != null &&
        identical(_audioPlayer.audioSource, attached) &&
        _audioPlayer.processingState != ProcessingState.idle &&
        listEquals(_lastSyncedQueueSnapshot, queuePaths)) {
      try {
        _nativeQueueLoading = true;
        try {
          await _audioPlayer.seek(initialPosition, index: startIndex).timeout(const Duration(seconds: 8));
        } finally {
          _nativeQueueLoading = false;
        }
        if (myReq != _playRequestSeq) return;
        await _audioPlayer.setSpeed(_playbackSpeed);
        _lastHandledNativeIndex = null;
        PlaylistContext.setCurrentPath(queuePaths[startIndex]);
        if (autoplay) await _audioPlayer.play();
        if (myReq != _playRequestSeq) return;
        final pos = _audioPlayer.position;
        if (mounted) {
          setState(() {
            _isPlaying = autoplay;
            _currentPosition = pos;
          });
        } else {
          _isPlaying = autoplay;
          _currentPosition = pos;
        }
        unawaited(_onNativeIndexChanged(startIndex));
        return;
      } catch (e) {
        debugPrint('Seek within attached queue failed, rebuilding: $e');
        if (myReq != _playRequestSeq) return;
      }
    }

    try {
      final children = queuePaths
          .map((path) => AudioSource.uri(Uri.file(path), tag: <String, dynamic>{'filePath': path}))
          .toList();
      final source = ConcatenatingAudioSource(children: children);

      if (myReq != _playRequestSeq) return;
      _concatQueueSource = source;
      _lastHandledNativeIndex = null;
      _lastSyncedQueueSnapshot = List<String>.from(queuePaths);
      // While the new queue attaches, just_audio can briefly report index 0
      // before settling on startIndex; if that stale event were handled
      // after the real one, the FIRST song would stick as "current" (wrong
      // queue highlight, phantom play counts, wrong crossfade/normalization
      // target). Ignore index events until the load has settled.
      _nativeQueueLoading = true;
      try {
        await _setSourceWithRecovery(
          () => _audioPlayer.setAudioSource(source, initialIndex: startIndex, initialPosition: initialPosition),
          myReq: myReq,
        );
      } finally {
        _nativeQueueLoading = false;
      }
      if (myReq != _playRequestSeq) return;
      await _audioPlayer.setSpeed(_playbackSpeed);
      _lastHandledNativeIndex = startIndex;
      PlaylistContext.setCurrentPath(queuePaths[startIndex]);
      if (autoplay) await _audioPlayer.play();
      if (myReq != _playRequestSeq) return;

      final pos = _audioPlayer.position;
      if (mounted) {
        setState(() {
          _isPlaying = autoplay;
          _currentPosition = pos;
        });
      } else {
        _isPlaying = autoplay;
        _currentPosition = pos;
      }

      unawaited(_onNativeIndexChanged(startIndex));
    } catch (e, st) {
      if (myReq != _playRequestSeq) return;
      debugPrint('Error starting native queue playback: $e\n$st');
      _concatQueueSource = null;
      _lastSyncedQueueSnapshot = null;
      // Fall back to the reliable single-track path rather than failing
      // playback outright.
      await _loadAndPlayFile(File(queuePaths[startIndex]), myReq: myReq);
    }
  }

  /// Fires on every native-queue index change (both a real user-visible
  /// track transition and the initial entry into native mode). Mirrors what
  /// _loadAndPlayFile does directly: updates _currentIndex/PlaylistContext,
  /// marks recently-played, and refreshes the notification — none of which
  /// happen automatically since native transitions use light tags, not
  /// MediaItem tags.
  int? _lastHandledNativeIndex;

  Future<void> _onNativeIndexChanged(int index) async {
    final source = _concatQueueSource;
    if (source == null || index < 0 || index >= source.length) return;
    // Stale events: mid-load churn, or an index the player has already left.
    if (_nativeQueueLoading || _audioPlayer.currentIndex != index) return;
    // currentIndexStream can emit the same index more than once around a
    // single transition (buffering/processing-state churn) — skip repeats,
    // the metadata/notification refresh below is redundant work otherwise.
    if (_lastHandledNativeIndex == index) return;
    _lastHandledNativeIndex = index;

    final tag = source.sequence[index].tag;
    final path = (tag is Map) ? tag['filePath'] as String? : null;
    if (path == null) return;
    _currentIndex = _audioIndexByPath[path] ?? _currentIndex;
    PlaylistContext.setCurrentPath(path);
    unawaited(_markRecentlyPlayed(path));
    if (mounted) setState(() {});

    final file = File(path);
    if (!await file.exists()) return;
    final meta = await _loadFullMetadata(file);
    final mediaItem = await _buildMediaItem(file, meta);
    _lastNotifiedMediaId = null; // force refresh even if a stale id matches
    _updateNotificationForMediaItem(mediaItem, playing: _audioPlayer.playing);
  }

  /// Reacts to ANY change in PlaylistContext's queue (the single choke point
  /// every add-to-queue/delete/reorder call site across the app already
  /// feeds into) while a native queue is attached. Patches the live
  /// ConcatenatingAudioSource incrementally for the common cases (a single
  /// insert or a single removal of a track other than the one currently
  /// playing) so unrelated queue edits never interrupt playback — matching
  /// today's behavior where editing a track that isn't currently playing
  /// never touches the player at all. Anything bulkier (a reorder, or a
  /// multi-element change) falls back to a position-preserving rebuild
  /// (same track, same timestamp, brief rebuffer) rather than restarting
  /// the song.
  void _onQueueContextChanged() {
    final source = _concatQueueSource;
    final newList = PlaylistContext.currentPlaylistNotifier.value;

    if (source == null) {
      _lastSyncedQueueSnapshot = newList == null ? null : List<String>.from(newList);
      return;
    }

    final oldList = _lastSyncedQueueSnapshot;
    _lastSyncedQueueSnapshot = newList == null ? null : List<String>.from(newList);

    if (newList == null || oldList == null) return;
    if (listEquals(oldList, newList)) return;

    final currentPath = PlaylistContext.currentPathNotifier.value;
    if (currentPath == null || !oldList.contains(currentPath) || !newList.contains(currentPath)) {
      // Current track was removed/replaced, or this is a different queue
      // entirely — already handled by the existing play/delete/resume call
      // chains, which will rebuild a fresh native queue via _playAudio the
      // next time they run.
      return;
    }

    // Pure single insert?
    if (newList.length == oldList.length + 1) {
      for (var i = 0; i <= oldList.length; i++) {
        final candidate = List<String>.from(oldList)..insert(i, newList[i]);
        if (listEquals(candidate, newList)) {
          unawaited(source.insert(i, AudioSource.uri(Uri.file(newList[i]), tag: <String, dynamic>{'filePath': newList[i]})));
          _lastSyncedQueueSnapshot = List<String>.from(newList);
          return;
        }
      }
    }

    // Pure single removal (of a track other than the current one, per the
    // guard above)?
    if (newList.length == oldList.length - 1) {
      for (var i = 0; i < oldList.length; i++) {
        final candidate = List<String>.from(oldList)..removeAt(i);
        if (listEquals(candidate, newList)) {
          if (i < source.length) unawaited(source.removeAt(i));
          _lastSyncedQueueSnapshot = List<String>.from(newList);
          return;
        }
      }
    }

    // Reorder or a bulkier change — rebuild in place at the exact same
    // position rather than trying to generically diff an arbitrary
    // permutation.
    // Single move (e.g. "Play next" on a song already in the queue)? Relocate
    // it natively so playback is never interrupted and the native index stays
    // in sync with the queue (a full setAudioSource rebuild here raced with the
    // Next button and stale index events).
    if (newList.length == oldList.length) {
      var d = 0;
      while (d < oldList.length && oldList[d] == newList[d]) {
        d++;
      }
      if (d < oldList.length) {
        final candidates = <List<int>>[
          [d, newList.indexOf(oldList[d])], // old[d] moved later
          [oldList.indexOf(newList[d]), d], // new[d] moved earlier
        ];
        for (final c in candidates) {
          final from = c[0], to = c[1];
          if (from < 0 || to < 0 || from >= source.length || to >= source.length) continue;
          final cand = List<String>.from(oldList);
          cand.insert(to, cand.removeAt(from));
          if (listEquals(cand, newList)) {
            unawaited(source.move(from, to).then((_) {
              _lastHandledNativeIndex = _audioPlayer.currentIndex;
            }));
            _lastSyncedQueueSnapshot = List<String>.from(newList);
            return;
          }
        }
      }
    }

    unawaited(_rebuildNativeQueueInPlace(newList, currentPath));
  }

  Future<void> _rebuildNativeQueueInPlace(List<String> newQueue, String currentPath) async {
    final idx = newQueue.indexOf(currentPath);
    if (idx == -1) return;
    final myReq = ++_playRequestSeq;
    final position = _audioPlayer.position;
    final wasPlaying = _audioPlayer.playing;
    await _loadAndPlayNativeQueue(newQueue, idx, myReq: myReq, initialPosition: position, autoplay: wasPlaying);
  }

  void _handleTrackComplete() {
    if (RadioPlaybackContext.isActive) return;
    if (PlaylistContext.isFullScreenPlayerOpen) return;

    if (_audioPlayer.audioSource is ConcatenatingAudioSource) {
      // Mid-queue transitions never reach ProcessingState.completed — only
      // the very last item does (intermediate transitions are reported via
      // currentIndexStream/_onNativeIndexChanged instead). LoopMode.one
      // (repeat-one) already replays the current item natively — no action
      // needed. LoopMode.off does not auto-wrap the way this app's manual
      // advance logic always has, so replicate that explicitly here, unless
      // shuffle was toggled on after entering native mode, in which case
      // fall through to the normal shuffle-pick logic below instead of
      // blindly wrapping to track 0.
      if (_isRepeatOne) return;
      if (!_shuffleEnabled) {
        final wrapPlaylist = PlaylistContext.getCurrentPlaylist();
        if (wrapPlaylist != null && wrapPlaylist.isNotEmpty) {
          _playAudioByPath(wrapPlaylist.first, source: _currentPlaylistSource);
        } else {
          _playAudio(0, source: _currentPlaylistSource);
        }
        return;
      }
    }

    if (_isRepeatOne) {
      final curPath = PlaylistContext.currentPathNotifier.value ??
          (_currentIndex >= 0 && _currentIndex < _audioFiles.length ? _audioFiles[_currentIndex].path : null);
      if (curPath != null) {
        _playAudioByPath(curPath, source: _currentPlaylistSource);
      }
      return;
    }

    final playlist = PlaylistContext.getCurrentPlaylist();
    final currentPath = PlaylistContext.currentPathNotifier.value ??
        (_currentIndex >= 0 && _currentIndex < _audioFiles.length ? _audioFiles[_currentIndex].path : null);

    if (_shuffleEnabled && playlist != null && playlist.isNotEmpty) {
      final pick = PlaylistContext.pickShuffleCandidate(playlist, currentPath);
      if (pick != null) {
        _playAudioByPath(pick, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
        return;
      }
    }

    if (playlist != null && playlist.isNotEmpty && currentPath != null) {
      final idx = playlist.indexOf(currentPath);
      if (idx != -1) {
        final nextIdx = (idx + 1) % playlist.length;
        final nextPath = playlist[nextIdx];
        _playAudioByPath(nextPath, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
        return;
      }
    }

    if (_audioFiles.isEmpty) {
      _stopAudio();
    } else if (_currentIndex < _audioFiles.length - 1) {
      _playAudio(_currentIndex + 1, source: _currentPlaylistSource);
    } else {
      _playAudio(0, source: _currentPlaylistSource);
    }
  }

  /// Native index of the queue neighbour (+1 / -1) of the playing track,
  /// resolved by PATH from PlaylistContext (the source of truth for queue
  /// order, including "Play next" edits) against the native sequence tags,
  /// so a stale or shifted native index can never pick the wrong song.
  /// Null at the queue boundary or when the two disagree (callers then use
  /// the plain native/wrap behaviour).
  int? _nativeNeighborIndex(ConcatenatingAudioSource source, int delta) {
    final playlist = PlaylistContext.getCurrentPlaylist();
    final cur = PlaylistContext.currentPathNotifier.value;
    if (playlist == null || cur == null) return null;
    final i = playlist.indexOf(cur);
    final j = i + delta;
    if (i == -1 || j < 0 || j >= playlist.length) return null;
    final want = playlist[j];
    for (var n = 0; n < source.sequence.length; n++) {
      final tag = source.sequence[n].tag;
      if (tag is Map && tag['filePath'] == want) return n;
    }
    return null;
  }

  Future<void> _seekNativeIndex(int index) async {
    _lastHandledNativeIndex = null;
    await _audioPlayer.seek(Duration.zero, index: index);
    if (!_audioPlayer.playing) unawaited(_audioPlayer.play());
  }

  Future<void> _playNext() async {
    if (RadioPlaybackContext.isActive) return;

    final concatSource = _concatQueueSource;
    if (concatSource != null &&
        !_shuffleEnabled &&
        !_isRepeatOne &&
        PlaylistContext.currentPathNotifier.value != null) {
      final curIdx = _audioPlayer.currentIndex ?? 0;
      final navTarget = _nativeNeighborIndex(concatSource, 1);
      if (navTarget != null) {
        await _seekNativeIndex(navTarget);
      } else if (curIdx < concatSource.length - 1) {
        await _audioPlayer.seekToNext();
      } else {
        final wrapPlaylist = PlaylistContext.getCurrentPlaylist();
        if (wrapPlaylist != null && wrapPlaylist.isNotEmpty) {
          await _playAudioByPath(wrapPlaylist.first, source: _currentPlaylistSource);
        } else {
          await _playAudio(0, source: _currentPlaylistSource);
        }
      }
      return;
    }

    final playlist = PlaylistContext.getCurrentPlaylist();
    final currentPath = PlaylistContext.currentPathNotifier.value ??
        (_currentIndex >= 0 && _currentIndex < _audioFiles.length ? _audioFiles[_currentIndex].path : null);

    if (_shuffleEnabled && playlist != null && playlist.isNotEmpty) {
      final pick = PlaylistContext.pickShuffleCandidate(playlist, currentPath);
      if (pick != null) {
        await _playAudioByPath(pick, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
        return;
      }
    }

    if (playlist != null && playlist.isNotEmpty && currentPath != null) {
      final idx = playlist.indexOf(currentPath);
      if (idx != -1) {
        final nextIdx = (idx + 1) % playlist.length;
        final nextPath = playlist[nextIdx];
        await _playAudioByPath(nextPath, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
        return;
      }
    }

    if (_isRepeatOne) {
      if (_currentIndex != -1) {
        await _playAudio(_currentIndex, source: _currentPlaylistSource);
      }
      return;
    }

    if (_audioFiles.isEmpty) return;
    if (_currentIndex < _audioFiles.length - 1) {
      await _playAudio(_currentIndex + 1, source: _currentPlaylistSource);
    } else {
      await _playAudio(0, source: _currentPlaylistSource);
    }
  }

  Future<void> _playPrevious() async {
    if (RadioPlaybackContext.isActive) return;

    final concatSource = _concatQueueSource;
    if (concatSource != null &&
        !_shuffleEnabled &&
        !_isRepeatOne &&
        PlaylistContext.currentPathNotifier.value != null) {
      final curIdx = _audioPlayer.currentIndex ?? 0;
      final navTarget = _nativeNeighborIndex(concatSource, -1);
      if (navTarget != null) {
        await _seekNativeIndex(navTarget);
      } else if (curIdx > 0) {
        await _audioPlayer.seekToPrevious();
      } else {
        final wrapPlaylist = PlaylistContext.getCurrentPlaylist();
        if (wrapPlaylist != null && wrapPlaylist.isNotEmpty) {
          await _playAudioByPath(wrapPlaylist.last, source: _currentPlaylistSource);
        } else {
          await _playAudio(_audioFiles.length - 1, source: _currentPlaylistSource);
        }
      }
      return;
    }

    final playlist = PlaylistContext.getCurrentPlaylist();
    final currentPath = PlaylistContext.currentPathNotifier.value ??
        (_currentIndex >= 0 && _currentIndex < _audioFiles.length ? _audioFiles[_currentIndex].path : null);

    if (playlist != null && playlist.isNotEmpty && currentPath != null) {
      final idx = playlist.indexOf(currentPath);
      if (idx != -1) {
        final prevIdx = (idx - 1 + playlist.length) % playlist.length;
        final prevPath = playlist[prevIdx];
        await _playAudioByPath(prevPath, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
        return;
      }
    }

    if (_audioFiles.isEmpty) return;
    if (_currentIndex > 0) {
      await _playAudio(_currentIndex - 1, source: _currentPlaylistSource);
    } else {
      await _playAudio(_audioFiles.length - 1, source: _currentPlaylistSource);
    }
  }

  Future<void> _pauseAudio() async {
    try {
      await _audioPlayer.pause();
      final pos = _audioPlayer.position;
      setState(() {
        _isPlaying = false;
        _currentPosition = pos;
      });
      _updatePlaybackState(playing: false);
    } catch (e) {
      debugPrint('Pause failed: $e');
    }
  }

  Future<void> _resumeAudio() async {
    try {
      await _audioPlayer.play();
      final pos = _audioPlayer.position;
      setState(() {
        _isPlaying = true;
        _currentPosition = pos;
      });
      _updatePlaybackState(playing: true);
    } catch (e) {
      debugPrint('Resume failed: $e');
    }
  }

  Future<void> _stopAudio() async {
    await _audioPlayer.stop();
    setState(() {
      _currentIndex = -1;
      _currentPosition = Duration.zero;
      _totalDuration = Duration.zero;
      _currentPlaylistSource = 'songs';
      _isPlaying = false;
    });
    PlaylistContext.setCurrentPath(null);
    _updatePlaybackState(playing: false);
  }

  Future<void> _seekAudio(Duration position) async => await _audioPlayer.seek(position);

  Future<bool> _playRadioStation(RadioStation station) async {
    if (station.streamUrl.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"${station.name}" has no playable stream.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
      return false;
    }

    // Offline: say so plainly instead of blaming the station.
    if (!await _hasInternet(Uri.tryParse(station.streamUrl)?.host)) {
      _showNoInternetSnack();
      return false;
    }

    final myReq = ++_playRequestSeq;
    unawaited(RadioBrowserService.instance.registerClick(station.stationUuid));

    final mediaItem = MediaItem(
      id: 'radio:${station.stationUuid}',
      title: station.name,
      artist: station.subtitle.isNotEmpty ? station.subtitle : 'Internet Radio',
      album: 'Internet Radio',
      artUri: station.favicon.trim().isNotEmpty ? Uri.tryParse(station.favicon.trim()) : null,
      extras: {'isRadio': true, 'stationUuid': station.stationUuid},
    );

    _currentPosition = Duration.zero;
    RadioPlaybackContext.setCurrentStation(station);
    _updateNotificationForMediaItem(mediaItem, playing: false);

    try {
      await _audioPlayer.stop();
      if (myReq != _playRequestSeq) return false;
      await _audioPlayer.setAudioSource(AudioSource.uri(Uri.parse(station.streamUrl), tag: mediaItem));
      if (myReq != _playRequestSeq) return false;
      await _audioPlayer.play();
      if (myReq != _playRequestSeq) return false;
      if (mounted) setState(() => _isPlaying = true);
      _updateNotificationForMediaItem(mediaItem, playing: true);
      return true;
    } catch (e) {
      if (myReq != _playRequestSeq) return false;

      debugPrint('Radio playback error for "${station.name}": $e');
      RadioPlaybackContext.clear();
      // The connection may have dropped while the stream was opening.
      final online = await _hasInternet(Uri.tryParse(station.streamUrl)?.host);
      if (myReq != _playRequestSeq) return false;
      if (!online) {
        if (mounted) setState(() => _isPlaying = false);
        _showNoInternetSnack();
        await _updatePlaybackState(playing: false);
        return false;
      }
      if (mounted) {
        setState(() => _isPlaying = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Couldn\'t play "${station.name}". The station may be offline right now — try another one.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
      await _updatePlaybackState(playing: false);
      return false;
    }
  }

  /// True when a DNS lookup succeeds (the stream's own host first, then a
  /// well-known one). A failed lookup within a few seconds means there's
  /// no usable internet connection.
  Future<bool> _hasInternet([String? host]) async {
    for (final h in [if (host != null && host.isNotEmpty) host, 'one.one.one.one', 'google.com']) {
      try {
        final r = await InternetAddress.lookup(h).timeout(const Duration(seconds: 3));
        if (r.isNotEmpty && r.first.rawAddress.isNotEmpty) return true;
      } catch (_) {}
    }
    return false;
  }

  void _showNoInternetSnack() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('No internet connection. Connect to Wi-Fi or mobile data to play radio.'),
      backgroundColor: Colors.orange,
      behavior: SnackBarBehavior.floating,
      duration: Duration(seconds: 3),
    ));
  }

  Future<void> _stopRadio() async {
    try {
      await _audioPlayer.stop();
    } catch (e) {
      debugPrint('Error stopping radio: $e');
    }
    RadioPlaybackContext.clear();
    if (mounted) setState(() => _isPlaying = false);
    await _updatePlaybackState(playing: false);
  }

  Future<void> _openAudioConversionSheet(File file) async {
    final meta = _metaCache[file.path];
    final title = TitleCleaner.title(meta?.title, path: file.path);
    await showAudioConversionSheet(
      context: context,
      song: file,
      title: title,
      isDark: _effectiveIsDark,
      onConverted: _handleConvertedSong,
    );
  }

  Future<void> _handleConvertedSong(ConversionRecord record) async {
    final convertedFile = File(record.convertedPath);
    if (!await convertedFile.exists()) return;

    if (!_audioIndexByPath.containsKey(record.convertedPath)) {
      setState(() {
        _audioFiles.add(convertedFile);
      });
      _rebuildAudioIndexMap();
      unawaited(_saveCachedAudioList());
    }
    _rebuildSongDisplayList();

    final idx = _audioIndexByPath[record.convertedPath];
    if (idx != null) {
      await _playAudio(idx, source: 'songs');
    }
  }

  Future<void> _openAudioCutterPage(File file) async {
    final meta = _metaCache[file.path];
    final title = TitleCleaner.title(meta?.title, path: file.path);
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AudioCutterPage(
        song: file,
        title: title,
        isDark: _effectiveIsDark,
        knownDuration: meta?.duration,
        mainPlayerToPause: _audioPlayer,
        onCutSaved: _handleCutSong,
      ),
      fullscreenDialog: true,
    ));
  }

  Future<void> _handleCutSong(CutRecord record) async {
    final cutFile = File(record.cutPath);
    if (!await cutFile.exists()) return;

    if (!_audioIndexByPath.containsKey(record.cutPath)) {
      setState(() {
        _audioFiles.add(cutFile);
      });
      _rebuildAudioIndexMap();
      unawaited(_saveCachedAudioList());
    }
    _rebuildSongDisplayList();

    final idx = _audioIndexByPath[record.cutPath];
    if (idx != null) {
      await _playAudio(idx, source: 'songs');
    }
  }

  Future<void> _toggleFavoriteFor(String path) async {
    try {
      if (!FavoritesNotifier.instance.initialized) {
        await FavoritesNotifier.instance.init();
      }
      await FavoritesNotifier.instance.toggle(path);
      setState(() {
        _favorites = Set<String>.from(FavoritesNotifier.instance.favoritesSet);
      });

      final currentlyAdded = FavoritesNotifier.instance.contains(path);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(currentlyAdded ? 'Added to favorites' : 'Removed from favorites'),
        backgroundColor: _primaryColor,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      debugPrint('Toggle favorite failed: $e');
    }
  }

  Future<void> _deleteFile(String path) async {
    final File f = File(path);
    final fileName = p.basename(path);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file'),
        content: Text('Are you sure you want to delete "$fileName" from device?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final isCurrentFile = PlaylistContext.currentPathNotifier.value == path ||
          (_currentIndex >= 0 && _currentIndex < _audioFiles.length && _audioFiles[_currentIndex].path == path);

      if (isCurrentFile) {
        try {
          await _audioPlayer.stop();
        } catch (e) {
          debugPrint('Error stopping player before delete: $e');
        }

        PlaylistContext.setCurrentPath(null);
        setState(() {
          _currentIndex = -1;
          _currentPosition = Duration.zero;
          _totalDuration = Duration.zero;
          _currentPlaylistSource = 'songs';
        });

        await _updatePlaybackState(playing: false);
      }

      if (await f.exists()) {
        await f.delete();
      }

      _metaCache.remove(path);
      _coverCache.remove(path);
      final tempCover = _tempCoverFilePath.remove(path);
      if (tempCover != null) {
        try {
          final coverFile = File(tempCover);
          if (await coverFile.exists()) await coverFile.delete();
        } catch (e) {
          debugPrint('Failed to delete temp cover file: $e');
        }
      }

      try {
        final current = PlaylistContext.getCurrentPlaylist() ?? _audioFiles.map((f) => f.path).toList();
        final beforeLen = current.length;
        current.removeWhere((p) => p == path);
        if (beforeLen != current.length) {
          PlaylistContext.setCurrentPlaylist(current, pageId: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource);
          await PlaylistService.saveQueue(current);
          final currentPath = PlaylistContext.currentPathNotifier.value;
          if (currentPath != null) {
            final newIndex = current.indexOf(currentPath);
            setState(() => _currentIndex = newIndex);
          }
        }
      } catch (_) {}

      setState(() {
        _audioFiles.removeWhere((file) => file.path == path);
        _favorites.remove(path);
        _filteredSongs = List<File>.from(_audioFiles);

        if (_currentIndex >= _audioFiles.length) {
          _currentIndex = _audioFiles.isEmpty ? -1 : _audioFiles.length - 1;
        }
      });

      _rebuildAudioIndexMap();
      await _saveCachedAudioList();
      _rebuildSongDisplayList();

      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Song deleted successfully'),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ));
    } on FileSystemException catch (e) {
      debugPrint('FileSystemException on delete: $e');
      String msg = 'Delete failed: you may not have permission to delete this file.';
      if (Platform.isAndroid) {
        msg = 'Delete failed: On newer Android versions some folders are protected. Try moving the file to Music/ or Downloads and then delete again.';
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)));
    } catch (e) {
      debugPrint('Delete failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: ${e.toString()}'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _shareFile(String path, BuildContext context) async {
    try {
      final file = XFile(path);
      await Share.shareXFiles([file], text: p.basename(path));
    } catch (e) {
      debugPrint('Share failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: ${e.toString()}'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
    }
  }

  Future<void> _addFileToQueue(String path) async {
    QueueActions.addToQueueWithFeedback(context, [path]);
  }

  void _toggleRepeatMode() {
    setState(() {
      _audioPlayer.setLoopMode(_isRepeatOne ? LoopMode.off : LoopMode.one);
    });

    final label = _isRepeatOne ? 'Repeat: One' : 'Repeat: Off';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label), backgroundColor: _primaryColor, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
  }

  Future<void> _changePlaybackSpeed(double speed) async {
    try {
      await _audioPlayer.setSpeed(speed);
      setState(() => _playbackSpeed = speed);
      _updatePlaybackState(playing: _isPlaying);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playback speed: ${speed}x'), backgroundColor: _primaryColor, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
    } catch (e) {
      debugPrint('Error changing playback speed: $e');
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission Required'),
        content: const Text('Storage/media permission is required to access your music files.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          TextButton(onPressed: () { Navigator.of(context).pop(); openAppSettings(); }, child: const Text('Open Settings')),
        ],
      ),
    );
  }

  String _formatDurationShort(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    if (duration.inHours > 0) {
      return '${twoDigits(duration.inHours)}:${twoDigits(duration.inMinutes.remainder(60))}:${twoDigits(duration.inSeconds.remainder(60))}';
    } else {
      return '${twoDigits(duration.inMinutes.remainder(60))}:${twoDigits(duration.inSeconds.remainder(60))}';
    }
  }

  void _openSortSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 4),
              child: Row(children: [
                Text('Sort songs by', style: TextStyle(color: _textColor, fontSize: 17, fontWeight: FontWeight.bold)),
                const Spacer(),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, icon: Icon(Icons.arrow_upward_rounded, size: 18)),
                    ButtonSegment(value: false, icon: Icon(Icons.arrow_downward_rounded, size: 18)),
                  ],
                  selected: {SongSort.ascending},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) async {
                    await SongSort.set(SongSort.field, v.first);
                    setSheet(() {});
                  },
                ),
              ]),
            ),
            for (final f in SongSortField.values)
              ListTile(
                leading: Icon(
                  switch (f) {
                    SongSortField.title => Icons.title_rounded,
                    SongSortField.artist => Icons.person_rounded,
                    SongSortField.album => Icons.album_rounded,
                    SongSortField.dateAdded => Icons.schedule_rounded,
                    SongSortField.duration => Icons.timelapse_rounded,
                    SongSortField.fileName => Icons.insert_drive_file_outlined,
                  },
                  color: SongSort.field == f ? _primaryColor : _subtitleColor,
                ),
                title: Text(SongSort.label(f),
                    style: TextStyle(color: SongSort.field == f ? _primaryColor : _textColor, fontWeight: SongSort.field == f ? FontWeight.w600 : FontWeight.normal)),
                trailing: SongSort.field == f ? Icon(Icons.check_rounded, color: _primaryColor) : null,
                onTap: () async {
                  // Newest-first / longest-first is the natural default for
                  // date and duration; A–Z for the text sorts.
                  final defaultAsc = !(f == SongSortField.dateAdded || f == SongSortField.duration);
                  await SongSort.set(f, SongSort.field == f ? SongSort.ascending : defaultAsc);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ]),
        ),
      ),
    );
  }

  void _onNavTap(int index) {
    setState(() => _selectedTabIndex = index);
  }

  void _refreshSongs() {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Refreshing songs...'), backgroundColor: _primaryColor, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
    _requestPermissionAndLoadSongs(forceRescan: true);
  }

  void _filterSongsInSongsPage(String query) {
    _searchDebounce?.cancel();
    if (query.isEmpty) {
      _applySongsFilter(query);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _applySongsFilter(query);
    });
  }

  void _applySongsFilter(String query) {
    if (query.isEmpty) {
      setState(() => _filteredSongs = _audioFiles);
      _rebuildSongDisplayList();
      return;
    }
    final q = query.toLowerCase();
    setState(() {
      _filteredSongs = _audioFiles.where((file) {
        final fileName = p.basename(file.path).toLowerCase();
        final meta = _metaCache[file.path];
        final t = (meta?.title ?? '').toLowerCase();
        final a = (meta?.artist ?? '').toLowerCase();
        final al = (meta?.album ?? '').toLowerCase();
        return fileName.contains(q) || t.contains(q) || a.contains(q) || al.contains(q);
      }).toList();
    });
    _rebuildSongDisplayList();
  }

  void _toggleSearchInSongsPage() {
    setState(() {
      _isSearchingInSongs = !_isSearchingInSongs;
      if (!_isSearchingInSongs) {
        _songsSearchController.clear();
        _filteredSongs = _audioFiles;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) => _songsSearchFocusNode.requestFocus());
      }
    });
    _rebuildSongDisplayList();
  }

  @override
  void dispose() {
    LibraryFilter.changes.removeListener(_onLibraryFilterChanged);
    TagEditorService.edited.removeListener(_onTagsEdited);
    SongSort.changes.removeListener(_rebuildSongDisplayList);
    AppPalette.changes.removeListener(_onPaletteChanged);
    if (_current == this) _current = null;
    ShortcutActions.instance.detach();
    WidgetsBinding.instance.removeObserver(this);
    _libraryTabController.dispose();
    FavoritesNotifier.instance.removeListener(_onFavoritesChanged);
    PlaylistContext.shuffleEnabledNotifier.removeListener(_scheduleNotificationRefresh);
    _notifRefreshTimer?.cancel();
    _sleepSub?.cancel();
    _searchDebounce?.cancel();
    _songsSearchController.dispose();
    _songsSearchFocusNode.dispose();
    _audioPlayer.dispose();
    _scanProgressTimer?.cancel();
    try {
      _audioHandler?.stop();
    } catch (_) {}
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _processingStateSub?.cancel();
    _sequenceStateSub?.cancel();
    _currentIndexSub?.cancel();
    PlaylistContext.currentPlaylistNotifier.removeListener(_onQueueContextChanged);
    PlaylistContext.currentPathNotifier.removeListener(_onCurrentPathForEffects);
    PositionMemoryService.instance.resumed.removeListener(_onPositionResumed);
    super.dispose();
  }

  Future<void> _openEqualizer() async {
    try {
      final sessionId = await _audioPlayer.androidAudioSessionId;

      if (sessionId == null || sessionId == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Play a song first'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final bool isDark = _effectiveIsDark;

      Navigator.of(context).push(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => EqualizerScreen(
            audioSessionId: sessionId,
            isDark: isDark,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Open equalizer failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open equalizer.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _openSettingsPage({bool openSleepTimer = true}) {
    try {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => SleepTimerPage(audioPlayer: _audioPlayer, onThemeChange: (isDark) async { await _onExternalThemeChange(); _applySystemUiOverlay(); }, isDark: _effectiveIsDark,), fullscreenDialog: true));
    } catch (e) {
      debugPrint('Open settings failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open settings.'), behavior: SnackBarBehavior.floating));
    }
  }

  void _openSleepTimer() {
    try {
      Navigator.of(context).push(MaterialPageRoute(fullscreenDialog: true, builder: (_) => SleepTimerPage(audioPlayer: _audioPlayer, isDark: _effectiveIsDark, onThemeChange: (isDark) async { await _onExternalThemeChange(); _applySystemUiOverlay(); })));
    } catch (e) {
      debugPrint('Open sleep timer failed: $e');
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open sleep timer.'), behavior: SnackBarBehavior.floating));
    }
  }

  bool _isOpeningFullScreenPlayer = false;

  void _openFullScreenPlayer() {
    if (_currentIndex == -1 && PlaylistContext.currentPathNotifier.value == null) return;
    if (_isOpeningFullScreenPlayer) return;
    _isOpeningFullScreenPlayer = true;
    Navigator.of(context).push(nowPlayingRoute((_) => FullScreenPlayer(
      audioPlayer: _audioPlayer,
      audioFiles: _audioFiles,
      initialIndex: _currentIndex,
      favorites: _favorites,
      repeatMode: _audioPlayer.loopMode,
      playbackSpeed: _playbackSpeed,
      equalizerActive: false,
      metaCache: _metaCache.map((k, v) => MapEntry(k, <String,dynamic>{ 'title': v.title, 'artist': v.artist, 'album': v.album, 'year': v.year, 'duration': v.duration, 'cover': v.cover })),
      loadFullMetadata: (file) async {
        final meta = await _loadFullMetadata(file);
        return { 'title': meta.title, 'artist': meta.artist, 'album': meta.album, 'year': meta.year, 'duration': meta.duration, 'cover': meta.cover };
      },
      onPlayAtIndex: (i) => _playAudio(i, source: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource),
      onSkipNext: () => _playNextAndNotify(),
      onSkipPrevious: () => _playPreviousAndNotify(),
      onToggleFavorite: (path) => _toggleFavoriteFor(path),
      onDelete: (path) => _deleteFile(path),
      onShare: (path) => _shareFile(path, context),
      onToggleRepeat: _toggleRepeatMode,
      onChangePlaybackSpeed: _changePlaybackSpeed,
      onOpenEqualizer: _openEqualizer,
      onClose: (index) {
        if (index != null && index >= 0 && index < _audioFiles.length) {
          setState(() => _currentIndex = index);
        }
      },
      isDarkMode: _effectiveIsDark,
      pageId: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource,
      onOpenSleepTimer: () { _openSettingsPage(openSleepTimer: true); },
      onEqualizerChange: (bool enabled, Map<int, double> gains) { },
      onAudioConversionDone: (record) => _handleConvertedSong(record),
    ))).then((_) => _isOpeningFullScreenPlayer = false);
  }

  /// Merged "Library" AppBar — hosts the Overview/Songs internal TabBar.
  /// The shuffle/search/refresh controls only make sense for the flat song
  /// list, so they're shown only while the Songs sub-tab is active; the
  /// Overview sub-tab gets the same plain title ListPage's own AppBar used
  /// to show standalone.
  PreferredSizeWidget _buildLibraryAppBar() {
    final showSongsActions = _libraryTabController.index == 1;
    return AppPageBar(
      title: context.l10n.navLibrary,
      backgroundColor: _effectiveIsDark ? AppPalette.darkBackground : Colors.white,
      foregroundColor: _textColor,
      leading: showSongsActions
          ? ValueListenableBuilder<bool>(
              valueListenable: PlaylistContext.shuffleEnabledNotifier,
              builder: (context, shuffleOn, _) => IconButton(
                icon: Icon(Icons.shuffle, color: shuffleOn ? _primaryColor : _textColor),
                onPressed: () async {
                  final newVal = !shuffleOn;
                  PlaylistContext.setShuffleEnabled(newVal);
                  try {
                    await _audioPlayer.setShuffleModeEnabled(newVal);
                  } catch (e) {
                    debugPrint('setShuffleModeEnabled error: $e');
                  }
                  final label = newVal ? context.l10n.tipShuffleOn : context.l10n.tipShuffleOff;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(label), backgroundColor: _primaryColor, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 2)));
                },
                tooltip: shuffleOn ? context.l10n.tipShuffleOn : context.l10n.tipShuffleOff,
              ),
            )
          : null,
      titleWidget: (showSongsActions && _isSearchingInSongs)
          ? TextField(
              controller: _songsSearchController,
              focusNode: _songsSearchFocusNode,
              style: TextStyle(color: _textColor, fontSize: 16),
              decoration: InputDecoration(hintText: context.l10n.searchSongsHint, hintStyle: TextStyle(color: _subtitleColor), border: InputBorder.none, contentPadding: EdgeInsets.zero),
            )
          : null,
      actions: showSongsActions
          ? [
              IconButton(icon: Icon(Icons.sort_rounded, color: _textColor), onPressed: _openSortSheet, tooltip: context.l10n.tipSortSongs),
              IconButton(icon: Icon(Icons.refresh, color: _textColor), onPressed: _refreshSongs, tooltip: context.l10n.tipRefreshSongs),
              IconButton(icon: Icon(Icons.manage_search_rounded, color: _textColor), onPressed: _openGlobalSearch, tooltip: context.l10n.tipSearchEverywhere),
              if (!_isSearchingInSongs)
                IconButton(icon: Icon(Icons.search, color: _textColor), onPressed: _toggleSearchInSongsPage, tooltip: context.l10n.tipSearch)
              else
                IconButton(icon: Icon(Icons.close, color: _textColor), onPressed: _toggleSearchInSongsPage, tooltip: context.l10n.tipCloseSearch),
            ]
          : const [],
      bottom: TabBar(
        controller: _libraryTabController,
        labelColor: _primaryColor,
        unselectedLabelColor: _subtitleColor,
        indicatorColor: _primaryColor,
        tabs: [Tab(text: context.l10n.tabOverview), Tab(text: context.l10n.tabSongs)],
      ),
    );
  }

  Widget _buildLibraryBody() {
    return TabBarView(
      controller: _libraryTabController,
      children: [
        ListPage(
          embedded: true,
          audioFiles: _audioFiles,
          onPlay: (file) {
            final idx = _audioFiles.indexWhere((f) => f.path == file.path);
            if (idx != -1) {
              _playAudio(idx, source: 'list');
            } else {
              _requestPermissionAndLoadSongs(forceRescan: true);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Song not available yet — refreshing list'), backgroundColor: AppPalette.accent, behavior: SnackBarBehavior.floating, duration: Duration(seconds: 2)));
            }
          },
          onToggleFavorite: (file) {
            _toggleFavoriteFor(file.path);
          },
          onOpenAlbums: _openAlbumsPage,
          onOpenGenres: _openGenresPage,
          onOpenSmartMix: _openSmartMixPage,
          loading: _isLoading,
          nowPlayingPath: (_currentIndex >= 0 && _currentIndex < _audioFiles.length) ? _audioFiles[_currentIndex].path : null,
          nowPlaying: _isPlaying,
          progress: _totalDuration.inMilliseconds > 0
              ? (_currentPosition.inMilliseconds / _totalDuration.inMilliseconds).clamp(0.0, 1.0).toDouble()
              : 0.0,
          onTogglePlay: () => _isPlaying ? _pauseAudio() : _resumeAudio(),
          onShuffleAll: _shuffleAll,
          resolveArtist: (path) => TitleCleaner.artist(_metaCache[path]?.artist),
          resolveAlbum: (path) {
            final a = _metaCache[path]?.album?.trim();
            return (a == null || a.isEmpty) ? null : a;
          },
        ),
        _buildSongsBody(),
      ],
    );
  }

  /// Turns shuffle on and starts a random song (Overview chip + launcher shortcut).
  Future<void> _shuffleAll() async {
    if (_audioFiles.isEmpty) return;
    PlaylistContext.setShuffleEnabled(true);
    try { await _audioPlayer.setShuffleModeEnabled(true); } catch (_) {}
    _playAudio(math.Random().nextInt(_audioFiles.length), source: 'list');
  }

  /// Launcher shortcut routed from Kotlin (see lib/shortcuts/shortcut_actions.dart).
  Future<void> _onShortcutAction(String action) async {
    if (!mounted) return;
    if (action == 'search') {
      _openGlobalSearch();
    } else if (action == 'shuffle_all') {
      // A cold start may reach here before the first scan finished: give it
      // one short grace period instead of silently doing nothing.
      if (_audioFiles.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
      }
      await _shuffleAll();
    }
  }

  Widget _buildSectionHeader(String letter) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8, top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _effectiveIsDark ? AppPalette.darkCard.withValues(alpha: 0.55) : const Color(0xFFF0F4FA),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: _primaryColor,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildSongsSkeletonList() {
    final baseColor = _effectiveIsDark ? const Color(0xFF2A2A2A) : Colors.grey.shade300;
    final highlightColor = _effectiveIsDark ? const Color(0xFF3A3A3A) : Colors.grey.shade100;
    return Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: 10,
        itemBuilder: (context, index) => Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: baseColor, borderRadius: BorderRadius.circular(16)),
          child: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(width: 44, height: 44, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(width: double.infinity, height: 14, color: Colors.white),
                const SizedBox(height: 8),
                Container(width: 120, height: 11, color: Colors.white),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildSongsBody() {
    if (_audioFiles.isEmpty) {
      if (!_loadedCacheOnStartup) {
        return _buildSongsSkeletonList();
      }
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.music_off, size: 72, color: _subtitleColor),
          const SizedBox(height: 16),
          Text('No audio files found', style: TextStyle(color: _textColor, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(_isLoading ? 'Scanning your device — found ${_lastScannedCount} so far...' : 'Make sure you have granted storage permissions', style: TextStyle(color: _subtitleColor, fontSize: 14), textAlign: TextAlign.center),
          const SizedBox(height: 12),
          if (_isLoading)
            Row(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(width: 4),
              const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text('Scanning...', style: TextStyle(color: _subtitleColor)),
            ]),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: () => _requestPermissionAndLoadSongs(forceRescan: true), style: ElevatedButton.styleFrom(backgroundColor: _primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Scan Again')),
        ]),
      );
    }

    final displayFiles = _isSearchingInSongs ? _filteredSongs : _audioFiles;
    final totalSongs = _audioFiles.length;

    return Column(children: [
      if (_isLoading)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
          color: _cardColor,
          child: Row(children: [
            const SizedBox(width: 4),
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 12),
            Expanded(child: Text('Scanning music library...', style: TextStyle(color: _subtitleColor))),
            Text('${_lastScannedCount} found', style: TextStyle(color: _subtitleColor))
          ]),
        )
      else
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: _cardColor,
          child: Row(
            children: [
              Text(
                _isSearchingInSongs
                    ? 'Showing ${displayFiles.length} of $totalSongs songs'
                    : 'Total songs: $totalSongs',
                style: TextStyle(color: _subtitleColor, fontSize: 14, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: _openSortSheet,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(SongSort.ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 16, color: _primaryColor),
                    const SizedBox(width: 4),
                    Text(SongSort.label(SongSort.field), style: TextStyle(color: _primaryColor, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              if (_isSearchingInSongs && _songsSearchController.text.isNotEmpty)
                TextButton(
                  onPressed: () {
                    _songsSearchController.clear();
                    _filterSongsInSongsPage('');
                  },
                  child: Text('Clear', style: TextStyle(color: _primaryColor, fontSize: 14)),
                ),
            ],
          ),
        ),
      Expanded(
        child: _songDisplayItems.isEmpty
            ? const SizedBox.shrink()
            : ListView.builder(
          key: const PageStorageKey<String>('songs_list_view'),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          itemCount: _songDisplayItems.length,
          itemBuilder: (context, index) {
            final item = _songDisplayItems[index];

            if (item.isHeader) {
              return _buildSectionHeader(item.letter ?? '#');
            }

            final file = item.file!;
            final originalIndex = item.originalIndex ?? _audioIndexByPath[file.path] ?? -1;
            final selected = (_currentPlaylistSource == 'songs') && (originalIndex == _currentIndex);

            return StaggerIn(
              playKey: 'songs:${file.path}',
              index: index,
              child: _SongRow(
              key: ValueKey<String>(file.path),
              file: file,
              selected: selected,
              isFav: _favorites.contains(file.path),
              isPlaying: _isPlaying,
              primaryColor: _primaryColor,
              cardColor: _cardColor,
              textColor: _textColor,
              subtitleColor: _subtitleColor,
              backgroundColor: _backgroundColor,
              isDark: _effectiveIsDark,
              metaCache: _metaCache,
              loadingMetadataPaths: _loadingMetadataPaths,
              loadFullMetadata: _loadFullMetadata,
              displayArtist: _displayArtist,
              albumAndYear: _albumAndYear,
              truncate: _truncate,
              onTap: () {
                if (originalIndex != -1) {
                  _playAudio(originalIndex, source: 'songs');
                }
              },
              onToggleFavorite: () => _toggleFavoriteFor(file.path),
              onOpenEqualizer: _openEqualizer,
              onOpenSleepTimer: _openSleepTimer,
              onShare: () => _shareFile(file.path, context),
              onDelete: () => _deleteFile(file.path),
              onAddToQueue: () => _addFileToQueue(file.path),
              onAudioConversion: () => _openAudioConversionSheet(file),
              onAudioCutter: () => _openAudioCutterPage(file),
              onEditTags: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TagEditorPage(path: file.path, isDark: _effectiveIsDark),
              )),
            ),
            );
          },
        ),
      ),
    ]);
  }

  Widget _buildPageFor(int tabIndex) {
    switch (tabIndex) {
      case 0:
        return _buildLibraryBody();
      case 1:
        return InternetRadioPage(
          audioPlayer: _audioPlayer,
          isDark: _effectiveIsDark,
          onPlayStation: _playRadioStation,
          // This tab screen's own bottomNavigationBar already shows the
          // mini player and a banner ad regardless of the selected tab.
          showMiniPlayer: false,
        );
      case 2:
        return DuoPage(
          audioFiles: _audioFiles,
          isDark: _effectiveIsDark,
          resolveTitle: (file) {
            final meta = _metaCache[file.path];
            return TitleCleaner.title(meta?.title, path: file.path);
          },
          resolveArtist: (file) {
            return TitleCleaner.artist(_metaCache[file.path]?.artist);
          },
          resolveCover: (path) => _metaCache[path]?.cover,
        );
      case 3:
        return AudioConverterPage(audioFiles: _audioFiles);
      case 4:
        return SettingsPage(
          audioPlayer: _audioPlayer,
          onThemeChange: (isDark) async {
            await _onExternalThemeChange();
            _applySystemUiOverlay();
          },
          onPlayRadioStation: _playRadioStation,
          audioFiles: _audioFiles,
          resolveSongTitle: (file) {
            final meta = _metaCache[file.path];
            return TitleCleaner.title(meta?.title, path: file.path);
          },
          resolveSongDuration: (file) => _metaCache[file.path]?.duration,
          onCutSaved: (record) => _handleCutSong(record),
        );
      default:
        return _buildLibraryBody();
    }
  }

  void _openGlobalSearch() {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SearchPage(
        audioFiles: _audioFiles,
        isDark: _effectiveIsDark,
        resolveMeta: (path) {
          final m = _metaCache[path];
          return SearchMeta(title: m?.title, artist: m?.artist, album: m?.album);
        },
        loadCover: (path) async => (await _loadFullMetadata(File(path))).cover,
        onPlay: (path, queue) {
          PlaylistContext.setCurrentPlaylist(queue, pageId: 'search', folderPath: null);
          PlaylistService.saveQueue(queue);
          _playAudioByPath(path, source: 'search');
        },
      ),
    ));
  }

  void _openAlbumsPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AlbumsPage(
          audioFiles: _audioFiles,
          onPlay: (path, index) {
            _playAudio(index, source: 'albums');
          },
          currentPlayingIndex: _currentIndex,
          isDarkMode: _effectiveIsDark,
        ),
      ),
    );
  }

  void _openGenresPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GenresPage(
          audioFiles: _audioFiles,
          metadataCache: _metaCache,
          onPlay: (dynamic indexOrPaths) {
            try {
              if (indexOrPaths is int) {
                _playAudio(indexOrPaths, source: 'genres');
              } else if (indexOrPaths is Map) {
                final paths = List<String>.from(indexOrPaths['paths'] ?? []);
                final startIndex = (indexOrPaths['startIndex'] is int) ? indexOrPaths['startIndex'] as int : 0;
                if (paths.isNotEmpty) {
                  PlaylistContext.setCurrentPlaylist(paths, pageId: 'genres', folderPath: null);
                  PlaylistService.saveQueue(paths);
                  final playPath = (startIndex >= 0 && startIndex < paths.length) ? paths[startIndex] : paths.first;
                  _playAudioByPath(playPath, source: 'genres');
                }
              }
            } catch (e, st) {
              debugPrint('❌ GenresPage onPlay error: $e\n$st');
            }
          },
          currentPlayingIndex: _currentIndex,
        ),
      ),
    );
  }

  void _openSmartMixPage() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SmartMixPage(
          audioFiles: _audioFiles,
          audioPlayer: _audioPlayer,
          onTogglePlayPause: () => _isPlaying ? _pauseAudioAndNotify() : _resumeAudioAndNotify(),
          onPlay: (dynamic playlistPayload) {
            try {
              if (playlistPayload is Map) {
                final paths = List<String>.from(playlistPayload['paths'] ?? []);
                final startIndex = (playlistPayload['startIndex'] is int) ? playlistPayload['startIndex'] as int : 0;
                if (paths.isNotEmpty) {
                  PlaylistContext.setCurrentPlaylist(paths, pageId: 'smart_mix', folderPath: null);
                  PlaylistService.saveQueue(paths);
                  final playPath = (startIndex >= 0 && startIndex < paths.length) ? paths[startIndex] : paths.first;
                  _playAudioByPath(playPath, source: 'smart_mix');
                }
              }
            } catch (e, st) {
              debugPrint('❌ SmartMixPage onPlay error: $e\n$st');
            }
          },
        ),
      ),
    );
  }

  String _truncate(String text, [int maxLen = kMaxTitleLength]) {
    if (text.length <= maxLen) return text;
    return text.substring(0, maxLen - 3) + '...';
  }

  Widget _buildLocalMiniPlayer() {
    return MiniPlayer(
      audioPlayer: _audioPlayer,
      audioFiles: _audioFiles,
      currentIndex: _currentIndex,
      isPlaying: _isPlaying,
      currentPosition: _currentPosition,
      totalDuration: _totalDuration,
      metaCache: _metaCache.map((k, v) => MapEntry(k, {
        'title': v.title,
        'artist': v.artist,
        'album': v.album,
        'year': v.year,
        'duration': v.duration,
        'cover': v.cover,
      })),
      isDarkMode: _effectiveIsDark,
      onOpenFullScreen: _openFullScreenPlayer,
      onNext: () => _playNext(),
      onPrevious: () => _playPrevious(),
      onPlayPause: () {
        if (_isPlaying) {
          _pauseAudio();
        } else {
          if (_currentIndex == -1 && _audioFiles.isNotEmpty) {
            _playAudio(0, source: 'songs');
          } else {
            _resumeAudio();
          }
        }
      },
      loadFullMetadata: (file) async {
        final m = await _loadFullMetadata(file);
        return {'title': m.title, 'artist': m.artist, 'album': m.album, 'year': m.year, 'duration': m.duration, 'cover': m.cover};
      },
      pageId: PlaylistContext.getCurrentPageId() ?? _currentPlaylistSource,
    );
  }

  Widget _buildMiniPlayerBar(BuildContext context) {
    return ValueListenableBuilder<RadioStation?>(
      valueListenable: RadioPlaybackContext.currentStationNotifier,
      builder: (context, station, _) {
        if (station != null) {
          return RadioMiniPlayer(
            station: station,
            audioPlayer: _audioPlayer,
            isDarkMode: _effectiveIsDark,
            onOpenFullScreen: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RadioFullScreenPlayer(audioPlayer: _audioPlayer, isDarkMode: _effectiveIsDark),
            )),
          );
        }
        return ValueListenableBuilder<String?>(
          valueListenable: PlaylistContext.currentPathNotifier,
          builder: (context, currentPath, _) {
            if (currentPath == null && _currentIndex == -1) {
              return const SizedBox.shrink();
            }
            return _buildLocalMiniPlayer();
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    _applySystemUiOverlay();

    return Scaffold(
      backgroundColor: _backgroundColor,
      appBar: _selectedTabIndex == 0 ? _buildLibraryAppBar() : null,
      // Tabs are built lazily and kept alive, so scroll positions survive
      // switching; only the fade-through animates.
      body: TabBodySwitcher(
        index: _selectedTabIndex,
        builders: List.generate(5, (i) => (_) => _buildPageFor(i)),
      ),
      bottomNavigationBar: Container(
        color: _bottomNavBackground,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _buildMiniPlayerBar(context),
          const BannerAdWidget(useSafeArea: false),
          Container(
            decoration: BoxDecoration(
              // Logo theme (dark mode, non-AMOLED): the icon's own background
              // gradient instead of a flat card colour.
              color: _useLogoNavGradient ? null : _bottomNavCardColor,
              gradient: _useLogoNavGradient
                  ? LinearGradient(
                      colors: AppPalette.backgroundGradient!,
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    )
                  : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(_effectiveIsDark ? 0.3 : 0.1),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                )
              ],
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
              ),
            ),
            child: SafeArea(
              bottom: true,
              child: AnimatedNavBar(
                destinations: [
                  NavDestination(Icons.library_music, context.l10n.navLibrary),
                  NavDestination(Icons.radio, context.l10n.navRadio),
                  // Highlighted centre destination: Duo Mode.
                  NavDestination(Icons.headphones_rounded, context.l10n.navDuo),
                  NavDestination(Icons.graphic_eq, context.l10n.navConverter),
                  NavDestination(Icons.settings, context.l10n.navSettings),
                ],
                tabHint: (i, n) => context.l10n.navTabSemantics(i + 1, n),
                centerIndex: 2,
                centerColors: const [kDuoLeftColor, kDuoRightColor],
                currentIndex: _selectedTabIndex,
                // Lightened on dark surfaces so the selected label keeps 4.5:1
                // against the logo gradient (violet alone was ~3.6:1).
                selectedColor: AppPalette.accentText(dark: _effectiveIsDark),
                unselectedColor: _bottomNavSubtitleColor,
                onTap: _onNavTap,
              ),
            ),
          ),
        ]),
      ),
      floatingActionButton: _audioFiles.isEmpty
          ? FloatingActionButton(
        onPressed: () => _requestPermissionAndLoadSongs(forceRescan: true),
        backgroundColor: _primaryColor,
        child: const Icon(Icons.refresh, color: Colors.white),
      )
          : null,
    );
  }
}

class GlobalMiniPlayer extends StatelessWidget {
  const GlobalMiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final host = _AudioPlayerScreenState._current;
    if (host == null) return const SizedBox.shrink();
    return SafeArea(
      bottom: true,
      child: host._buildMiniPlayerBar(context),
    );
  }
}

class _SongRow extends StatefulWidget {
  final File file;
  final bool selected;
  final bool isFav;
  final bool isPlaying;
  final Color primaryColor;
  final Color cardColor;
  final Color textColor;
  final Color subtitleColor;
  final Color backgroundColor;
  final bool isDark;
  final Map<String, SongMeta> metaCache;
  final Set<String> loadingMetadataPaths;
  final Future<SongMeta> Function(File file) loadFullMetadata;
  final String Function(String? artist) displayArtist;
  final String Function(SongMeta? meta) albumAndYear;
  final String Function(String text) truncate;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;
  final VoidCallback onOpenEqualizer;
  final VoidCallback onOpenSleepTimer;
  final VoidCallback onShare;
  final VoidCallback onDelete;
  final VoidCallback onAddToQueue;
  final VoidCallback onAudioConversion;
  final VoidCallback onAudioCutter;
  final VoidCallback? onEditTags;

  const _SongRow({
    super.key,
    required this.file,
    required this.selected,
    required this.isFav,
    required this.isPlaying,
    required this.primaryColor,
    required this.cardColor,
    required this.textColor,
    required this.subtitleColor,
    required this.backgroundColor,
    required this.isDark,
    required this.metaCache,
    required this.loadingMetadataPaths,
    required this.loadFullMetadata,
    required this.displayArtist,
    required this.albumAndYear,
    required this.truncate,
    required this.onTap,
    required this.onToggleFavorite,
    required this.onOpenEqualizer,
    required this.onOpenSleepTimer,
    required this.onShare,
    required this.onDelete,
    required this.onAddToQueue,
    required this.onAudioConversion,
    required this.onAudioCutter,
    this.onEditTags,
  });

  @override
  State<_SongRow> createState() => _SongRowState();
}

class _SongRowState extends State<_SongRow> {
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _ensureMetadataLoaded();
  }

  @override
  void didUpdateWidget(covariant _SongRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) {
      _ensureMetadataLoaded();
    }
  }

  void _ensureMetadataLoaded() {
    final path = widget.file.path;
    final cached = widget.metaCache[path];
    final needsLoad = cached == null || cached.cover == null;
    if (!needsLoad || widget.loadingMetadataPaths.contains(path)) return;

    widget.loadingMetadataPaths.add(path);
    widget.loadFullMetadata(widget.file).then((_) {
      widget.loadingMetadataPaths.remove(path);
      if (mounted) setState(() {});
    }).catchError((_) {
      widget.loadingMetadataPaths.remove(path);
    });
  }

  @override
  Widget build(BuildContext context) {
    final meta = widget.metaCache[widget.file.path];
    final cover = meta?.cover;
    final artistText = widget.displayArtist(meta?.artist);
    final albumYear = widget.albumAndYear(meta);
    // Same rule as the sort key and A-Z headers (_songTitleForSort): the title
    // tag, else the file name without its extension.
    final titleText = TitleCleaner.title(meta?.title, path: widget.file.path);
    final reduceMotion = LibraryMotion.reduced(context);

    final l = context.l10n;
    // One screen-reader node for the row; the favorite and ⋮ buttons stay
    // separate nodes. Decorative art / bars are excluded below.
    final rowLabel = l.songRowSemantics(
        titleText, artistText, widget.selected ? l.nowPlayingState : l.notPlayingState);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: Semantics(
          label: rowLabel,
          button: true,
          selected: widget.selected,
          child: InkWell(
          onTap: () {
            HapticFeedback.selectionClick();
            widget.onTap();
          },
          onHighlightChanged: reduceMotion ? null : (v) => setState(() => _pressed = v),
          borderRadius: BorderRadius.circular(16),
          child: AnimatedScale(
            scale: _pressed ? 0.98 : 1.0,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: widget.selected ? widget.primaryColor.withOpacity(0.12) : widget.cardColor,
              borderRadius: BorderRadius.circular(16),
              border: widget.selected ? Border.all(color: widget.primaryColor, width: 1) : null,
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(widget.isDark ? 0.1 : 0.05), blurRadius: 8, offset: const Offset(0, 2))],
            ),
            child: Row(children: [
              ExcludeSemantics(child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: cover != null
                      ? Image.memory(cover, fit: BoxFit.cover)
                      : Container(
                    color: widget.isDark ? widget.backgroundColor : Colors.grey.shade200,
                    child: Icon(Icons.music_note, color: widget.subtitleColor, size: 20),
                  ),
                ),
              )),
              const SizedBox(width: 12),
              Expanded(
                child: ExcludeSemantics(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(titleText, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: widget.selected ? widget.primaryColor : widget.textColor, fontSize: 14)),
                  const SizedBox(height: 4),
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(artistText, style: TextStyle(color: widget.selected ? widget.primaryColor.withOpacity(0.8) : widget.subtitleColor, fontSize: 12, fontWeight: FontWeight.w600)),
                    if (albumYear.isNotEmpty) Text(albumYear, style: TextStyle(color: widget.selected ? widget.primaryColor.withOpacity(0.7) : widget.subtitleColor, fontSize: 11)),
                  ]),
                ])),
              ),
              AnimatedFavoriteButton(
                isFavorite: widget.isFav,
                inactiveColor: widget.subtitleColor,
                onPressed: widget.onToggleFavorite,
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              ),
              PopupMenuButton<int>(
                tooltip: l.moreOptionsFor(titleText),
                icon: Icon(Icons.more_vert, color: widget.subtitleColor),
                onSelected: (value) {
                  switch (value) {
                    case 1:
                      widget.onOpenEqualizer();
                      break;
                    case 2:
                      widget.onOpenSleepTimer();
                      break;
                    case 3:
                      widget.onShare();
                      break;
                    case 4:
                      widget.onDelete();
                      break;
                    case 5:
                      widget.onAddToQueue();
                      break;
                    case 9:
                      QueueActions.playNextWithFeedback(context, [widget.file.path]);
                      break;
                    case 6:
                      widget.onAudioConversion();
                      break;
                    case 7:
                      widget.onAudioCutter();
                      break;
                    case 8:
                      widget.onEditTags?.call();
                      break;
                    default:
                  }
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 1, child: Text('Equalizer')),
                  PopupMenuItem(value: 2, child: Text('Sleep timer')),
                  PopupMenuItem(value: 3, child: Text('Share')),
                  PopupMenuItem(value: 9, child: Text('Play next')),
                  PopupMenuItem(value: 5, child: Text('Add to Queue')),
                  PopupMenuItem(value: 6, child: Text('Audio Conversion')),
                  PopupMenuItem(value: 7, child: Text('Audio Cutter')),
                  PopupMenuItem(value: 8, child: Text('Edit tags')),
                ],
              ),
              if (widget.selected)
                EqualizerBars(color: widget.primaryColor, playing: widget.isPlaying)
              else
                ExcludeSemantics(child: Icon(Icons.play_arrow, color: widget.subtitleColor, size: 20)),
            ]),
            ),
          ),
        )),
      ),
    );
  }
}