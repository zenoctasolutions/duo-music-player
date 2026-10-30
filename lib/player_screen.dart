// lib/player_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' show log, pow;

import 'package:audio_service/audio_service.dart' hide PlaybackState;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For MethodChannel & PlatformException & SystemChrome
import 'package:hive/hive.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'public_storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_lyrics.dart';
import 'list_page.dart';
import 'online_lyrics.dart';
import 'ringtone_screen.dart';
import 'audio_conversion_service.dart';
import 'audio_conversion_sheet.dart';
import 'app_palette.dart';
import 'audio_quality.dart';
import 'media_store_service.dart';
import 'lyrics_service.dart';
import 'tag_editor_page.dart';
import 'tag_editor_service.dart';
import 'artwork_service.dart';
import 'queues_sheet.dart';
import 'cast_service.dart';
import 'cast_sheet.dart';
import 'ad_widgets.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'l10n/l10n.dart';
import 'player/art_colors.dart';
import 'player/controls.dart';
import 'player/drag_dismiss.dart';
import 'player/marquee_text.dart';
import 'player/now_playing_art.dart';
import 'player/now_playing_route.dart';
import 'player/press_scale.dart';
import 'player/ab_loop.dart';
import 'player/seek_bar.dart';
import 'player/track_text.dart';
import 'library/title_cleaner.dart';
import 'library/queue_actions.dart';
import 'library/queue_logic.dart';
import 'player/visualizer.dart';

/// SharedPreferences keys used by SettingsPage (kept here to read user choices)
const String _prefSeekButtonsEnabled = 'settings_seek_buttons_enabled';
const String _prefSeekSeconds = 'settings_seek_seconds';

/// -------------------- Playlist Service --------------------
class PlaylistService {
  static const String _boxName = 'custom_playlists';
  static const String _queueKey = 'current_queue';

  static Future<Box> _getBox() async {
    if (!Hive.isBoxOpen(_boxName)) {
      return await Hive.openBox(_boxName);
    }
    return Hive.box(_boxName);
  }

  static Future<List<String>> getPlaylistNames() async {
    final box = await _getBox();
    // Filter out the internal queue key from user playlists
    return box.keys.cast<String>().where((k) => k != _queueKey).toList();
  }

  static Future<void> createPlaylist(String name) async {
    final box = await _getBox();
    if (!box.containsKey(name)) {
      await box.put(name, <String>[]);
    }
  }

  static Future<void> addToPlaylist(String playlistName, String songPath) async {
    final box = await _getBox();
    final List<String> current = List<String>.from(
      box.get(playlistName, defaultValue: <String>[]) as List,
    );
    if (!current.contains(songPath)) {
      current.add(songPath);
      await box.put(playlistName, current);
    }
  }

  static Future<void> removeFromPlaylist(String playlistName, String songPath) async {
    final box = await _getBox();
    final List<String> current = List<String>.from(
      box.get(playlistName, defaultValue: <String>[]) as List,
    );
    if (current.contains(songPath)) {
      current.remove(songPath);
      await box.put(playlistName, current);
    }
  }

  static Future<bool> isInPlaylist(String playlistName, String songPath) async {
    final box = await _getBox();
    final List current = box.get(playlistName, defaultValue: []) as List;
    return current.contains(songPath);
  }

  // --- Persistent Queue Methods ---

  static Future<void> saveQueue(List<String> queue) async {
    final box = await _getBox();
    await box.put(_queueKey, queue);
  }

  static Future<List<String>> getQueue() async {
    final box = await _getBox();
    final List result = box.get(_queueKey, defaultValue: []) as List;
    return result.cast<String>();
  }

  static Future<List<String>> getPlaylist(String name) async {
    final box = await _getBox();
    final List result = box.get(name, defaultValue: []) as List;
    return result.cast<String>();
  }

  static Future<bool> playlistExists(String name) async {
    final box = await _getBox();
    return name != _queueKey && box.containsKey(name);
  }

  /// Creates (or replaces) playlist [name] with [paths], keeping their order.
  static Future<void> savePlaylist(String name, List<String> paths) async {
    final box = await _getBox();
    final seen = <String>{};
    await box.put(name, [for (final p in paths) if (seen.add(p)) p]);
  }
}

/// "Save queue as playlist" — asks for a name (confirming before replacing
/// an existing playlist) and saves [paths] in queue order.
Future<void> showSaveQueueAsPlaylistDialog(BuildContext context, List<String> paths) async {
  if (paths.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('The queue is empty'), behavior: SnackBarBehavior.floating));
    return;
  }
  final now = DateTime.now();
  final controller = TextEditingController(
      text: 'Queue ${now.day.toString().padLeft(2, '0')}-${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save queue as playlist'),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${paths.length} song${paths.length == 1 ? '' : 's'}, in the current order.'),
        const SizedBox(height: 12),
        TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Playlist name', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('Save')),
      ],
    ),
  );
  if (name == null || name.isEmpty || !context.mounted) return;
  if (name == 'current_queue') {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please choose a different name'), behavior: SnackBarBehavior.floating));
    return;
  }
  if (await PlaylistService.playlistExists(name)) {
    if (!context.mounted) return;
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace playlist?'),
        content: Text('"$name" already exists. Replace its songs with the current queue?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace')),
        ],
      ),
    );
    if (replace != true) return;
  }
  await PlaylistService.savePlaylist(name, paths);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved playlist "$name"'), behavior: SnackBarBehavior.floating));
  }
}

/// -------------------- Playlist Context --------------------
class PlaylistContext {
  static List<String>? _currentPlaylist;
  static String? _currentPageId;
  static String? _currentFolder;

  static final ValueNotifier<List<String>?> currentPlaylistNotifier =
  ValueNotifier<List<String>?>(null);
  static final ValueNotifier<String?> currentPageIdNotifier =
  ValueNotifier<String?>(null);
  static final ValueNotifier<String?> currentPathNotifier =
  ValueNotifier<String?>(null);
  static final ValueNotifier<String?> currentFolderNotifier =
  ValueNotifier<String?>(null);

  static void setCurrentPlaylist(
      List<String> playlist, {
        String? pageId,
        String? folderPath,
      }) {
    _currentPlaylist = List.from(playlist);
    _currentPageId = pageId;
    _currentFolder = folderPath;
    currentPlaylistNotifier.value = List.from(playlist);
    currentPageIdNotifier.value = pageId;
    currentFolderNotifier.value = folderPath;
  }

  static List<String>? getCurrentPlaylist() => _currentPlaylist;
  static String? getCurrentPageId() => _currentPageId;
  static String? getCurrentFolder() => _currentFolder;

  static void setCurrentPath(String? path) => currentPathNotifier.value = path;

  static void clear() {
    _currentPlaylist = null;
    _currentPageId = null;
    _currentFolder = null;
    currentPlaylistNotifier.value = null;
    currentPageIdNotifier.value = null;
    currentFolderNotifier.value = null;
    currentPathNotifier.value = null;
  }

  static bool isInCurrentPlaylist(String path) =>
      _currentPlaylist?.contains(path) ?? false;

  /// Single shared shuffle flag — read/written by both the Songs page app bar
  /// and the Full Screen Player so neither can drift out of sync with the
  /// other.
  static final ValueNotifier<bool> shuffleEnabledNotifier = ValueNotifier<bool>(false);

  static bool get isShuffleEnabled => shuffleEnabledNotifier.value;

  static void setShuffleEnabled(bool value) => shuffleEnabledNotifier.value = value;

  /// True while a FullScreenPlayer route is on screen. The Songs page's own
  /// track-completion handler checks this so a completed track is only
  /// advanced once (by whichever handler is actually visible) instead of
  /// racing with FullScreenPlayer's own completion handling.
  static bool isFullScreenPlayerOpen = false;

  /// The one shuffle-pick implementation shared by every completion/next
  /// handler in the app: pick any track in [playlist] other than
  /// [currentPath]. Returns null when there is no other candidate.
  static String? pickShuffleCandidate(List<String> playlist, String? currentPath) {
    // "Play next" items go first even in shuffle mode.
    final queued = QueueLogic.pendingNextFor(playlist, currentPath);
    if (queued != null) return queued;
    final candidates = playlist.where((p) => p != currentPath).toList();
    if (candidates.isEmpty) return null;
    return candidates[DateTime.now().millisecondsSinceEpoch % candidates.length];
  }
}

typedef LoadFullMetadataFn = Future<dynamic> Function(File file);
typedef OnPlayAtIndexFn = void Function(int index);
typedef OnToggleFavoriteFn = void Function(String path);
typedef OnDeleteFn = Future<void> Function(String path);
typedef OnShareFn = void Function(String path);
typedef OnChangeSpeedFn = void Function(double speed);

/// Renders [cover] as an image, or [fallback] when there is no cover, the
/// byte data is empty, or the bytes can't be decoded (corrupted/unsupported
/// format). Keeps every album-art call site from having to duplicate the
/// same null/empty/decode-error handling.
Widget buildCoverArt(Uint8List? cover, {required Widget fallback, BoxFit fit = BoxFit.cover}) {
  if (cover == null || cover.isEmpty) return fallback;
  return Image.memory(
    cover,
    fit: fit,
    // Keep showing the old frame while new bytes decode (track change,
    // tag edit) instead of blanking for a frame — that blank read as a
    // flicker on the full-screen player.
    gaplessPlayback: true,
    errorBuilder: (context, error, stackTrace) => fallback,
  );
}

/// -------------------- MiniPlayer --------------------
class MiniPlayer extends StatefulWidget {
  final AudioPlayer audioPlayer;
  final List<File> audioFiles;
  final int currentIndex;
  final bool isPlaying;
  final Duration currentPosition;
  final Duration totalDuration;
  final Map<String, dynamic> metaCache;
  final bool isDarkMode;
  final VoidCallback onOpenFullScreen;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final LoadFullMetadataFn? loadFullMetadata;
  final String? pageId;
  final String? folderPath;

  const MiniPlayer({
    Key? key,
    required this.audioPlayer,
    required this.audioFiles,
    required this.currentIndex,
    required this.isPlaying,
    required this.currentPosition,
    required this.totalDuration,
    required this.metaCache,
    required this.isDarkMode,
    required this.onOpenFullScreen,
    required this.onNext,
    required this.onPrevious,
    required this.onPlayPause,
    this.loadFullMetadata,
    this.pageId,
    this.folderPath,
  }) : super(key: key);

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration?>? _durationSub;

  // Driven by our own stream subscriptions below so the progress bar keeps
  // animating smoothly without requiring the parent screen to rebuild (and
  // therefore rebuild its whole Songs list) on every position tick.
  late Duration _position = widget.currentPosition;
  late Duration _duration = widget.totalDuration;

  // Tint taken from the current cover (null until extracted / no art).
  Color? _tint;
  Uint8List? _tintSourceCover;

  void _syncTint(Uint8List? cover) {
    if (identical(cover, _tintSourceCover)) return;
    _tintSourceCover = cover;
    final cached = ArtColors.peek(cover);
    if (cached != null || cover == null || cover.isEmpty) {
      _tint = cached;
      return;
    }
    ArtColors.extract(cover).then((c) {
      if (!mounted || !identical(_tintSourceCover, cover)) return;
      setState(() => _tint = c);
    });
  }

  @override
  void initState() {
    super.initState();
    PlaylistContext.currentPathNotifier.addListener(_onChange);
    PlaylistContext.currentPlaylistNotifier.addListener(_onChange);

    // Subscribe to audioPlayer's state stream so we stay in sync when play/pause happens anywhere.
    _playerStateSub = widget.audioPlayer.playerStateStream.listen((ps) {
      if (!mounted) return;
      setState(() => _position = widget.audioPlayer.position);
    });

    _positionSub = widget.audioPlayer.positionStream.listen((pos) {
      if (!mounted) return;
      setState(() => _position = pos);
    });

    _durationSub = widget.audioPlayer.durationStream.listen((dur) {
      if (!mounted) return;
      setState(() => _duration = dur ?? Duration.zero);
    });
  }

  void _onChange() {
    if (!mounted) return;
    // A new song started (or the queue changed): resync immediately from the
    // live player instead of waiting for the next stream tick, so the
    // progress bar doesn't briefly show the previous track's position.
    setState(() {
      _position = widget.audioPlayer.position;
      _duration = widget.audioPlayer.duration ?? Duration.zero;
    });
  }

  @override
  void dispose() {
    PlaylistContext.currentPathNotifier.removeListener(_onChange);
    PlaylistContext.currentPlaylistNotifier.removeListener(_onChange);
    _playerStateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    super.dispose();
  }

  List<File> get _effectiveFiles {
    final list = PlaylistContext.getCurrentPlaylist();
    if (list != null && list.isNotEmpty) {
      return list.map((path) {
        try {
          return widget.audioFiles.firstWhere((f) => f.path == path);
        } catch (_) {
          return File(path);
        }
      }).toList();
    }
    return widget.audioFiles;
  }

  String? get _currentPath => PlaylistContext.currentPathNotifier.value;

  int get _effectiveIndex {
    final path = _currentPath;
    if (path == null) return -1;
    return _effectiveFiles.indexWhere((f) => f.path == path);
  }

  File? get _currentFile {
    final idx = _effectiveIndex;
    if (idx >= 0 && idx < _effectiveFiles.length) return _effectiveFiles[idx];
    if (_currentPath != null) return File(_currentPath!);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final file = _currentFile;
    if (file == null) return const SizedBox.shrink();

    // Theme Colors
    final isDark = widget.isDarkMode;
    final backgroundColor = isDark ? AppPalette.darkCard : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final subtitleColor = isDark ? Colors.grey[400] : Colors.grey[600];
    final iconColor = isDark ? Colors.white : const Color(0xFF2D2B4E);

    final meta = widget.metaCache[file.path];
    final cover = meta?['cover'] as Uint8List?;
    final artist = TrackText.artist(meta?['artist']?.toString()) ?? 'Unknown Artist';
    final rawTitle = (meta?['title'] as String?)?.trim();
    final title = TrackText.title(
        (rawTitle != null && rawTitle.isNotEmpty) ? rawTitle : p.basenameWithoutExtension(file.path));
    _syncTint(cover);

    final totalMs = _duration.inMilliseconds;
    final posMs = _position.inMilliseconds;
    final progress = (totalMs == 0) ? 0.0 : (posMs / totalMs);

    // Accent follows the art so the bar matches the full player.
    final primary = _tint == null
        ? AppPalette.accent
        : ArtColors.accent(_tint!, dark: isDark, fallback: AppPalette.accent);
    // Card colour: the normal surface with a soft wash of the art colour.
    final cardColor = _tint == null
        ? backgroundColor
        : Color.lerp(backgroundColor, primary, isDark ? 0.16 : 0.10)!;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final effIdx = _effectiveIndex;
    final canPrev = effIdx > 0;
    final canNext = effIdx < _effectiveFiles.length - 1;

    // Use the actual player state for playing indicator
    final playerState = widget.audioPlayer.playerState;
    final isPlayingNow = playerState.playing;

    return AnimatedContainer(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 450),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: (_tint == null ? Colors.black : primary).withOpacity(isDark ? 0.3 : 0.16),
            blurRadius: 15,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Semantics(
        container: true,
        label: context.l10n.mini,
        // Swiping the bar skips tracks; expose the same to screen readers.
        customSemanticsActions: {
          if (canNext) CustomSemanticsAction(label: context.l10n.swipeNextSong): widget.onNext,
          if (canPrev) CustomSemanticsAction(label: context.l10n.swipePreviousSong): widget.onPrevious,
        },
        child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragEnd: (details) {
          final velocity = details.primaryVelocity ?? 0;
          // A deliberate flick, not an incidental drag — matches the swipe
          // threshold common competitors use for mini-player skip gestures.
          if (velocity.abs() < 250) return;
          if (velocity < 0 && canNext) {
            HapticFeedback.selectionClick();
            widget.onNext();
          } else if (velocity > 0 && canPrev) {
            HapticFeedback.selectionClick();
            widget.onPrevious();
          }
        },
        // Swipe up expands the full player (same as tapping the bar).
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -300) widget.onOpenFullScreen();
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            children: [
              Semantics(
                hint: context.l10n.openPlayer,
                child: InkWell(
                onTap: widget.onOpenFullScreen,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 10, 10, 13),
                  child: Row(
                    children: [
                      // Rounding sits outside the Hero; the flight morphs it.
                      ExcludeSemantics(child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: NowPlayingHero(
                          tag: 'now_playing_art_${file.path}',
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: buildCoverArt(
                              cover,
                              fit: BoxFit.cover,
                              fallback: Container(
                                color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
                                child: Icon(
                                  Icons.music_note,
                                  color: isDark ? Colors.white54 : Colors.grey,
                                  size: 24,
                                ),
                              ),
                            ),
                          ),
                        ),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 250),
                          layoutBuilder: (current, previous) => Stack(
                            alignment: Alignment.centerLeft,
                            children: [...previous, if (current != null) current],
                          ),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(begin: const Offset(0.08, 0), end: Offset.zero).animate(anim),
                              child: child,
                            ),
                          ),
                          child: Column(
                            key: ValueKey(file.path),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: titleColor,
                                ),
                              ),
                              Text(
                                artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: subtitleColor,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      PressScale(
                        onTap: canPrev ? widget.onPrevious : null,
                        semanticLabel: context.l10n.previous,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.skip_previous,
                            color: canPrev ? iconColor : Colors.grey,
                          ),
                        ),
                      ),
                      PressScale(
                        pressedScale: 0.9,
                        onTap: widget.onPlayPause,
                        semanticLabel: isPlayingNow ? context.l10n.pause : context.l10n.play,
                        child: AnimatedContainer(
                          duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 450),
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            gradient: _tint == null
                                ? AppPalette.gradient
                                : LinearGradient(colors: [primary, Color.lerp(primary, Colors.white, 0.25)!]),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: PlayPauseIcon(
                              playing: isPlayingNow,
                              color: _tint == null ? Colors.white : ArtColors.onColor(primary),
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                      PressScale(
                        onTap: canNext ? widget.onNext : null,
                        semanticLabel: context.l10n.next,
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Icon(
                            Icons.skip_next,
                            color: canNext ? iconColor : Colors.grey,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )),
              // Thin progress line along the bottom edge of the card.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ExcludeSemantics(child: IgnorePointer(
                  child: RepaintBoundary(
                    child: SizedBox(
                      height: 3,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: progress.clamp(0.0, 1.0)),
                        duration: const Duration(milliseconds: 250),
                        builder: (context, v, _) => LinearProgressIndicator(
                          value: v,
                          minHeight: 3,
                          backgroundColor: primary.withOpacity(0.18),
                          valueColor: AlwaysStoppedAnimation<Color>(primary),
                        ),
                      ),
                    ),
                  ),
                )),
              ),
            ],
          ),
        ),
      )),
    );
  }
}
/// -------------------- FullScreenPlayer --------------------

class FullScreenPlayer extends StatefulWidget {
  final AudioPlayer audioPlayer;
  final List<File> audioFiles;
  final int initialIndex;
  final Set<String> favorites;
  final dynamic repeatMode;
  final double playbackSpeed;
  final bool equalizerActive;
  final Map<String, dynamic> metaCache;
  final LoadFullMetadataFn loadFullMetadata;
  final OnPlayAtIndexFn onPlayAtIndex;
  final VoidCallback onSkipNext;
  final VoidCallback onSkipPrevious;
  final OnToggleFavoriteFn onToggleFavorite;
  final OnDeleteFn onDelete;
  final OnShareFn onShare;
  final VoidCallback onToggleRepeat;
  final OnChangeSpeedFn onChangePlaybackSpeed;
  final VoidCallback onOpenEqualizer;
  final VoidCallback onOpenSleepTimer;
  final void Function(int? lastIndex) onClose;
  final void Function(bool enabled, Map<int, double> gains) onEqualizerChange;
  final bool isDarkMode;
  final String? pageId;
  final void Function(ConversionRecord record)? onAudioConversionDone;

  const FullScreenPlayer({
    Key? key,
    required this.audioPlayer,
    required this.audioFiles,
    required this.initialIndex,
    required this.favorites,
    required this.repeatMode,
    required this.playbackSpeed,
    required this.equalizerActive,
    required this.metaCache,
    required this.loadFullMetadata,
    required this.onPlayAtIndex,
    required this.onSkipNext,
    required this.onSkipPrevious,
    required this.onToggleFavorite,
    required this.onDelete,
    required this.onShare,
    required this.onToggleRepeat,
    required this.onChangePlaybackSpeed,
    required this.onOpenEqualizer,
    required this.onOpenSleepTimer,
    required this.onClose,
    required this.onEqualizerChange,
    required this.isDarkMode,
    this.pageId,
    this.onAudioConversionDone,
  }) : super(key: key);

  @override
  State<FullScreenPlayer> createState() => _FullScreenPlayerState();
}

enum PlayMode { off, repeatOne }

class _LyricLine {
  final Duration time;
  final String text;
  _LyricLine(this.time, this.text);
}


class _FullScreenPlayerState extends State<FullScreenPlayer> {
  late int _index;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  late double _currentSpeed;
  bool _eqEnabledLocal = false;
  final List<int> _bandFreqs = [60, 230, 910, 3600, 14000];
  final Map<int, double> _bandGains = {};

  late LoopMode _currentRepeatMode;
  final Set<String> _localFavorites = <String>{};

  final PageController _pageController = PageController(initialPage: 0);
  int _currentPage = 0;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription<SequenceState?>? _seqSub;
  StreamSubscription<double>? _speedSub;

  // ---- A-B repeat + pitch (see player/ab_loop.dart) ------------------
  final AbLoop _ab = AbLoop();
  DateTime _abLastSeek = DateTime.fromMillisecondsSinceEpoch(0);
  String? _abTrackPath;
  ProcessingState? _prevProcState;
  // Pitch in semitones. Static so it lasts for the app session only (not
  // persisted to disk); the Reset button sets it back to 0.
  static int _sessionSemitones = 0;
  StreamSubscription<LoopMode>? _loopSub;
  StreamSubscription<ProcessingState>? _processingSub;
  late VoidCallback _playlistListener;

  PlayMode _playMode = PlayMode.off;

  String? _rawLyrics;
  List<_LyricLine>? _lrcLines;
  int _currentLyricIndex = -1;
  List<GlobalKey> _lyricKeys = [];
  DateTime _lastLyricsUserScroll = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fetchingLyrics = false;

  // Tap-to-sync: plain lyrics (typically pasted from a website) are timed by
  // tapping as each line starts; the result is saved as LRC.
  List<String>? _tapSyncLines;
  final List<Duration> _tapSyncTimes = [];

  // Per-track base colour, extracted from the current cover art. The screen
  // gradient and every accent (play button, slider, chips, page dots) derive
  // from this one colour and animate between tracks (see build()).
  // `_accentColorSourceCover` dedupes extraction to only run when the cover
  // actually changes (not on every rebuild).
  static Color get _defaultAccent => AppPalette.accent;
  Color? _accentColor;
  Uint8List? _accentColorSourceCover;

  // Playback position lives in a notifier so the seek bar and visualizer can
  // update every tick without rebuilding this whole screen.
  final ValueNotifier<Duration> _posNotifier = ValueNotifier<Duration>(Duration.zero);

  // Art slide direction (1 = next, -1 = previous) and optional visualizer.
  int _lastBuiltIndex = -1;
  int _artDirection = 1;
  bool _showVisualizer = false;
  static const String _prefShowVisualizer = 'player_show_visualizer';

  void _maybeUpdateAccentColor(Uint8List? cover) {
    if (identical(cover, _accentColorSourceCover)) return;
    _accentColorSourceCover = cover;

    if (cover == null || cover.isEmpty) {
      if (_accentColor != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _accentColor = null);
        });
      }
      return;
    }

    // Cached colour: apply immediately so the first frame is already right.
    final cached = ArtColors.peek(cover);
    if (cached != null) {
      _accentColor = cached;
      return;
    }
    ArtColors.extract(cover).then((color) {
      if (!mounted || !identical(_accentColorSourceCover, cover)) return;
      if (color != null) setState(() => _accentColor = color);
    });
  }

  /// Closes the player the same way the header chevron does.
  void _closePlayer() {
    final main = _mainIndexFromEffectiveIndex(_index);
    widget.onClose(main != -1 ? main : _index);
    Navigator.pop(context);
  }

  // MethodChannel for platform delete fallback
  static const MethodChannel _platformFileChannel =
  MethodChannel('music_app/file_utils');

  List<File> get _effectiveFiles {
    final current = PlaylistContext.getCurrentPlaylist();
    if (current != null && current.isNotEmpty) {
      return current.map((path) {
        try {
          return widget.audioFiles.firstWhere((f) => f.path == path);
        } catch (_) {
          return File(path);
        }
      }).toList();
    }
    return widget.audioFiles;
  }

  int _mainIndexFromEffectiveIndex(int effIdx) {
    if (effIdx < 0 || effIdx >= _effectiveFiles.length) return -1;
    final path = _effectiveFiles[effIdx].path;
    return widget.audioFiles.indexWhere((f) => f.path == path);
  }

  int _effectiveIndexFromPath(String pathId) {
    return _effectiveFiles.indexWhere((f) => f.path == pathId);
  }

  // --- Seek button prefs local state (read from SharedPreferences) ---
  bool _seekButtonsEnabledLocal = false;
  int _seekSecondsLocal = 10;
  // -------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    // While this screen is on top, it is the sole handler of track
    // completion (see _onTrackComplete) — the Songs page's own completion
    // handler checks this flag and steps aside to avoid both handlers
    // racing to advance the same completed track.
    PlaylistContext.isFullScreenPlayerOpen = true;

    // Initialize local lyrics storage (safe to call multiple times)
    LocalLyricsManager.init();

    _currentRepeatMode = widget.audioPlayer.loopMode;
    _localFavorites.addAll(widget.favorites);

    final initialPath = (widget.initialIndex >= 0 &&
        widget.initialIndex < widget.audioFiles.length)
        ? widget.audioFiles[widget.initialIndex].path
        : null;
    _index = 0;
    if (initialPath != null) {
      final eff = _effectiveIndexFromPath(initialPath);
      _index = eff != -1 ? eff : 0;
    }

    _currentSpeed = widget.playbackSpeed;
    if (_sessionSemitones != 0) _applyPitch(_sessionSemitones, force: true);
    _eqEnabledLocal = widget.equalizerActive;
    for (int i = 0; i < _bandFreqs.length; i++) _bandGains[i] = 0.0;

    _updatePlayModeFromState();

    _posSub = widget.audioPlayer.positionStream.listen((p) {
      if (!mounted) return;
      // Only the seek bar / visualizer listen to the notifier; rebuild the
      // whole screen just when the highlighted lyric line actually changes.
      _position = p;
      _posNotifier.value = p;
      _abOnPosition(p);
      final lyricBefore = _currentLyricIndex;
      _updateCurrentLyricIndex();
      if (_currentLyricIndex != lyricBefore) setState(() {});
    });

    _durSub = widget.audioPlayer.durationStream.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d ?? Duration.zero;
      });
    });

    _playerStateSub = widget.audioPlayer.playerStateStream.listen((ps) {
      if (!mounted) return;
      setState(() => _isPlaying = ps.playing);
      // The native player can drop pitch when a source is (re)loaded; re-apply
      // when it becomes ready again.
      if (ps.processingState == ProcessingState.ready &&
          _prevProcState != ProcessingState.ready) {
        _applyPitch(_sessionSemitones, force: true);
      }
      _prevProcState = ps.processingState;
    });

    _loopSub = widget.audioPlayer.loopModeStream.listen((lm) {
      if (!mounted) return;
      setState(() {
        _currentRepeatMode = lm;
        _updatePlayModeFromState();
      });
    });

    _seqSub = widget.audioPlayer.sequenceStateStream.listen((ss) {
      if (!mounted) return;
      try {
        final currentSource = ss?.currentSource;
        if (currentSource != null) {
          final tag = currentSource.tag;
          String? pathId;
          if (tag is MediaItem)
            pathId = tag.id;
          else if (tag is Map)
            pathId = (tag['filePath'] as String?) ??
                (tag['id'] as String?) ??
                (tag['path'] as String?);
          else if (tag is String) pathId = tag;

          if (pathId != null) {
            if (_abTrackPath != null && pathId != _abTrackPath) {
              // New track: the A-B loop belongs to the old one.
              if (!_ab.isIdle) setState(_ab.clear);
              _applyPitch(_sessionSemitones, force: true);
            }
            _abTrackPath = pathId;
            PlaylistContext.setCurrentPath(pathId);
            final effFound = _effectiveIndexFromPath(pathId);
            if (effFound != -1 && effFound != _index) {
              setState(() => _index = effFound);
              _ensureLoaded(effFound);
              _loadLyricsForIndex(effFound);
            }
          }
        }
      } catch (_) {}
    });

    _speedSub = widget.audioPlayer.speedStream.listen((s) {
      if (!mounted) return;
      setState(() => _currentSpeed = s);
    });

    _processingSub =
        widget.audioPlayer.processingStateStream.listen((ps) {
          if (!mounted) return;
          if (ps == ProcessingState.completed) {
            _onTrackComplete();
          }
        });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureLoaded(_index);
      widget.onEqualizerChange(
          _eqEnabledLocal, Map<int, double>.from(_bandGains));
      final effective = _effectiveFiles;
      if (effective.isNotEmpty) {
        final paths = effective.map((f) => f.path).toList();
        PlaylistContext.setCurrentPlaylist(paths, pageId: widget.pageId);
        // Save initial queue if created from main list
        PlaylistService.saveQueue(paths);
      }
      _loadLyricsForIndex(_index);
    });

    _playlistListener = () {
      if (!mounted) return;
      final currentPath = PlaylistContext.currentPathNotifier.value;
      if (currentPath != null) {
        final effFound = _effectiveIndexFromPath(currentPath);
        if (effFound != -1 && effFound != _index) {
          setState(() {
            _index = effFound;
            _ensureLoaded(effFound);
            _loadLyricsForIndex(effFound);
          });
        }
      }
    };
    PlaylistContext.currentPlaylistNotifier.addListener(_playlistListener);
    TagEditorService.edited.addListener(_onTagsEdited);
    ArtworkService.instance.downloaded.addListener(_onArtworkDownloaded);

    _pageController.addListener(() {
      final p = _pageController.page?.round() ?? 0;
      if (p != _currentPage) {
        setState(() => _currentPage = p);
      }
    });

    // Load seek prefs for showing/hiding seek buttons and seconds
    _loadSeekPrefs();
    _loadVisualizerPref();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playerStateSub?.cancel();
    _seqSub?.cancel();
    _speedSub?.cancel();
    _loopSub?.cancel();
    _processingSub?.cancel();
    PlaylistContext.currentPlaylistNotifier.removeListener(_playlistListener);
    TagEditorService.edited.removeListener(_onTagsEdited);
    ArtworkService.instance.downloaded.removeListener(_onArtworkDownloaded);
    PlaylistContext.isFullScreenPlayerOpen = false;
    _pageController.dispose();
    _posNotifier.dispose();
    super.dispose();
  }

  // ---- A-B repeat -------------------------------------------------
  void _abOnPosition(Duration p) {
    if (!_ab.isActive) return;
    // Let a just-issued seek settle before judging positions again.
    if (DateTime.now().difference(_abLastSeek).inMilliseconds < 500) return;
    final tick = _ab.onPosition(p);
    if (tick.seekTo != null) {
      _abLastSeek = DateTime.now();
      widget.audioPlayer.seek(tick.seekTo!);
    } else if (tick.cleared) {
      setState(() {});
      _abSnack(context.l10n.abLoopCleared);
    }
  }

  void _abSnack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2)));
  }

  void _onAbTap() {
    final r = _ab.tap(widget.audioPlayer.position);
    setState(() {});
    HapticFeedback.selectionClick();
    switch (r) {
      case AbTapResult.aSet:
        _abSnack(context.l10n.abSetAt(formatDuration(_ab.a!)));
        break;
      case AbTapResult.activated:
        _abSnack(context.l10n.abLooping(formatDuration(_ab.a!), formatDuration(_ab.b!)));
        break;
      case AbTapResult.cleared:
        _abSnack(context.l10n.abLoopCleared);
        break;
      case AbTapResult.rejectedTooShort:
        _abSnack(context.l10n.abTooShort);
        break;
    }
  }

  // ---- Pitch ------------------------------------------------------
  Future<void> _applyPitch(int semitones, {bool force = false}) async {
    final ratio = semitonesToRatio(semitones);
    if (!force && (widget.audioPlayer.pitch - ratio).abs() < 1e-6) return;
    if (force && semitones == 0 && (widget.audioPlayer.pitch - 1.0).abs() < 1e-6) return;
    try {
      await widget.audioPlayer.setPitch(ratio);
    } catch (e) {
      debugPrint('setPitch failed: $e');
    }
  }

  Future<void> _loadVisualizerPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final on = prefs.getBool(_prefShowVisualizer) ?? false;
      if (mounted && on != _showVisualizer) setState(() => _showVisualizer = on);
    } catch (e) {
      debugPrint('Failed to load visualizer pref: $e');
    }
  }

  Future<void> _saveVisualizerPref(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefShowVisualizer, on);
    } catch (e) {
      debugPrint('Failed to save visualizer pref: $e');
    }
  }

  Future<void> _loadSeekPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_prefSeekButtonsEnabled);
      final secs = prefs.getInt(_prefSeekSeconds);
      setState(() {
        _seekButtonsEnabledLocal = enabled ?? false;
        _seekSecondsLocal = secs ?? 10;
      });
    } catch (e) {
      debugPrint('Failed to load seek prefs: $e');
    }
  }

  /// Tags were saved from the editor opened on top of this screen.
  /// [widget.metaCache] is a snapshot taken when the player opened, so drop
  /// the stale entry and re-read the file — otherwise the new title/artist/
  /// cover only showed after closing and reopening the player.
  Future<void> _onTagsEdited() => _reloadMetaFor(TagEditorService.edited.value);

  /// A missing cover was downloaded (Settings → Appearance) while open.
  Future<void> _onArtworkDownloaded() => _reloadMetaFor(ArtworkService.instance.downloaded.value);

  Future<void> _reloadMetaFor(String? path) async {
    if (path == null || !mounted) return;
    widget.metaCache.remove(path);
    try {
      final meta = await widget.loadFullMetadata(File(path));
      if (!mounted) return;
      setState(() => widget.metaCache[path] = meta);
    } catch (_) {
      if (mounted) setState(() {});
    }
  }

  Future<void> _ensureLoaded(int idx) async {
    if (idx < 0 || idx >= _effectiveFiles.length) return;
    final file = _effectiveFiles[idx];
    if (widget.metaCache[file.path] != null) return;
    try {
      final meta = await widget.loadFullMetadata(file);
      if (!mounted) return;
      setState(() => widget.metaCache[file.path] = meta);
    } catch (_) {}
  }

  void _playIndex(int effIdx) {
    if (effIdx < 0 || effIdx >= _effectiveFiles.length) return;
    final mainIdx = _mainIndexFromEffectiveIndex(effIdx);
    if (mainIdx != -1) {
      widget.onPlayAtIndex(mainIdx);
    } else {
      // This queue entry isn't part of widget.audioFiles (e.g. a restored
      // queue referencing a file the library scan no longer has), so there
      // is no valid global index for it. onPlayAtIndex always resolves its
      // argument against widget.audioFiles — passing effIdx here would
      // silently play (and notify about) whatever unrelated song happens to
      // sit at that position in the main library instead of this track.
      debugPrint('Skipping play for "${_effectiveFiles[effIdx].path}": not found in main library list');
      return;
    }
    final path = _effectiveFiles[effIdx].path;
    // Don't recreate the playlist if it's already set correctly, just update the path
    if (!PlaylistContext.isInCurrentPlaylist(path)) {
      final paths = _effectiveFiles.map((f) => f.path).toList();
      PlaylistContext.setCurrentPlaylist(paths, pageId: widget.pageId);
      PlaylistService.saveQueue(paths);
    }
    PlaylistContext.setCurrentPath(path);
    setState(() => _index = effIdx);
    _ensureLoaded(effIdx);
    _loadLyricsForIndex(effIdx);
  }

  // The queue is circular: Previous/Next always have somewhere to go as long
  // as there is more than one track, wrapping around at either end.
  bool _canGoPrevious() => _effectiveFiles.length > 1;
  bool _canGoNext() => _effectiveFiles.length > 1;

  /// Picks the next effective index using the single shared shuffle
  /// implementation (PlaylistContext.pickShuffleCandidate), matching the
  /// Songs page's own shuffle behavior exactly. Returns null when shuffle is
  /// off or there is no other candidate.
  int? _shuffleNextIndex() {
    if (!PlaylistContext.isShuffleEnabled || _effectiveFiles.isEmpty) return null;
    final paths = _effectiveFiles.map((f) => f.path).toList();
    final currentPath = _effectiveFiles[_index].path;
    final pick = PlaylistContext.pickShuffleCandidate(paths, currentPath);
    if (pick == null) return null;
    final idx = _effectiveIndexFromPath(pick);
    return idx == -1 ? null : idx;
  }

  // Previous/Next delegate to the Songs page's _playNext/_playPrevious
  // (via widget.onSkipNext/onSkipPrevious, the same callbacks the
  // notification's skip buttons use) rather than keeping a second local copy
  // of the shuffle/sequential/wrap decision — that decision also drives
  // whether a gapless native seekToNext()/seekToPrevious() can be used
  // (see songs_page.dart's _playNext/_playPrevious), which only the shared
  // _audioPlayer's owner can resolve correctly. This screen's own _index/UI
  // stays in sync via the existing sequenceStateStream listener below, which
  // already handles the Map-tagged sources gapless playback uses.
  void _playPrevious() {
    if (!_canGoPrevious()) return;
    widget.onSkipPrevious();
  }

  void _playNext() {
    if (!_canGoNext()) return;
    widget.onSkipNext();
  }

  void _onTrackComplete() {
    if (widget.audioPlayer.loopMode == LoopMode.one) {
      widget.audioPlayer.seek(Duration.zero);
      widget.audioPlayer.play();
      return;
    }
    if (widget.audioPlayer.audioSource is ConcatenatingAudioSource) {
      // Gapless native queue: mid-queue transitions never reach
      // ProcessingState.completed (only the very last item does), so this
      // is always an end-of-queue/wrap-around decision — delegate to the
      // same logic the skip button and notification already use instead of
      // duplicating the native-seek/wrap/shuffle-fallback branching here.
      widget.onSkipNext();
      return;
    }
    if (_effectiveFiles.isEmpty) return;
    final shuffled = _shuffleNextIndex();
    if (shuffled != null) {
      _playIndex(shuffled);
      return;
    }
    if (_index < _effectiveFiles.length - 1) {
      _playIndex(_index + 1);
    } else {
      // Last song finished — wrap back to the first instead of stopping.
      _playIndex(0);
    }
  }

  void _cyclePlayMode() {
    setState(() {
      switch (_playMode) {
        case PlayMode.off:
          _playMode = PlayMode.repeatOne;
          widget.audioPlayer.setLoopMode(LoopMode.one);
          break;
        case PlayMode.repeatOne:
          _playMode = PlayMode.off;
          widget.audioPlayer.setLoopMode(LoopMode.off);
          break;
      }
      _currentRepeatMode = widget.audioPlayer.loopMode;
    });

    final String label = switch (_playMode) {
      PlayMode.off => 'Repeat Off',
      PlayMode.repeatOne => 'Repeat One',
    };

    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          backgroundColor: AppPalette.accent,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
  }

  void _updatePlayModeFromState() {
    if (widget.audioPlayer.loopMode == LoopMode.one) {
      _playMode = PlayMode.repeatOne;
    } else {
      _playMode = PlayMode.off;
    }
  }

  /// Media access needed before deleting audio. READ_MEDIA_AUDIO on
  /// Android 13+ (permission_handler maps Permission.audio to
  /// READ_EXTERNAL_STORAGE below that). Android 6-9 additionally needs
  /// legacy WRITE_EXTERNAL_STORAGE for a direct File.delete; on Android 10+
  /// deletion goes through MediaStore / the system consent dialog instead.
  Future<bool> _ensureStoragePermission() async {
    try {
      if (!Platform.isAndroid) return true;
      var status = await Permission.audio.status;
      if (!status.isGranted) status = await Permission.audio.request();
      if (!status.isGranted) {
        if (status.isPermanentlyDenied) _showPermissionDeniedDialog();
        return false;
      }
      final sdk = await PublicStorageService.instance.sdkInt();
      if (sdk <= 28 && !await Permission.storage.isGranted) {
        final w = await Permission.storage.request();
        if (!w.isGranted) {
          if (w.isPermanentlyDenied) _showPermissionDeniedDialog();
          return false;
        }
      }
      return true;
    } catch (e) {
      debugPrint('Permission check error: $e');
      return false;
    }
  }

  void _showPermissionDeniedDialog() {
    final isDark = widget.isDarkMode;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppPalette.darkCard : Colors.white,
        title: Text('Storage Permission Required',
            style: TextStyle(color: isDark ? Colors.white : Colors.black)),
        content: Text(
          'This app needs storage permission to delete audio files. Please grant the permission in app settings.',
          style:
          TextStyle(color: isDark ? Colors.grey[300] : Colors.black87),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<bool> _deleteFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return true;

      try {
        if (widget.audioPlayer.playing) await widget.audioPlayer.pause();
        await widget.audioPlayer.stop();
      } catch (e) {
        debugPrint('Error stopping player: $e');
      }

      // 1. Try direct delete
      const int maxAttempts = 4;
      int attempt = 0;
      while (attempt < maxAttempts) {
        attempt++;
        try {
          await file.delete();
          if (!await file.exists()) return true;
        } catch (_) {}
        await Future.delayed(Duration(milliseconds: 150 * attempt));
      }

      // 2. Try platform channel fallback (Android)
      if (Platform.isAndroid) {
        try {
          final res = await _platformFileChannel
              .invokeMethod<bool>('deleteFile', {'path': path});
          if (res == true && !await File(path).exists()) return true;
        } catch (_) {}

        try {
          final resSaf = await _platformFileChannel
              .invokeMethod<bool>('deleteFileSaf', {'path': path});
          if (resSaf == true && !await File(path).exists()) return true;
        } catch (_) {}

        try {
          final resMs = await _platformFileChannel.invokeMethod<bool>(
              'deleteMediaStoreEntry', {'path': path});
          if (resMs == true && !await File(path).exists()) return true;
        } catch (_) {}
      }

      return !await file.exists();
    } catch (e) {
      return false;
    }
  }

  Future<void> _handleDelete() async {
    if (_index < 0 || _index >= _effectiveFiles.length) return;

    final fileToDelete = _effectiveFiles[_index];
    final path = fileToDelete.path;
    final fileName = p.basename(path);
    final isDark = widget.isDarkMode;

    if (Platform.isAndroid) {
      final hasPermission = await _ensureStoragePermission();
      if (!hasPermission) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Storage permission required'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }
    }

    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppPalette.darkCard : Colors.white,
        title:
        Text("Delete File", style: TextStyle(color: isDark ? Colors.white : Colors.black)),
        content: Text("Delete $fileName?",
            style: TextStyle(color: isDark ? Colors.grey[300] : Colors.black87)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Delete", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleting $fileName...'), duration: const Duration(seconds: 2)),
      );
    }

    bool wasPlaying = _isPlaying;
    try {
      final deleted = await _deleteFile(path);
      if (deleted) {
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Deleted successfully"), backgroundColor: Colors.green));
        }
        await widget.onDelete(path);

        final remainingFiles = _effectiveFiles.where((f) => f.path != path).toList();
        if (remainingFiles.isEmpty) {
          if (mounted) {
            widget.onClose(null);
            Navigator.of(context).pop();
          }
        } else {
          int nextIndex = _index >= remainingFiles.length ? remainingFiles.length - 1 : _index;
          if (nextIndex >= 0) _playIndex(nextIndex);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Delete failed"), backgroundColor: Colors.red));
        }
        if (wasPlaying) try { await widget.audioPlayer.play(); } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
      }
      if (wasPlaying) try { await widget.audioPlayer.play(); } catch (_) {}
    }
  }

  String _truncate(String text, [int max = 30]) {
    if (text.length <= max) return text;
    return text.substring(0, max - 3) + '...';
  }

  String _getFileName(String path) => p.basename(path);

  /// -------------------- UPDATED: load lyrics (prefers local saved lyrics) --------------------
  Future<void> _loadLyricsForIndex(int idx) async {
    _tapSyncLines = null;
    _tapSyncTimes.clear();
    _rawLyrics = null;
    _lrcLines = null;
    _currentLyricIndex = -1;
    _lyricKeys = [];

    if (idx < 0 || idx >= _effectiveFiles.length) {
      if (mounted) setState(() {});
      return;
    }

    final file = _effectiveFiles[idx];
    // Saved (Hive) → embedded tags → sidecar .lrc — see LyricsService.
    final found = await LyricsService.findLocal(file.path);
    // Ignore a late result if the user already skipped to another song.
    if (idx != _index || !mounted) return;
    if (found != null) {
      _rawLyrics = found.raw;
      _lrcLines = _parseLrc(found.raw);
      _updateCurrentLyricIndex();
    }
    setState(() {});
  }
  /// -----------------------------------------------------------------------------


  /// Timestamped lines for synced (LRC) lyrics, or null for plain lyrics —
  /// plain lyrics are rendered as static text from [_rawLyrics] instead.
  List<_LyricLine>? _parseLrc(String raw) {
    final parsed = LrcParser.parse(raw);
    if (!parsed.synced || parsed.lines.isEmpty) return null;
    final lines = parsed.lines.map((l) => _LyricLine(l.time, l.text)).toList();
    _lyricKeys = List.generate(lines.length, (_) => GlobalKey());
    return lines;
  }

  void _updateCurrentLyricIndex() {
    final lines = _lrcLines;
    if (lines == null || lines.isEmpty) return;
    var lo = 0, hi = lines.length - 1, idx = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= _position) {
        idx = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (idx != _currentLyricIndex) {
      _currentLyricIndex = idx;
      _scrollLyricIntoView();
    }
  }

  /// Keeps the current synced line centred, unless the user scrolled the
  /// lyrics themselves in the last few seconds.
  void _scrollLyricIntoView() {
    if (_currentPage != 1 || _currentLyricIndex < 0 || _currentLyricIndex >= _lyricKeys.length) return;
    if (DateTime.now().difference(_lastLyricsUserScroll) < const Duration(seconds: 4)) return;
    final key = _lyricKeys[_currentLyricIndex];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx, alignment: 0.4, duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    });
  }

  /// "Find synced lyrics" — LRCLIB lookup, saved locally on success.
  Future<void> _findLyricsOnline(File file, {String? titleOverride}) async {
    final meta = widget.metaCache[file.path];
    final title = (titleOverride?.trim().isNotEmpty == true)
        ? titleOverride!.trim()
        : ((meta?['title'] as String?)?.trim().isNotEmpty == true ? (meta!['title'] as String) : p.basenameWithoutExtension(file.path));
    final artist = meta?['artist'] as String?;
    final album = meta?['album'] as String?;
    final duration = (meta?['duration'] as Duration?) ?? widget.audioPlayer.duration;
    // Already have (plain) lyrics: only a synced version is worth fetching —
    // never swap the user's pasted lyrics for another unsynced copy.
    final hasLyrics = _rawLyrics != null && _rawLyrics!.trim().isNotEmpty;
    setState(() => _fetchingLyrics = true);
    try {
      final res = await LyricsService.fetchOnline(
          path: file.path, title: title, artist: artist, album: album, duration: duration, syncedOnly: hasLyrics);
      if (!mounted) return;
      if (res == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(hasLyrics
              ? 'No synced version found online. Tap "Sync manually" to time these lyrics to the song.'
              : 'No lyrics found for "$title"'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
          persist: false,
          action: hasLyrics ? SnackBarAction(label: 'Sync manually', onPressed: _startTapSync) : null,
        ));
      } else {
        _rawLyrics = res.raw;
        _lrcLines = _parseLrc(res.raw);
        _currentLyricIndex = -1;
        _updateCurrentLyricIndex();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(_lrcLines != null ? 'Synced lyrics found and saved' : 'Lyrics found and saved (not synced)'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Couldn\'t reach the lyrics service. Check your connection.'), behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _fetchingLyrics = false);
    }
  }

  /// Starts tap-to-sync for the current plain lyrics: restarts the song and
  /// shows one line at a time; each tap stamps the line with the position.
  void _startTapSync() {
    final raw = _rawLyrics;
    if (raw == null || !mounted) return;
    final lines = LrcParser.parse(raw).lines.map((l) => l.text.trim()).where((t) => t.isNotEmpty).toList();
    if (lines.isEmpty) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    setState(() {
      _tapSyncLines = lines;
      _tapSyncTimes.clear();
    });
    if (_pageController.hasClients && _currentPage != 1) {
      _pageController.animateToPage(1, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
    widget.audioPlayer.seek(Duration.zero);
    if (!widget.audioPlayer.playing) widget.audioPlayer.play();
  }

  Future<void> _tapSyncStamp() async {
    final lines = _tapSyncLines;
    if (lines == null || _tapSyncTimes.length >= lines.length) return;
    var t = widget.audioPlayer.position;
    if (_tapSyncTimes.isNotEmpty && t < _tapSyncTimes.last) t = _tapSyncTimes.last;
    setState(() => _tapSyncTimes.add(t));
    if (_tapSyncTimes.length == lines.length) await _finishTapSync();
  }

  /// Un-stamps the last line and rewinds a little so it can be tapped again.
  void _tapSyncUndo() {
    if (_tapSyncTimes.isEmpty) return;
    final last = _tapSyncTimes.removeLast();
    final back = last - const Duration(seconds: 3);
    widget.audioPlayer.seek(back.isNegative ? Duration.zero : back);
    setState(() {});
  }

  void _cancelTapSync() => setState(() {
        _tapSyncLines = null;
        _tapSyncTimes.clear();
      });

  Future<void> _finishTapSync() async {
    final lines = _tapSyncLines;
    if (lines == null || _index < 0 || _index >= _effectiveFiles.length) return;
    final path = _effectiveFiles[_index].path;
    final lrc = LrcParser.toLrc([
      for (var i = 0; i < lines.length && i < _tapSyncTimes.length; i++) LyricLine(_tapSyncTimes[i], lines[i]),
    ]);
    await LocalLyricsManager.saveLyrics(path, lrc);
    if (!mounted) return;
    setState(() {
      _tapSyncLines = null;
      _tapSyncTimes.clear();
      _rawLyrics = lrc;
      _lrcLines = _parseLrc(lrc);
      _currentLyricIndex = -1;
      _updateCurrentLyricIndex();
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Lyrics synced and saved'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _buildTapSyncView(bool isDark) {
    final lines = _tapSyncLines!;
    final next = _tapSyncTimes.length;
    final dim = isDark ? Colors.white54 : Colors.black45;
    final strong = isDark ? Colors.white : Colors.black87;
    String fmt(Duration d) =>
        '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          children: [
            Text('Tap "Sync line" the moment each line starts',
                textAlign: TextAlign.center, style: TextStyle(color: dim, fontSize: 13)),
            const SizedBox(height: 4),
            Text('$next / ${lines.length}', style: TextStyle(color: dim, fontSize: 12)),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (next > 0)
                    Text('${fmt(_tapSyncTimes[next - 1])}  ${lines[next - 1]}',
                        textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: dim, fontSize: 14)),
                  const SizedBox(height: 14),
                  if (next < lines.length)
                    Text(lines[next],
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppPalette.accent, fontSize: 20, fontWeight: FontWeight.w700, height: 1.3)),
                  const SizedBox(height: 14),
                  for (var i = next + 1; i < lines.length && i <= next + 2; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(lines[i],
                          textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: strong.withOpacity(0.6), fontSize: 14)),
                    ),
                ],
              ),
            ),
            Row(
              children: [
                IconButton(
                  tooltip: 'Undo last line',
                  onPressed: _tapSyncTimes.isEmpty ? null : _tapSyncUndo,
                  icon: Icon(Icons.undo_rounded, color: _tapSyncTimes.isEmpty ? dim.withOpacity(0.3) : strong),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _tapSyncStamp,
                    icon: const Icon(Icons.touch_app_rounded, color: Colors.white),
                    label: const Text('Sync line', style: TextStyle(color: Colors.white, fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppPalette.accent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Cancel syncing',
                  onPressed: _cancelTapSync,
                  icon: Icon(Icons.close_rounded, color: strong),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// -------------------- NEW: Add/Edit local lyrics dialog --------------------
  void _showAddLocalLyricsDialog(File file) {
    final isDark = widget.isDarkMode;
    final textController = TextEditingController();

    // Prefill with local lyrics if present, otherwise try meta/sidecar quick load.
    // PRESERVE user formatting (do NOT trim).
    () async {
      try {
        final local = await LocalLyricsManager.getLyrics(file.path);
        if (local != null) {
          textController.text = local;
          return;
        }
        final meta = widget.metaCache[file.path];
        if (meta != null) {
          final candidates = [
            meta['lyrics'], meta['LYRICS'], meta['lyric'], meta['Lyric'],
            meta['unsyncedLyrics'], meta['lyrics_text']
          ];
          for (final c in candidates) {
            if (c is String && c.trim().isNotEmpty) {
              textController.text = c;
              return;
            }
          }
        }
        final dir = p.dirname(file.path);
        final base = p.basenameWithoutExtension(file.path);
        final lrcPath = p.join(dir, '$base.lrc');
        final f = File(lrcPath);
        if (await f.exists()) {
    final s = await f.readAsString();
    if (s.isNotEmpty) textController.text = s;
    }
    } catch (_) {}
    }();

    showDialog(
    context: context,
    builder: (ctx) {
    return Dialog(
    backgroundColor: isDark ? AppPalette.darkCard : Colors.white,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
    child: SizedBox(
    height: MediaQuery.of(context).size.height * 0.65,
    child: Column(
    children: [
    const SizedBox(height: 16),
    Text('Add / Edit Lyrics', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    Expanded(
    child: Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: TextField(
    controller: textController,
    maxLines: null,
    minLines: 10,
    keyboardType: TextInputType.multiline,
    textAlignVertical: TextAlignVertical.top,
    decoration: const InputDecoration(
    border: OutlineInputBorder(),
    contentPadding: EdgeInsets.all(12),
    ),
    ),
    ),
    ),
    const SizedBox(height: 12),
    Row(
    mainAxisAlignment: MainAxisAlignment.end,
    children: [
    TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: AppPalette.accent))),
    const SizedBox(width: 8),
    TextButton(
    onPressed: () async {
    String val = textController.text;
    // Check for "cleared" before padding: the old leading-newline
    // padding made an emptied box look non-empty, so lyrics could
    // never be removed.
    final cleared = val.trim().isEmpty;

    if (!cleared && !val.startsWith('\n')) {
    val = '\n$val';
    }

    if (cleared) {
    await LocalLyricsManager.deleteLyrics(file.path);
    _rawLyrics = null;
    _lrcLines = null;
    } else {
    await LocalLyricsManager.saveLyrics(file.path, val);
    _rawLyrics = val;
    _lrcLines = _parseLrc(val);
    }
    _tapSyncLines = null;
    _tapSyncTimes.clear();
    _currentLyricIndex = -1;
    _updateCurrentLyricIndex();
    if (mounted) setState(() {});
    Navigator.pop(ctx);
    if (!cleared && mounted) {
    final synced = _lrcLines != null;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(synced
    ? 'Synced lyrics saved'
    : 'Lyrics saved. They have no timestamps, so they can\'t follow the song yet.'),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 6),
    persist: false,
    action: synced ? null : SnackBarAction(label: 'Sync now', onPressed: _startTapSync),
    ));
    }
    },
    child: Text('Save', style: TextStyle(color: AppPalette.accent)),
    ),
    const SizedBox(width: 12),
    ],
    ),
    const SizedBox(height: 12),
    ],
    ),
    ),
    );
    },
    );
  }
  /// -----------------------------------------------------------------------------


  void _showAddToPlaylistSheet(File file) async {
    final playlistNames = await PlaylistService.getPlaylistNames();
    final currentPath = file.path;
    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet(
      context: context,
      backgroundColor: bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          builder: (_, controller) {
            return Column(
              children: [
                const SizedBox(height: 16),
                Text('Add to Playlist', style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                ListTile(
                  leading: Icon(Icons.add, color: AppPalette.accent),
                  title: Text('New Playlist', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showCreatePlaylistDialog(currentPath);
                  },
                ),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    itemCount: playlistNames.length,
                    itemBuilder: (context, index) {
                      final name = playlistNames[index];
                      return FutureBuilder<bool>(
                        future: PlaylistService.isInPlaylist(name, currentPath),
                        builder: (context, snapshot) {
                          final isIn = snapshot.data ?? false;
                          return ListTile(
                            leading: Icon(Icons.playlist_play, color: textColor),
                            title: Text(name, style: TextStyle(color: textColor)),
                            trailing: isIn ? Icon(Icons.check_circle, color: AppPalette.accent) : const Icon(Icons.circle_outlined, color: Colors.grey),
                            onTap: () async {
                              if (isIn) {
                                await PlaylistService.removeFromPlaylist(name, currentPath);
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Removed from $name'), backgroundColor: Colors.red));
                              } else {
                                await PlaylistService.addToPlaylist(name, currentPath);
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Added to $name'), backgroundColor: AppPalette.accent));
                              }
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showCreatePlaylistDialog(String songPath) {
    final controller = TextEditingController();
    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: bg,
        title: Text('New Playlist', style: TextStyle(color: textColor)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: textColor),
          decoration: InputDecoration(
            hintText: 'Playlist Name',
            hintStyle: TextStyle(color: textColor.withOpacity(0.5)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: textColor.withOpacity(0.3))),
            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppPalette.accent)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                await PlaylistService.createPlaylist(name);
                await PlaylistService.addToPlaylist(name, songPath);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Created $name')));
              }
              Navigator.pop(ctx);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  // New: add current track to "queue" (current playlist)
  Future<void> _addCurrentToQueue() async {
    if (_index < 0 || _index >= _effectiveFiles.length) return;
    QueueActions.addToQueueWithFeedback(context, [_effectiveFiles[_index].path]);
  }

  void _showMoreOptions(BuildContext ctx) {
    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet(
      context: ctx,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) {
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(Icons.queue_music, color: textColor),
                  title: Text('Add to Queue', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addCurrentToQueue();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.playlist_add, color: textColor),
                  title: Text('Add to Playlist', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showAddToPlaylistSheet(_effectiveFiles[_index]);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.notifications, color: textColor),
                  title: Text('Set as Ringtone', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    try {
                      final file = _effectiveFiles[_index];
                      final meta = widget.metaCache[file.path];
                      final title = (meta != null && meta['title'] != null) ? meta['title'] : _truncate(_getFileName(file.path));
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => RingtoneScreen(file: file, title: title, isDarkMode: isDark),
                      ));
                    } catch (e) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                    }
                  },
                ),
                ListTile(
                  leading: Icon(Icons.equalizer, color: textColor),
                  title: Text('Equalizer', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onOpenEqualizer();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.timer, color: textColor),
                  title: Text('Sleep Timer', style: TextStyle(color: textColor)),
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onOpenSleepTimer();
                  },
                ),
                ListTile(
                  leading: Icon(Icons.edit_note_rounded, color: textColor),
                  title: Text('Edit tags', style: TextStyle(color: textColor)),
                  subtitle: Text('Title, artist, album, genre, cover', style: TextStyle(color: textColor.withOpacity(0.6))),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_index < 0 || _index >= _effectiveFiles.length) return;
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => TagEditorPage(path: _effectiveFiles[_index].path, isDark: isDark),
                    ));
                  },
                ),
                ListTile(
                  leading: Icon(Icons.graphic_eq, color: textColor),
                  title: Text('Audio Conversion', style: TextStyle(color: textColor)),
                  subtitle: Text('Convert to 4D / 8D audio', style: TextStyle(color: textColor.withOpacity(0.6))),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_index < 0 || _index >= _effectiveFiles.length) return;
                    final file = _effectiveFiles[_index];
                    final meta = widget.metaCache[file.path];
                    final title = (meta != null && meta['title'] != null && (meta['title'] as String).isNotEmpty)
                        ? meta['title'] as String
                        : _truncate(_getFileName(file.path));
                    showAudioConversionSheet(
                      context: context,
                      song: file,
                      title: title,
                      isDark: isDark,
                      onConverted: (record) => widget.onAudioConversionDone?.call(record),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _cleanMetaValue(Object? value) {
    final s = value?.toString().trim() ?? '';
    if (s.isEmpty) return '';
    final lower = s.toLowerCase();
    if (lower == 'unknown' ||
        lower == 'unknown artist' ||
        lower == 'unknown album' ||
        lower == 'unknown genre' ||
        lower == 'various artists') {
      return '';
    }
    return s;
  }

  String _displayArtist(Map<String, dynamic>? meta, String filePath, String title, String album) {
    final candidates = <Object?>[
      meta?['singer'],
      meta?['vocalist'],
      meta?['performer'],
      meta?['albumArtist'],
      meta?['album artist'],
      meta?['artist'],
      meta?['composer'],
    ];

    for (final c in candidates) {
      final value = _cleanMetaValue(c);
      if (value.isNotEmpty) {
        final lower = value.toLowerCase();

        // Reject common non-singer values that often show movie/album/cast info
        if (lower.contains('soundtrack') ||
            lower.contains('motion picture') ||
            lower.contains('ost') ||
            lower.contains('cast') ||
            lower == title.toLowerCase() ||
            lower == album.toLowerCase()) {
          continue;
        }

        return value;
      }
    }

    final pathName = _cleanMetaValue(p.basenameWithoutExtension(filePath));
    if (pathName.isNotEmpty) {
      final parts = pathName.split(' - ');
      if (parts.length >= 2) {
        final first = _cleanMetaValue(parts.first);
        if (first.isNotEmpty) return first;
      }
    }

    return 'Unknown Artist';
  }

  String _displayLanguage(Map<String, dynamic>? meta, String filePath, String title, String album) {
    final candidates = <String>[
      _cleanMetaValue(meta?['language']).toLowerCase(),
      _cleanMetaValue(meta?['lang']).toLowerCase(),
      _cleanMetaValue(meta?['genre']).toLowerCase(),
      _cleanMetaValue(meta?['genere']).toLowerCase(),
    ];

    String normalizeLanguage(String s) {
      if (s.contains('telugu') || s.contains('తెలుగు') || s.contains('tollywood')) {
        return 'Telugu';
      }
      if (s.contains('hindi') || s.contains('हिंदी') || s.contains('bollywood')) {
        return 'Hindi';
      }
      if (s.contains('tamil')) return 'Tamil';
      if (s.contains('malayalam')) return 'Malayalam';
      if (s.contains('kannada')) return 'Kannada';
      if (s.contains('english')) return 'English';
      return '';
    }

    for (final c in candidates) {
      final normalized = normalizeLanguage(c);
      if (normalized.isNotEmpty) return normalized;
    }

    final haystack = [
      filePath,
      title,
      album,
    ].join(' ').toLowerCase();

    if (haystack.contains('telugu') ||
        haystack.contains('తెలుగు') ||
        haystack.contains('tollywood')) {
      return 'Telugu';
    }

    if (haystack.contains('hindi') ||
        haystack.contains('हिंदी') ||
        haystack.contains('bollywood')) {
      return 'Hindi';
    }

    // Optional fallback if your files are mostly these two languages:
    return 'Unknown Language';
  }

  void _showFileInfoSheet(File file) async {
    final meta = widget.metaCache[file.path];
    Uint8List? cover = meta?['cover'] as Uint8List?;

    final title = _cleanMetaValue(meta?['title']).isNotEmpty
        ? _cleanMetaValue(meta?['title'])
        : _truncate(_getFileName(file.path));

    final album = _cleanMetaValue(meta?['album']).isNotEmpty
        ? _cleanMetaValue(meta?['album'])
        : 'Unknown Album';

    final artist = _displayArtist(meta, file.path, title, album);
    final language = _displayLanguage(meta, file.path, title, album);

    int sizeBytes = 0;
    try {
      sizeBytes = await File(file.path).length();
    } catch (_) {}
    final audioInfo = await MediaStoreService.instance.getAudioInfo(file.path);
    if (!mounted) return;

    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subtitleColor = isDark ? Colors.grey[400] : Colors.grey[600];
    final headingColor = isDark ? Colors.grey[500] : Colors.grey[700];

    Widget buildInfoBlock(String heading, String value) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              heading.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                color: headingColor,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.8,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(
                fontSize: 16,
                color: textColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: bg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 80,
                        height: 80,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: buildCoverArt(
                            cover,
                            fit: BoxFit.cover,
                            fallback: Container(
                              decoration: BoxDecoration(
                                gradient: AppPalette.gradient,
                              ),
                              child: const Icon(
                                Icons.music_note,
                                color: Colors.white,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: textColor,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              artist,
                              style: TextStyle(
                                fontSize: 14,
                                color: subtitleColor,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Divider(height: 1),
                  const SizedBox(height: 20),

                  buildInfoBlock('Title', title),
                  buildInfoBlock('Album', album),
                  buildInfoBlock('Artist', artist),
                  buildInfoBlock('File Size', _formatBytes(sizeBytes)),
                  buildInfoBlock('Format', AudioQuality.codecName(audioInfo, file.path) +
                      (AudioQuality.isHiRes(audioInfo) ? '  (Hi-Res)' : (AudioQuality.isLossless(audioInfo, file.path) ? '  (Lossless)' : ''))),
                  if (audioInfo?.bitrate != null) buildInfoBlock('Bitrate', AudioQuality.bitrate(audioInfo!.bitrate!)),
                  if (audioInfo?.sampleRate != null) buildInfoBlock('Sample Rate', AudioQuality.sampleRate(audioInfo!.sampleRate!)),
                  if (audioInfo?.bitsPerSample != null) buildInfoBlock('Bit Depth', '${audioInfo!.bitsPerSample}-bit'),
                  if (audioInfo?.channels != null) buildInfoBlock('Channels', AudioQuality.channels(audioInfo!.channels!)),

                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'FILE PATH',
                        style: TextStyle(
                          fontSize: 12,
                          color: headingColor,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        file.path,
                        style: TextStyle(
                          fontSize: 13,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 24),

                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _openOnlineLyricsDialog(file);
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppPalette.accent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          icon: const Icon(Icons.public, color: Colors.white),
                          label: const Text(
                            'Search Online',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: textColor,
                            side: BorderSide(color: subtitleColor!),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text('Close'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(1)} ${suffixes[i]}';
  }

  Future<void> _removeFromQueueAt(int removeIndex) async {
    if (removeIndex < 0 || removeIndex >= _effectiveFiles.length) return;
    final pathToRemove = _effectiveFiles[removeIndex].path;
    final isDark = widget.isDarkMode;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppPalette.darkCard : Colors.white,
        title: Text("Remove from Queue", style: TextStyle(color: isDark ? Colors.white : Colors.black)),
        content: Text("Remove ${p.basename(pathToRemove)}?", style: TextStyle(color: isDark ? Colors.grey[300] : Colors.black87)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Remove", style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm != true) return;

    final current = List<String>.from(PlaylistContext.getCurrentPlaylist() ?? []);
    if (current.remove(pathToRemove)) {
      // 1. Update UI and Context immediately
      PlaylistContext.setCurrentPlaylist(current, pageId: widget.pageId);

      // 2. Persist to storage immediately to fix "reappearing" issue
      await PlaylistService.saveQueue(current);

      if (widget.pageId != null && widget.pageId!.trim().isNotEmpty) {
        try { await PlaylistService.removeFromPlaylist(widget.pageId!, pathToRemove); } catch (_) {}
      }

      if (removeIndex == _index) {
        if (current.isEmpty) {
          widget.audioPlayer.stop();
          widget.onClose(null);
          if (mounted) Navigator.of(context).pop();
        } else {
          int nextIndex = removeIndex;
          if (nextIndex >= current.length) nextIndex = 0;

          setState(() {
            _index = nextIndex;
          });
          final nextPath = current[nextIndex];
          final globalIdx = widget.audioFiles.indexWhere((f) => f.path == nextPath);
          if (globalIdx != -1) {
            widget.onPlayAtIndex(globalIdx);
          }
          PlaylistContext.setCurrentPath(nextPath);
        }
      } else if (removeIndex < _index) {
        setState(() => _index--);
      }
    }
  }

  // ----- New: Seek forward/backward operations -----
  Future<void> _seekBackward() async {
    try {
      final current = widget.audioPlayer.position;
      final newPos = current - Duration(seconds: _seekSecondsLocal);
      final target = newPos < Duration.zero ? Duration.zero : newPos;
      await widget.audioPlayer.seek(target);
    } catch (e) {
      debugPrint('Seek backward error: $e');
    }
  }

  Future<void> _seekForward() async {
    try {
      final current = widget.audioPlayer.position;
      final max = _duration;
      final newPos = current + Duration(seconds: _seekSecondsLocal);
      final target = newPos > max ? max : newPos;
      await widget.audioPlayer.seek(target);
    } catch (e) {
      debugPrint('Seek forward error: $e');
    }
  }
  // ------------------------------------------------

  // Helper: return appropriate forward icon for seconds (fallbacks used for missing sizes)
  IconData _getForwardIcon(int secs) {
    switch (secs) {
      case 5:
        return Icons.forward_5;
      case 10:
        return Icons.forward_10;
      case 30:
        return Icons.forward_30;
      default:
        return Icons.fast_forward;
    }
  }

  // Helper: return backward icon
  IconData _getBackwardIcon(int secs) {
    switch (secs) {
      case 5:
        return Icons.replay_5;
      case 10:
        return Icons.replay_10;
      case 30:
        return Icons.replay_30;
      default:
        return Icons.replay;
    }
  }

  // Build: action button used in bottom row
  Widget _buildActionButton(IconData icon, String label, VoidCallback onTap, Color color, double size,
      {String? semanticLabel, bool? toggled}) {
    return PressScale(
      onTap: onTap,
      semanticLabel: semanticLabel ?? label,
      semanticToggled: toggled,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min, // Fix: Use min size for column in row
          children: [
            TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: color),
              duration: const Duration(milliseconds: 220),
              builder: (_, c, __) => Icon(icon, color: c, size: 24),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  void _showSpeedDialog() {
    final speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];
    final isDark = widget.isDarkMode;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppPalette.darkCard : Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      isScrollControlled: true,
      builder: (ctx) {
        return SingleChildScrollView(
          child: Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Playback Speed', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              ...speeds.map((s) => ListTile(
                title: Text('${s}x', style: TextStyle(color: isDark ? Colors.white : Colors.black)),
                trailing: _currentSpeed == s ? Icon(Icons.check, color: AppPalette.accent) : null,
                onTap: () {
                  widget.onChangePlaybackSpeed(s);
                  setState(() => _currentSpeed = s);
                  Navigator.pop(ctx);
                },
              )),
              const Divider(),
              StatefulBuilder(builder: (ctx, setSheet) {
                final fg = isDark ? Colors.white : Colors.black;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text('Pitch', style: TextStyle(color: fg, fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(semitoneLabel(_sessionSemitones),
                              style: TextStyle(color: AppPalette.accent, fontWeight: FontWeight.w600)),
                        ),
                        TextButton(
                          onPressed: _sessionSemitones == 0
                              ? null
                              : () {
                                  setSheet(() => _sessionSemitones = 0);
                                  setState(() {});
                                  _applyPitch(0);
                                },
                          child: const Text('Reset'),
                        ),
                      ],
                    ),
                    Semantics(
                      label: 'Pitch in semitones',
                      value: semitoneLabel(_sessionSemitones),
                      child: Slider(
                        min: kMinSemitones.toDouble(),
                        max: kMaxSemitones.toDouble(),
                        divisions: kMaxSemitones - kMinSemitones,
                        value: _sessionSemitones.toDouble(),
                        label: semitoneLabel(_sessionSemitones),
                        activeColor: AppPalette.accent,
                        onChanged: (v) {
                          setSheet(() => _sessionSemitones = v.round());
                          if (mounted) setState(() {});
                        },
                        onChangeEnd: (v) => _applyPitch(v.round()),
                      ),
                    ),
                  ],
                );
              }),
            ],
          ),
        ));
      },
    );
  }

  Widget _buildPlaylistSheet(BuildContext ctx) {
    final isDark = widget.isDarkMode;
    return ValueListenableBuilder<List<String>?>(
      valueListenable: PlaylistContext.currentPlaylistNotifier,
      builder: (context, playlistValue, _) {
        return ValueListenableBuilder<String?>(
          valueListenable: PlaylistContext.currentPathNotifier,
          builder: (context, currentPath, __) {
            final currentPlaylistFiles = _effectiveFiles;
            final hasCustomPlaylist = PlaylistContext.getCurrentPlaylist() != null;

            return Container(
              height: MediaQuery.of(ctx).size.height * 0.7,
              decoration: BoxDecoration(
                color: isDark ? AppPalette.darkCard : Colors.white,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(30)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(width: 40, height: 4, decoration: BoxDecoration(color: isDark ? Colors.grey[600] : Colors.grey[300], borderRadius: BorderRadius.circular(4))),
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text('${hasCustomPlaylist ? 'Queue' : 'All Songs'} (${currentPlaylistFiles.length})', style: TextStyle(color: isDark ? Colors.white : Colors.black, fontSize: 20, fontWeight: FontWeight.w600))),
                        IconButton(
                          icon: const Icon(Icons.layers_rounded),
                          tooltip: 'Queues',
                          color: isDark ? Colors.white : Colors.black,
                          onPressed: () => showQueuesSheet(ctx),
                        ),
                        IconButton(
                          icon: const Icon(Icons.playlist_add_rounded),
                          tooltip: 'Save queue as playlist',
                          color: isDark ? Colors.white : Colors.black,
                          onPressed: () => showSaveQueueAsPlaylistDialog(ctx, currentPlaylistFiles.map((f) => f.path).toList()),
                        ),
                        IconButton(icon: const Icon(Icons.close), tooltip: context.l10n.close, color: isDark ? Colors.white : Colors.black, onPressed: () => Navigator.pop(ctx)),
                      ],
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: currentPlaylistFiles.length,
                      itemBuilder: (c, i) {
                        final f = currentPlaylistFiles[i];
                        final sel = f.path == (currentPath ?? (_effectiveFiles.isNotEmpty ? _effectiveFiles[_index].path : null));
                        final title = _truncate(_getFileName(f.path));

                        return Material(
                          color: Colors.transparent,
                          child: ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(Icons.music_note, color: sel ? AppPalette.accent : (isDark ? Colors.white54 : Colors.black54)),
                            title: Text(title, style: TextStyle(color: sel ? AppPalette.accent : (isDark ? Colors.white : Colors.black), fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              tooltip: context.l10n.removeFromQueue,
                              color: isDark ? Colors.white54 : Colors.black54,
                              onPressed: () => _removeFromQueueAt(i),
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              _playIndex(i);
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // Helper to replace normal spaces with NBSP so Text preserves repeated spaces & leading spaces
  String _preserveSpaces(String s) {
    // Replace normal space with non-breaking space so leading spaces and multiple spaces are visible.
    // NB: avoid changing newline characters.
    return s.replaceAll(' ', '\u00A0');
  }

  Widget _buildLyricsView() {
    return LayoutBuilder(builder: (context, constraints) {
      final isDark = widget.isDarkMode;
      // extra bottom padding so last lines aren't hidden by system UI / bottom navs
      final double bottomSafe = MediaQuery.of(context).viewPadding.bottom + 32.0;
      final topSafe = MediaQuery.of(context).viewPadding.top + 12.0;

      if (_tapSyncLines != null) return _buildTapSyncView(isDark);

      // treat empty/whitespace raw lyrics as "no lyrics"
      final bool hasRaw = _rawLyrics != null && _rawLyrics!.trim().isNotEmpty;
      final bool hasLrc = _lrcLines != null && _lrcLines!.isNotEmpty;

      // If no lyrics at all -> show text-like button that opens options popup
      if (!hasRaw && !hasLrc) {
        return Center(
          child: InkWell(
            onTap: () => _showNoLyricsOptionsSheet(_effectiveFiles[_index]),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search, size: 18, color: isDark ? Colors.white54 : Colors.black54),
                      const SizedBox(width: 6),
                      Text('Search lyrics',
                          style: TextStyle(color: isDark ? Colors.white54 : Colors.black54, fontSize: 16)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('No lyrics found \u2014 tap to search online or add your own',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 12)),
                ],
              ),
            ),
          ),
        );
      }

      // Synchronized LRC lines available — return a scrollable list with bottom & top padding
      if (hasLrc) {
        return SafeArea(
          child: NotificationListener<UserScrollNotification>(
            onNotification: (_) {
              _lastLyricsUserScroll = DateTime.now();
              return false;
            },
            child: SingleChildScrollView(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 24,
              bottom: bottomSafe,
            ),
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              children: [
                // Center column to mimic the screenshot: wide centered block with centered lines
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.92),
                  child: Column(
                    children: List.generate(_lrcLines!.length, (i) {
                      final isCurrent = i == _currentLyricIndex;
                      final rawText = _lrcLines![i].text;
                      // Plain text (not _preserveSpaces): non-breaking spaces would force mid-word wraps.
                      final display = rawText.trim();
                      // For empty lines, add vertical gap
                      if (display.trim().isEmpty) {
                        return SizedBox(height: isCurrent ? 14 : 10);
                      }
                      final isPast = i < _currentLyricIndex;
                      // Tap a line to jump there.
                      return GestureDetector(
                        key: i < _lyricKeys.length ? _lyricKeys[i] : null,
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _lastLyricsUserScroll = DateTime.fromMillisecondsSinceEpoch(0);
                          widget.audioPlayer.seek(_lrcLines![i].time);
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 250),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: isCurrent ? 19 : 15,
                              color: isCurrent
                                  ? AppPalette.accent
                                  : (isDark ? Colors.white.withOpacity(isPast ? 0.45 : 0.7) : Colors.black.withOpacity(isPast ? 0.4 : 0.75)),
                              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                              height: 1.35,
                            ),
                            child: Text(display, textAlign: TextAlign.center),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                SizedBox(height: bottomSafe),
              ],
            ),
          ),
          ),
        );
      }

      // Unsynced lyrics (plain text) — render line-by-line preserving spaces and blank lines,
      // and render in a large centered card-like block so it feels full-screen.
      final raw = _rawLyrics ?? '';
      final lines = raw.split('\n');

      return SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(12, topSafe, 12, bottomSafe),
          physics: const BouncingScrollPhysics(),
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                // make the lyrics block wide (like the screenshot) up to 96% of width
                maxWidth: constraints.maxWidth * 0.96,
                minWidth: constraints.maxWidth * 0.96,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: _fetchingLyrics
                        ? const Padding(padding: EdgeInsets.all(8), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                        : Wrap(
                            alignment: WrapAlignment.center,
                            children: [
                              TextButton.icon(
                                onPressed: () => _findLyricsOnline(_effectiveFiles[_index]),
                                icon: Icon(Icons.sync_rounded, size: 18, color: AppPalette.accent),
                                label: Text('Find synced version', style: TextStyle(color: AppPalette.accent)),
                              ),
                              TextButton.icon(
                                onPressed: _startTapSync,
                                icon: Icon(Icons.touch_app_rounded, size: 18, color: AppPalette.accent),
                                label: Text('Sync manually', style: TextStyle(color: AppPalette.accent)),
                              ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 4),
                  // Render each line preserving spaces and blank lines, centered as in screenshot
                  ...List<Widget>.generate(lines.length, (i) {
                    final line = lines[i];
                    if (line.isEmpty) {
                      // keep a visible blank line height
                      return const SizedBox(height: 12);
                    }
                    final preserved = _preserveSpaces(line);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: SelectableText(
                        preserved,
                        textAlign: TextAlign.center, // center aligns like screenshot
                        style: TextStyle(
                          color: isDark ? Colors.white : Colors.black87,
                          height: 1.45,
                          fontSize: 14, // slightly reduced but readable
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }


  /// Bottom sheet shown when "Search lyrics" is tapped and no lyrics present.
  /// Shows editable song title and two actions: Search Online & Add / Paste Lyrics.
  void _showNoLyricsOptionsSheet(File file) {
    final meta = widget.metaCache[file.path];
    final initialTitle = (meta != null && meta['title'] != null) ? meta['title'] as String : p.basenameWithoutExtension(file.path);
    final TextEditingController titleController = TextEditingController(text: initialTitle);
    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkCard : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black87;

    showModalBottomSheet(
      context: context,
      backgroundColor: bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: isDark ? Colors.grey[600] : Colors.grey[300], borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 12),
              Text('Lyrics', style: TextStyle(color: textColor, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              TextField(
                controller: titleController,
                style: TextStyle(color: textColor),
                decoration: InputDecoration(
                  labelText: 'Song Title',
                  labelStyle: TextStyle(color: textColor.withOpacity(0.8)),
                  enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: textColor.withOpacity(0.2))),
                  focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: AppPalette.accent)),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _findLyricsOnline(file, titleOverride: titleController.text);
                  },
                  icon: const Icon(Icons.lyrics_rounded, color: Colors.white),
                  label: const Text('Find synced lyrics', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(backgroundColor: AppPalette.accent, padding: const EdgeInsets.symmetric(vertical: 12)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 4),
                child: Text('Searches LRCLIB, a free community lyrics database. Saved for offline use.',
                    textAlign: TextAlign.center, style: TextStyle(color: textColor.withOpacity(0.6), fontSize: 11)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        // Open OnlineLyricsPopup with the edited title
                        showDialog(
                          context: context,
                          barrierDismissible: true,
                          builder: (_) => OnlineLyricsPopup(
                            songTitle: titleController.text.trim(),
                            artistName: (meta?['artist'] ?? '') as String,
                            isDarkMode: widget.isDarkMode,
                          ),
                        );
                      },
                      icon: const Icon(Icons.public, color: Colors.white),
                      label: const Text('Web search', style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(backgroundColor: AppPalette.accent),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(ctx);
                        // Open Add/Paste lyrics dialog (reuses existing function)
                        _showAddLocalLyricsDialog(file);
                      },
                      icon: const Icon(Icons.note_add, color: Colors.white),
                      label: const Text('Add Lyrics', style: TextStyle(color: Colors.white)),
                      style: ElevatedButton.styleFrom(backgroundColor: AppPalette.accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: textColor)),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _notifyBackgroundIfNeeded() async {}

  ///
  /// NEW: Open current queue page (navigation)
  ///
  Future<void> _openQueuePage() async {
    try {
      final savedQueue = await PlaylistService.getQueue();

      if (savedQueue.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Queue is empty')),
          );
        }
        return;
      }

      // set the current playlist context so highlighting works
      PlaylistContext.setCurrentPlaylist(
        savedQueue,
        pageId: CurrentQueuePage.kQueuePageId,
      );

      if (!mounted) return;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => CurrentQueuePage(
            queue: savedQueue.map((p) => File(p)).toList(),
            metaCache: widget.metaCache,
            onPlay: (File file, int index) async {
              // Map the queue index back to the global audioFiles index.
              final path = file.path;
              final globalIdx = widget.audioFiles.indexWhere((f) => f.path == path);
              if (globalIdx != -1) {
                // Play via the provided onPlayAtIndex so the whole app playback flow is used.
                widget.onPlayAtIndex(globalIdx);
                // Also update the playlist context/path immediately for responsive UI.
                PlaylistContext.setCurrentPath(path);
              } else {
                // If for some reason the track isn't in the main list, fall back to setting the playlist
                // (PlaybackController is part of your app; keep this call if you have it available).
                try {
                  await PlaybackController.instance.setPlaylist(
                    savedQueue,
                    startIndex: index >= 0 ? index : 0,
                    play: true,
                    pageId: CurrentQueuePage.kQueuePageId,
                  );
                  PlaylistContext.setCurrentPath(savedQueue[index]);
                } catch (e) {
                  debugPrint('Fallback setPlaylist error: $e');
                }
              }
            },
            onPause: (File f) async {
              try {
                await widget.audioPlayer.pause();
              } catch (_) {}
            },
            onToggleFavorite: (File f) async {
              try {
                widget.onToggleFavorite(f.path);
              } catch (_) {}
            },
            loadCoverForFile: (File file) async {
              try {
                final m = await widget.loadFullMetadata(file);
                if (m is Map && m['cover'] is Uint8List) return m['cover'] as Uint8List;
              } catch (_) {}
              return null;
            },
          ),
        ),
      );
    } catch (e) {
      debugPrint('Open queue page error: $e');
    }
  }

  ///
  /// Helper to open the OnlineLyricsPopup for the given file
  ///
  void _openOnlineLyricsDialog(File file) {
    final meta = widget.metaCache[file.path];
    final title = meta?['title'] ?? p.basenameWithoutExtension(file.path);
    final artist = meta?['artist'] ?? '';

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => OnlineLyricsPopup(
        songTitle: title,
        artistName: artist,
        isDarkMode: widget.isDarkMode,
      ),
    );
  }

  bool? _overlayStyleIsDark;

  /// Status-bar style for this screen. build() runs on every position tick
  /// (several times a second); pushing the overlay style to the platform
  /// each time made the status bar flash, so only send it when it changes.
  void _applyOverlayStyle(bool isDark) {
    if (_overlayStyleIsDark == isDark) return;
    _overlayStyleIsDark = isDark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));
  }

  // Add the landscape layout builder wrapper
  @override
  Widget build(BuildContext context) {
    if (_effectiveFiles.isEmpty) {
      return Scaffold(
        appBar: AppBar(elevation: 0, backgroundColor: Colors.transparent),
        body: const Center(child: Text("No track selected")),
      );
    }

    if (_index < 0) _index = 0;
    if (_index >= _effectiveFiles.length) _index = _effectiveFiles.length - 1;

    final file = _effectiveFiles[_index];
    final meta = widget.metaCache[file.path];
    final cover = meta?['cover'] as Uint8List?;
    final rawTitle = (meta?['title'] as String?)?.trim();
    final title = TrackText.title(
        (rawTitle != null && rawTitle.isNotEmpty) ? rawTitle : p.basenameWithoutExtension(file.path));
    final artist = TrackText.artist(meta?['artist']?.toString()) ?? 'Unknown Artist';
    _maybeUpdateAccentColor(cover);
    final targetBase = _accentColor ?? _defaultAccent;

    // Which way the art should slide in when the track changes.
    if (_lastBuiltIndex != -1 && _index != _lastBuiltIndex) {
      _artDirection = _index > _lastBuiltIndex ? 1 : -1;
    }
    _lastBuiltIndex = _index;

    final isDark = widget.isDarkMode;
    final baseBackground = isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
    final textColor = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final subtitleColor = isDark ? Colors.white70 : const Color(0xFF5E5B73);
    final iconColor = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    _applyOverlayStyle(isDark);

    // One animated base colour feeds the gradient and every accent, so they
    // all glide between tracks together and can never disagree.
    return DragToDismiss(
      enabled: MediaQuery.orientationOf(context) == Orientation.portrait,
      onDismiss: _closePlayer,
      child: TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: targetBase),
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 700),
      curve: Curves.easeInOut,
      builder: (context, animBase, _) {
    final base = animBase ?? targetBase;
    final accent = ArtColors.accent(base, dark: isDark, fallback: AppPalette.accent);
    final gradientTop = ArtColors.gradientTop(base, dark: isDark);

    final bool repeatActive = _playMode != PlayMode.off;
    final IconData modeIcon = _playMode == PlayMode.repeatOne ? Icons.repeat_one : Icons.repeat;

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: baseBackground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildNowPlayingBackground(gradientTop, baseBackground),
          SafeArea(
        child: LayoutBuilder(
            builder: (context, constraints) {
              final isLandscape = constraints.maxWidth > constraints.maxHeight;

              // Header Row (Back, Title, Lyrics, Info)
              Widget headerRow = Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    IconButton(icon: Icon(Icons.keyboard_arrow_down, color: iconColor), tooltip: context.l10n.back, onPressed: _closePlayer),
                    const Spacer(),
                    Semantics(header: true, child: Text(context.l10n.nowPlayingTitle, style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w600))),
                    const Spacer(),
                    ValueListenableBuilder<String?>(
                      valueListenable: CastService.instance.connectedDevice,
                      builder: (context, device, _) => IconButton(
                        icon: Icon(device == null ? Icons.cast_rounded : Icons.cast_connected_rounded),
                        color: device == null ? iconColor : accent,
                        tooltip: device == null ? context.l10n.cast : context.l10n.castingTo(device),
                        onPressed: () => showCastSheet(context, titleFor: (path) {
                          final t = widget.metaCache[path]?['title'] as String?;
                          return (t != null && t.isNotEmpty) ? t : p.basenameWithoutExtension(path);
                        }),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_note),
                      color: iconColor,
                      tooltip: context.l10n.lyricsEditLocal,
                      onPressed: () => _showAddLocalLyricsDialog(file),
                    ),
                    IconButton(
                      icon: const Icon(Icons.public),
                      color: iconColor,
                      tooltip: context.l10n.lyricsOnline,
                      onPressed: () => _openOnlineLyricsDialog(file),
                    ),
                    IconButton(icon: Icon(Icons.info_outline, color: iconColor), tooltip: context.l10n.songInfo, onPressed: () => _showFileInfoSheet(file)),
                  ],
                ),
              );

              // Album art page: rounded square (BoxFit.cover, no letterbox
              // bars) with an art-tinted shadow. Inset by artInset so the
              // shadow (blur 40) fits inside the full-width PageView; the
              // lyrics card uses the same inset so both pages line up.
              const double artInset = 40;
              final artPage = LayoutBuilder(builder: (context, box) {
                final side = (box.maxWidth < box.maxHeight ? box.maxWidth : box.maxHeight) - artInset * 2;
                return Center(
                  child: SizedBox(
                    width: side > 0 ? side : 0,
                    height: side > 0 ? side : 0,
                    child: NowPlayingArt(
                      trackKey: file.path,
                      direction: _artDirection,
                      playing: _isPlaying,
                      shadowColor: accent,
                      heroTag: 'now_playing_art_${file.path}',
                      onSwipeNext: _canGoNext() ? _playNext : null,
                      onSwipePrevious: _canGoPrevious() ? _playPrevious : null,
                      child: RepaintBoundary(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            buildCoverArt(
                              cover,
                              fit: BoxFit.cover,
                              fallback: Container(color: isDark ? Colors.grey[800] : Colors.grey[300], child: Icon(Icons.music_note, size: 80, color: subtitleColor)),
                            ),
                            if (_showVisualizer)
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: Container(
                                  height: 96,
                                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Color(0xB0000000)],
                                    ),
                                  ),
                                  // Simulated bars (no FFT available) — see visualizer.dart.
                                  child: SimulatedVisualizer(
                                    playing: _isPlaying,
                                    color: accent,
                                    seed: file.path.hashCode,
                                    position: _posNotifier,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              });

              // Album art PageView (art page / lyrics page). While on the art
              // page horizontal swipes skip tracks, so the page switch is the
              // dots below (and swiping back from the lyrics page).
              Widget albumArtView = PageView(
                controller: _pageController,
                clipBehavior: Clip.none,
                physics: _currentPage == 0 ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
                onPageChanged: (p) {
                  setState(() => _currentPage = p);
                  if (p == 1) {
                    _lastLyricsUserScroll = DateTime.fromMillisecondsSinceEpoch(0);
                    _scrollLyricIntoView();
                  }
                },
                children: [
                  artPage,
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: isLandscape ? 0 : artInset, vertical: 4),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: Container(
                        color: isDark ? AppPalette.darkCard.withOpacity(0.85) : Colors.white.withOpacity(0.9),
                        child: _buildLyricsView(),
                      ),
                    ),
                  ),
                ],
              );

              // Title & Artist Column (cross-fades per track; long titles scroll)
              Widget titleAndArtist = _pageSwipeZone(SizedBox(
                width: double.infinity,
                child: AnimatedSwitcher(
                  duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 300),
                  layoutBuilder: (current, previous) => Stack(
                    alignment: isLandscape ? Alignment.topLeft : Alignment.topCenter,
                    children: [...previous, if (current != null) current],
                  ),
                  child: Column(
                    key: ValueKey(file.path),
                    crossAxisAlignment: isLandscape ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                    children: [
                      MarqueeText(
                        title,
                        textAlign: isLandscape ? TextAlign.start : TextAlign.center,
                        style: TextStyle(fontSize: isLandscape ? 20 : 22, fontWeight: FontWeight.bold, color: textColor),
                      ),
                      const SizedBox(height: 2),
                      Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: subtitleColor)),
                      AudioQualityBadge(path: file.path, color: accent, onTap: () => _showFileInfoSheet(file)),
                    ],
                  ),
                ),
              ));

              // Seek Bar Row (listens to the position itself; see seek_bar.dart)
              Widget seekBar = NowPlayingSeekBar(
                position: _posNotifier,
                duration: _duration,
                accent: accent,
                inactive: textColor.withOpacity(0.16),
                labelColor: subtitleColor,
                loopStart: _ab.a,
                loopEnd: _ab.b,
                onSeek: (d) {
                  _abLastSeek = DateTime.now();
                  widget.audioPlayer.seek(d);
                  _notifyBackgroundIfNeeded();
                },
              );

              // Playback Controls Row
              Widget playbackControls = Row(
                mainAxisAlignment: isLandscape ? MainAxisAlignment.spaceEvenly : MainAxisAlignment.spaceBetween,
                children: [
                  AnimatedModeButton(
                    icon: modeIcon,
                    active: repeatActive,
                    accent: accent,
                    inactiveColor: subtitleColor,
                    tooltip: switch (_playMode) {
                      PlayMode.off => context.l10n.repeatOff,
                      PlayMode.repeatOne => context.l10n.repeatOne,
                    },
                    onPressed: _cyclePlayMode,
                  ),
                  TransportButton(
                    icon: Icons.skip_previous,
                    label: context.l10n.previous,
                    color: _canGoPrevious() ? iconColor : subtitleColor.withOpacity(0.5),
                    onPressed: _canGoPrevious() ? _playPrevious : null,
                  ),
                  if (_seekButtonsEnabledLocal)
                    Column(
                      children: [
                        IconButton(
                          icon: Icon(_getBackwardIcon(_seekSecondsLocal), size: 26),
                          color: subtitleColor,
                          tooltip: context.l10n.seekBackBy(_seekSecondsLocal),
                          onPressed: _seekBackward,
                        ),
                        Text('${_seekSecondsLocal}s', style: TextStyle(color: subtitleColor, fontSize: 10)),
                      ],
                    )
                  else if (!isLandscape)
                    const SizedBox(width: 40),
                  PlayPauseButton(
                    playing: _isPlaying,
                    accent: accent,
                    diameter: isLandscape ? 60 : 70,
                    onPressed: () => _isPlaying ? widget.audioPlayer.pause() : widget.audioPlayer.play(),
                  ),
                  if (_seekButtonsEnabledLocal)
                    Column(
                      children: [
                        IconButton(
                          icon: Icon(_getForwardIcon(_seekSecondsLocal), size: 26),
                          color: subtitleColor,
                          tooltip: context.l10n.seekForwardBy(_seekSecondsLocal),
                          onPressed: _seekForward,
                        ),
                        Text('${_seekSecondsLocal}s', style: TextStyle(color: subtitleColor, fontSize: 10)),
                      ],
                    )
                  else if (!isLandscape)
                    const SizedBox(width: 40),
                  TransportButton(
                    icon: Icons.skip_next,
                    label: context.l10n.next,
                    color: _canGoNext() ? iconColor : subtitleColor.withOpacity(0.5),
                    onPressed: _canGoNext() ? _playNext : null,
                  ),
                  // Shares one flag with the Songs page shuffle button, so
                  // both always agree; _playNext honours it via
                  // _shuffleNextIndex().
                  ValueListenableBuilder<bool>(
                    valueListenable: PlaylistContext.shuffleEnabledNotifier,
                    builder: (context, shuffleOn, _) => AnimatedModeButton(
                      icon: Icons.shuffle,
                      active: shuffleOn,
                      accent: accent,
                      inactiveColor: subtitleColor,
                      tooltip: shuffleOn ? context.l10n.tipShuffleOn : context.l10n.tipShuffleOff,
                      onPressed: () async {
                        final newVal = !shuffleOn;
                        PlaylistContext.setShuffleEnabled(newVal);
                        try {
                          await widget.audioPlayer.setShuffleModeEnabled(newVal);
                        } catch (e) {
                          debugPrint('setShuffleModeEnabled error: $e');
                        }
                      },
                    ),
                  ),
                ],
              );

              // Bottom Actions Row
              Widget bottomActions = FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _buildActionButton(Icons.share, context.l10n.share, () => widget.onShare(file.path), subtitleColor, 40),
                    const SizedBox(width: 20),
                    _buildActionButton(Icons.playlist_play, context.l10n.queue, _openQueuePage, subtitleColor, 40),
                    const SizedBox(width: 20),
                    _buildActionButton(Icons.speed, '${_currentSpeed}x', _showSpeedDialog, subtitleColor, 40,
                        semanticLabel: context.l10n.speedSemantics('$_currentSpeed')),
                    if (_sessionSemitones != 0)
                      Semantics(
                        label: 'Pitch ${semitoneLabel(_sessionSemitones)}',
                        child: Container(
                          margin: const EdgeInsets.only(left: 4),
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withOpacity(0.18),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(semitoneLabel(_sessionSemitones),
                              style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.w600)),
                        ),
                      ),
                    const SizedBox(width: 20),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      child: _buildActionButton(
                          Icons.sync_alt,
                          _ab.phase == AbLoopPhase.aSet ? context.l10n.abSet : context.l10n.abLoop,
                          _onAbTap,
                          _ab.isIdle ? subtitleColor : accent,
                          40,
                          semanticLabel: context.l10n.abLoopLabel,
                          toggled: !_ab.isIdle),
                    ),
                    const SizedBox(width: 20),
                    _buildActionButton(Icons.graphic_eq, context.l10n.visualizer, () {
                      setState(() => _showVisualizer = !_showVisualizer);
                      _saveVisualizerPref(_showVisualizer);
                      if (_showVisualizer && _currentPage != 0 && _pageController.hasClients) {
                        _pageController.animateToPage(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
                      }
                    }, _showVisualizer ? accent : subtitleColor, 40, toggled: _showVisualizer),
                    const SizedBox(width: 20),
                    _buildActionButton(Icons.more_horiz, context.l10n.more, () => _showMoreOptions(context), subtitleColor, 40),
                  ],
                ),
              );


              if (isLandscape) {
                return Column(
                  children: [
                    headerRow,
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start, // Align to top so it scrolls naturally
                        children: [
                          // Left side: Album Art
                          Expanded(
                            flex: 5,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(24, 0, 16, 16), // Slightly reduced bottom padding
                              child: Column(
                                children: [
                                  Expanded(child: albumArtView),
                                  const SizedBox(height: 8),
                                  _buildPageDots(accent, subtitleColor),
                                ],
                              ),
                            ),
                          ),
                          // Right side: Details & Controls (Now Scrollable)
                          Expanded(
                            flex: 6,
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.fromLTRB(16, 0, 24, 16), // Reduced bottom padding
                              physics: const BouncingScrollPhysics(), // Adds smooth scrolling effect
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  titleAndArtist,
                                  const SizedBox(height: 12), // Decreased spacing for smaller screens
                                  seekBar,
                                  const SizedBox(height: 8), // Decreased spacing for smaller screens
                                  playbackControls,
                                  const SizedBox(height: 16), // Replaced Spacer() with fixed height to prevent scroll errors
                                  Center(child: bottomActions),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              } else {
                // Portrait mode
                final screenHeight = MediaQuery.of(context).size.height;
                final imagePadding = screenHeight < 700 ? 12.0 : 40.0;

                return Column(
                  children: [
                    headerRow,
                    Expanded(
                      flex: 5,
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: imagePadding / 4),
                        child: albumArtView,
                      ),
                    ),
                    _buildPageDots(accent, subtitleColor),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30),
                      child: titleAndArtist,
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: seekBar,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: playbackControls,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 20),
                      child: bottomActions,
                    ),
                  ],
                );
              }
            }
        ),
      ),
        ],
      ),
    );
      },
    ),
    );
  }

  /// Screen backdrop: a vertical gradient from the art-derived (lightness
  /// clamped) top colour into the normal background. Replaces the old blurred
  /// cover scrim — cheaper to paint and animates smoothly between tracks.
  Widget _buildNowPlayingBackground(Color top, Color bottom) {
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [top, Color.lerp(top, bottom, 0.65)!, bottom],
            stops: const [0.0, 0.45, 1.0],
          ),
        ),
      ),
    );
  }

  void _goToPage(int page) {
    if (_pageController.hasClients && _currentPage != page) {
      _pageController.animateToPage(page, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);
    }
  }

  /// Horizontal swipes on [child] page between art and lyrics (the art itself
  /// keeps swipe = skip track).
  Widget _pageSwipeZone(Widget child) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -150) {
          _goToPage(1);
        } else if (v > 150) {
          _goToPage(0);
        }
      },
      child: child,
    );
  }

  /// Art / lyrics page indicator in the shared accent; tap a dot (or the
  /// Lyrics / Cover pill) to switch, or swipe across the row.
  Widget _buildPageDots(Color accent, Color inactive) {
    Widget dot(int page) {
      final active = _currentPage == page;
      // Decorative: the Lyrics / Cover pill is the accessible switch.
      return ExcludeSemantics(child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _goToPage(page),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
            width: active ? 18 : 8,
            height: 8,
            decoration: BoxDecoration(
              color: active ? accent : inactive.withOpacity(0.45),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ));
    }

    final onLyrics = _currentPage == 1;
    final pill = Semantics(
      button: true,
      excludeSemantics: true,
      label: onLyrics ? context.l10n.cover : context.l10n.lyrics,
      onTap: () => _goToPage(onLyrics ? 0 : 1),
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _goToPage(onLyrics ? 0 : 1),
      // 12dp of invisible padding brings the pill to a 48dp touch target.
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: accent.withOpacity(0.14),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: accent.withOpacity(0.5)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(onLyrics ? Icons.album_rounded : Icons.lyrics_rounded, size: 15, color: accent),
          const SizedBox(width: 5),
          Text(onLyrics ? context.l10n.cover : context.l10n.lyrics, style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      )),
    ));

    return _pageSwipeZone(SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [dot(0), dot(1)]),
          Positioned(right: 24, child: pill),
        ],
      ),
    ));
  }
}

class CurrentQueuePage extends StatefulWidget {
  final List<File> queue;
  final FutureOr<void> Function(File file, int index) onPlay;
  final FutureOr<void> Function(File) onPause;
  final FutureOr<void> Function(File) onToggleFavorite;
  final Future<Uint8List?> Function(File file) loadCoverForFile;

  /// Optional title/artist metadata (path -> tags) for readable rows.
  final Map<String, dynamic>? metaCache;
  static const String kQueuePageId = 'current_queue';

  const CurrentQueuePage({
    super.key,
    this.metaCache,
    required this.queue,
    required this.onPlay,
    required this.onPause,
    required this.onToggleFavorite,
    required this.loadCoverForFile,
  });

  @override
  State<CurrentQueuePage> createState() => _CurrentQueuePageState();
}

///
/// 🔥 Each queue entry MUST be unique even if file path is same
///
class _QueueItem {
  final String id;
  final File file;

  _QueueItem(this.file) : id = UniqueKey().toString();
}

class _CurrentQueuePageState extends State<CurrentQueuePage> {
  late List<_QueueItem> _currentList;
  final ScrollController _scroll = ScrollController();
  // Thumbnails are loaded lazily per path and kept for the page's lifetime.
  final Map<String, Future<Uint8List?>> _covers = {};
  static const double _rowExtent = 72;

  @override
  void initState() {
    super.initState();

    // Bring the playing track into view on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final cur = PlaylistContext.currentPathNotifier.value;
      final i = _currentList.indexWhere((e) => e.file.path == cur);
      if (i < 0 || !_scroll.hasClients) return;
      final target = (i * _rowExtent - 120).clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
    });

    /// convert files → unique queue items
    _currentList = widget.queue.map((f) => _QueueItem(f)).toList();

    PlaylistContext.currentPlaylistNotifier.addListener(_onExternalQueueChange);
    PlaylistContext.currentPathNotifier.addListener(_onPlaybackChange);
  }

  @override
  void dispose() {
    PlaylistContext.currentPlaylistNotifier.removeListener(_onExternalQueueChange);
    PlaylistContext.currentPathNotifier.removeListener(_onPlaybackChange);
    _scroll.dispose();
    super.dispose();
  }

  void _onPlaybackChange() {
    if (mounted) setState(() {});
  }

  /// Sync when playlist updated externally
  void _onExternalQueueChange() {
    final updatedPaths = PlaylistContext.getCurrentPlaylist();

    if (updatedPaths != null && mounted) {
      setState(() {
        _currentList = updatedPaths
            .map((p) => _QueueItem(File(p)))
            .toList(); // 🔥 recreate unique items
      });
    }
  }

  /// Save order back to PlaylistContext
  void _syncToContext() {
    final paths = _currentList.map((e) => e.file.path).toList();

    PlaylistContext.setCurrentPlaylist(
      paths,
      pageId: CurrentQueuePage.kQueuePageId,
    );

    // persist queue
    PlaylistService.saveQueue(paths);
  }

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.of(context).platformBrightness == Brightness.dark || Theme.of(context).brightness == Brightness.dark;

    final currentPath = PlaylistContext.currentPathNotifier.value;
    final isPlayingGlobal = PlaybackState.isPlaying.value;

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
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
            icon: const Icon(Icons.clear_all_rounded),
            tooltip: 'Clear queue (keep playing)',
            onPressed: _currentList.length <= 1 ? null : () => QueueActions.showFeedback(context, QueueActions.clearKeepPlaying()),
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
        scrollController: _scroll,
        itemExtent: _rowExtent,
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
          final meta = widget.metaCache?[file.path];
          final rawTitle = meta is Map ? meta['title'] as String? : null;
          final rawArtist = meta is Map ? meta['artist'] as String? : null;
          final accent = AppPalette.accent;

          return Dismissible(
            key: ValueKey(item.id), // 🔥 UNIQUE KEY FIX

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
                  ? accent.withOpacity(dark ? 0.18 : 0.10)
                  : Colors.transparent,
              child: ListTile(
                leading: SizedBox(
                  width: 48,
                  height: 48,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FutureBuilder<Uint8List?>(
                          future: _covers.putIfAbsent(file.path, () => widget.loadCoverForFile(file)),
                          builder: (context, snap) => buildCoverArt(
                            snap.data,
                            fallback: Container(
                              color: dark ? Colors.grey[800] : Colors.grey[300],
                              child: Icon(Icons.music_note, color: dark ? Colors.white38 : Colors.black38),
                            ),
                          ),
                        ),
                        if (isCurrent)
                          Container(
                            color: Colors.black45,
                            child: Icon(isRowPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                          ),
                      ],
                    ),
                  ),
                ),
                title: Text(
                  TitleCleaner.title(rawTitle ?? p.basenameWithoutExtension(file.path), path: file.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent ? accent : null,
                    fontWeight:
                    isCurrent ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  TitleCleaner.artistOrUnknown(rawArtist),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: context.l10n.removeFromQueue,
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
