// lib/settings_page.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'audio_cutter.dart';
import 'audio_cutter_service.dart';
import 'url_download_screen.dart';
import 'equalizer_screen.dart';
import 'theme_provider.dart'; // ensure this matches your project path
import 'radio_service.dart';
import 'radio_page.dart';
import 'backup_service.dart';
import 'app_palette.dart';
import 'appearance_page.dart';
import 'library_filters_page.dart';
import 'library_service.dart';
import 'duo_service.dart';
import 'audio_effects_service.dart';
import 'sound_effects_page.dart';
import 'position_memory_service.dart';
import 'lastfm_service.dart';
import 'lastfm_page.dart';
import 'ad_widgets.dart';

/// Fallback SharedPreferences keys
const String _prefKeyDark = 'settings_dark_mode';
const String _prefKeyFollowSystem = 'settings_follow_system';

/// Seek prefs keys
const String _prefSeekButtonsEnabled = 'settings_seek_buttons_enabled';
const String _prefSeekSeconds = 'settings_seek_seconds';

/// Theme-aware color scheme for Settings
class SettingsColors {
  final bool isDarkMode;
  SettingsColors(this.isDarkMode);
  Color get backgroundColor => isDarkMode ? AppPalette.darkBackground : Colors.white;
  Color get surfaceColor => isDarkMode ? AppPalette.darkCard : const Color(0xFFF8F9FA);
  Color get cardColor => isDarkMode ? (AppPalette.amoled ? AppPalette.darkCard : const Color(0xFF1B1B1B)) : Colors.white;
  Color get primaryText => isDarkMode ? Colors.white : Colors.black;
  Color get secondaryText => isDarkMode ? const Color(0xFFB0B0B0) : const Color(0xFF666666);
  Color get tertiaryText => isDarkMode ? const Color(0xFF999999) : const Color(0xFF999999);
  Color get primary => AppPalette.accent;
  Color get divider => isDarkMode ? const Color(0xFF2C2C2C) : const Color(0xFFE6E6E6);
  Color get appBarBackground => isDarkMode ? AppPalette.darkBackground : Colors.white;
  Color get appBarForeground => isDarkMode ? Colors.white : Colors.black;
}

/// SettingsPage
class SettingsPage extends StatefulWidget {
  final AudioPlayer? audioPlayer;
  final void Function(bool isDarkMode)? onThemeChange;
  final Future<bool> Function(RadioStation station)? onPlayRadioStation;

  /// Already-scanned library songs, reused by the Audio Cutter entry point's
  /// song picker instead of re-scanning storage from Settings.
  final List<File> audioFiles;
  final String Function(File file)? resolveSongTitle;
  final Duration? Function(File file)? resolveSongDuration;
  final void Function(CutRecord record)? onCutSaved;

  const SettingsPage({
    Key? key,
    this.audioPlayer,
    this.onThemeChange,
    this.onPlayRadioStation,
    this.audioFiles = const [],
    this.resolveSongTitle,
    this.resolveSongDuration,
    this.onCutSaved,
  }) : super(key: key);

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// Sleep timer. Two modes:
///  * timed — stops after a chosen duration, optionally letting the song
///    that's playing at that moment finish first;
///  * end of song — stops when the current song ends.
/// With fade-out on, volume ramps down over the last [fadeSeconds] so the
/// music doesn't cut off abruptly. Also pauses Duo Mode.
class SleepTimerService {
  SleepTimerService._internal();
  static final SleepTimerService instance = SleepTimerService._internal();

  static const _kFade = 'sleep_timer_fade_out';
  static const _kFinishSong = 'sleep_timer_finish_song';
  static const int fadeSeconds = 15;

  /// Persisted options.
  bool fadeOut = true;
  bool finishSong = false;
  bool _prefsLoaded = false;

  Timer? _ticker;
  DateTime? _endAt;
  bool _endOfSong = false;
  int? _initialTotalSeconds;
  AudioPlayer? _player;
  double? _volumeBeforeFade;
  Duration _remaining = Duration.zero;

  final StreamController<SleepTimerState> _ctrl = StreamController.broadcast();
  Stream<SleepTimerState> get stream => _ctrl.stream;
  bool get isActive => _ticker != null;
  bool get isEndOfSong => _endOfSong;

  SleepTimerState _currentState() => SleepTimerState(
        active: _ticker != null,
        remaining: _remaining,
        initialTotalSeconds: _initialTotalSeconds ?? 0,
        endOfSong: _endOfSong,
      );

  Future<void> loadPrefs() async {
    if (_prefsLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      fadeOut = prefs.getBool(_kFade) ?? true;
      finishSong = prefs.getBool(_kFinishSong) ?? false;
    } catch (_) {}
    _prefsLoaded = true;
  }

  Future<void> setOptions({bool? fade, bool? finish}) async {
    if (fade != null) fadeOut = fade;
    if (finish != null) finishSong = finish;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFade, fadeOut);
    await prefs.setBool(_kFinishSong, finishSong);
  }

  /// Timed mode.
  void start(Duration d, {AudioPlayer? player}) {
    stop();
    if (d.inSeconds <= 0) return;
    _player = player;
    _initialTotalSeconds = d.inSeconds;
    _endAt = DateTime.now().add(d);
    _remaining = d;
    _startTicker();
  }

  /// Stop when the song that's playing now finishes.
  void startEndOfSong({AudioPlayer? player}) {
    stop();
    _player = player;
    _endOfSong = true;
    _initialTotalSeconds = _songRemaining()?.inSeconds;
    _remaining = _songRemaining() ?? Duration.zero;
    _startTicker();
  }

  Duration? _songRemaining() {
    final p = _player;
    final dur = p?.duration;
    if (p == null || dur == null || dur == Duration.zero) return null;
    final r = dur - p.position;
    return r.isNegative ? Duration.zero : r;
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) => _tick());
    _ctrl.add(_currentState());
  }

  void _tick() {
    if (_endOfSong) {
      final r = _songRemaining();
      if (r == null) return;
      _remaining = r;
      // Pause just before the track ends so the next one never starts.
      if (r <= const Duration(milliseconds: 600)) {
        _finish();
        return;
      }
    } else {
      final end = _endAt;
      if (end == null) return;
      final r = end.difference(DateTime.now());
      _remaining = r.isNegative ? Duration.zero : r;
      if (_remaining == Duration.zero) {
        if (finishSong && (_player?.playing ?? false)) {
          // Time's up but let the current song play out.
          _endOfSong = true;
          _endAt = null;
          _ctrl.add(_currentState());
          return;
        }
        _finish();
        return;
      }
    }
    _applyFade();
    _ctrl.add(_currentState());
  }

  void _applyFade() {
    final p = _player;
    if (!fadeOut || p == null) return;
    final secs = _remaining.inMilliseconds / 1000.0;
    if (secs <= fadeSeconds) {
      _volumeBeforeFade ??= p.volume;
      final v = (_volumeBeforeFade! * (secs / fadeSeconds)).clamp(0.0, 1.0);
      p.setVolume(v);
    } else if (_volumeBeforeFade != null) {
      // Time was extended past the fade window (e.g. seeking back).
      p.setVolume(_volumeBeforeFade!);
      _volumeBeforeFade = null;
    }
  }

  void _restoreVolume() {
    final v = _volumeBeforeFade;
    if (v != null) {
      try {
        _player?.setVolume(v);
      } catch (_) {}
    }
    _volumeBeforeFade = null;
  }

  void _finish() {
    try {
      _player?.pause();
    } catch (_) {}
    unawaited(DuoService.instance.pause());
    stop();
  }

  void stop() {
    _ticker?.cancel();
    _ticker = null;
    _restoreVolume();
    _endAt = null;
    _endOfSong = false;
    _remaining = Duration.zero;
    _initialTotalSeconds = null;
    _player = null;
    _ctrl.add(_currentState());
  }

  void dispose() {
    stop();
    _ctrl.close();
  }
}

class SleepTimerState {
  final bool active;
  final Duration remaining;
  final int initialTotalSeconds;
  final bool endOfSong;
  SleepTimerState({required this.active, required this.remaining, required this.initialTotalSeconds, this.endOfSong = false});
}

/// SettingsPage State
class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  String _appName = 'Music App';
  String _version = '';

  StreamSubscription<SleepTimerState>? _timerSub;
  SleepTimerState _timerState = SleepTimerState(active: false, remaining: Duration.zero, initialTotalSeconds: 0);

  // Fallback state when ThemeProvider is NOT present:
  bool _fallbackIsDark = false;
  bool _fallbackFollowSystem = true;

  // --- Seek / Forward-Backward controls (combined) ---
  bool _seekButtonsEnabled = true; // single toggle for both forward & backward
  int _seekSeconds = 10; // default seek seconds
  // ------------------------------------------------

  SettingsColors get colors => SettingsColors(_effectiveIsDarkMode);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPackageInfo();
    _subscribeTimer();
    _loadFallbackPrefs(); // load fallback prefs (if provider absent)
    _loadSeekPrefs(); // load persisted seek prefs
    _loadMonoAudio();
  }

  /// Android's Accessibility "Mono audio" — when on, Duo Mode can't give
  /// each ear its own song. Null until read (or on unsupported devices).
  bool? _monoAudio;

  Future<void> _loadMonoAudio() async {
    if (!DuoService.instance.supported) return;
    try {
      final st = await DuoService.instance.getState();
      if (mounted && st != null) setState(() => _monoAudio = st.monoAudio);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from Accessibility settings: show the new Mono audio state.
    if (state == AppLifecycleState.resumed) _loadMonoAudio();
  }

  @override
  void dispose() {
    _timerSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Listen for system brightness changes
  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    final prov = _maybeThemeProvider();
    if (prov != null) {
      if (prov.themeMode == ThemeMode.system) {
        setState(() {});
        _updateSystemOverlayFromProvider(prov);
        widget.onThemeChange?.call(_effectiveIsDarkMode);
      }
    } else {
      if (_fallbackFollowSystem) {
        setState(() {});
        _updateSystemOverlay();
        widget.onThemeChange?.call(_effectiveIsDarkMode);
      }
    }
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() {
        _appName = info.appName;
        _version = info.version;
      });
    } catch (_) {
      if (mounted) setState(() => _version = '');
    }
  }

  void _subscribeTimer() {
    _timerSub = SleepTimerService.instance.stream.listen((s) {
      if (mounted) setState(() => _timerState = s);
    });
  }

  // ---------------- Theme integration ----------------

  ThemeProvider? _maybeThemeProvider({bool listen = false}) {
    try {
      return Provider.of<ThemeProvider>(context, listen: listen);
    } catch (_) {
      return null;
    }
  }

  // Effective theme used by the UI
  bool get _effectiveIsDarkMode {
    final prov = _maybeThemeProvider(listen: false);
    if (prov != null) {
      final mode = prov.themeMode;
      if (mode == ThemeMode.system) {
        final pb = WidgetsBinding.instance.platformDispatcher.platformBrightness;
        return pb == Brightness.dark;
      }
      return mode == ThemeMode.dark;
    } else {
      if (_fallbackFollowSystem) {
        final pb = WidgetsBinding.instance.platformDispatcher.platformBrightness;
        return pb == Brightness.dark;
      }
      return _fallbackIsDark;
    }
  }

  void _updateSystemOverlay() {
    final style = _effectiveIsDarkMode ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
    SystemChrome.setSystemUIOverlayStyle(style);
  }

  void _updateSystemOverlayFromProvider(ThemeProvider prov) {
    final mode = prov.themeMode;
    Brightness effective;
    if (mode == ThemeMode.system) {
      effective = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    } else {
      effective = (mode == ThemeMode.dark) ? Brightness.dark : Brightness.light;
    }
    SystemChrome.setSystemUIOverlayStyle(effective == Brightness.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark);
  }

  // Centralized setter: request a ThemeMode. Will try provider; otherwise use fallback prefs.
  Future<void> _setThemeMode(ThemeMode mode) async {
    final prov = _maybeThemeProvider();
    if (prov != null) {
      // provider exists — call synchronously (may be void)
      try {
        prov.setThemeMode(mode);
      } catch (e) {
        debugPrint('ThemeProvider.setThemeMode error: $e');
      }
    } else {
      // fallback: persist follow-system + dark bool
      if (mode == ThemeMode.system) {
        _fallbackFollowSystem = true;
        _fallbackIsDark = WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
      } else {
        _fallbackFollowSystem = false;
        _fallbackIsDark = (mode == ThemeMode.dark);
      }
      await _saveFallbackPrefs();
    }

    if (mounted) setState(() {});
    _updateSystemOverlay();
    widget.onThemeChange?.call(_effectiveIsDarkMode);
  }

  // ---------------- Fallback prefs for when ThemeProvider is absent ----------------

  Future<void> _loadFallbackPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dark = prefs.getBool(_prefKeyDark);
      final follow = prefs.getBool(_prefKeyFollowSystem);
      _fallbackIsDark = dark ?? false;
      _fallbackFollowSystem = follow ?? true;
      if (mounted) setState(() {});
      _updateSystemOverlay();
      widget.onThemeChange?.call(_effectiveIsDarkMode);
    } catch (e) {
      debugPrint('Failed to load fallback prefs: $e');
    }
  }

  Future<void> _saveFallbackPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyDark, _fallbackIsDark);
      await prefs.setBool(_prefKeyFollowSystem, _fallbackFollowSystem);
    } catch (e) {
      debugPrint('Failed to save fallback prefs: $e');
    }
  }

  // ---------------- Seek prefs persistence ----------------

  Future<void> _loadSeekPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final buttons = prefs.getBool(_prefSeekButtonsEnabled);
      final secs = prefs.getInt(_prefSeekSeconds);
      setState(() {
        _seekButtonsEnabled = buttons ?? true;
        _seekSeconds = secs ?? 10;
      });
    } catch (e) {
      debugPrint('Failed to load seek prefs: $e');
    }
  }

  Future<void> _saveSeekPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefSeekButtonsEnabled, _seekButtonsEnabled);
      await prefs.setInt(_prefSeekSeconds, _seekSeconds);
    } catch (e) {
      debugPrint('Failed to save seek prefs: $e');
    }
  }

  Future<void> _openLatestVersionCard() async {
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=com.zenocta.duomusicplayer&hl=en_IN',
    );

    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open Play Store')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open Play Store: $e')),
        );
      }
    }
  }

  Future<void> _openOurAppsCard() async {
    final uri = Uri.parse(
      'https://play.google.com/store/apps/dev?id=5437613496660069144',
    );

    try {
      final ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );

      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open developer page')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open developer page: $e')),
        );
      }
    }
  }

  // ---------------- UI helpers & navigation ----------------

  Future<void> _openEqualizer() async {
    if (!mounted) return;

    final player = widget.audioPlayer;
    if (player == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Audio player not available')),
      );
      return;
    }

    try {
      final sessionId = await player.androidAudioSessionId;

      if (!mounted) return;

      if (sessionId == null || sessionId == 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Play a song first')),
        );
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => EqualizerScreen(
            audioSessionId: sessionId,
            isDark: _effectiveIsDarkMode,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Equalizer open error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open equalizer')),
      );
    }
  }

  Future<void> _openAudioCutterPicker() async {
    if (!mounted) return;
    if (widget.audioFiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No songs found yet. Scan your library from the Songs tab first.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final file = await Navigator.of(context).push<File>(MaterialPageRoute(
      builder: (_) => _AudioCutterSongPickerPage(
        songs: widget.audioFiles,
        isDark: _effectiveIsDarkMode,
        resolveTitle: widget.resolveSongTitle,
      ),
      fullscreenDialog: true,
    ));
    if (file == null || !mounted) return;

    final title = widget.resolveSongTitle?.call(file) ?? p.basenameWithoutExtension(file.path);
    final duration = widget.resolveSongDuration?.call(file);

    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => AudioCutterPage(
        song: file,
        title: title,
        isDark: _effectiveIsDarkMode,
        knownDuration: duration,
        mainPlayerToPause: widget.audioPlayer,
        onCutSaved: (record) => widget.onCutSaved?.call(record),
      ),
      fullscreenDialog: true,
    ));
  }

  void _openUrlDownloader() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => AudioDownloadPage(isDark: _effectiveIsDarkMode)));
  }

  void _openInternetRadio() {
    if (widget.audioPlayer == null || widget.onPlayRadioStation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Internet Radio is unavailable right now.')),
      );
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => InternetRadioPage(
          audioPlayer: widget.audioPlayer!,
          isDark: _effectiveIsDarkMode,
          onPlayStation: widget.onPlayRadioStation!,
        ),
      ),
    );
  }

  Future<void> _openBackupRestore() async {
    final sc = colors;
    bool busy = false;

    await showModalBottomSheet(
      context: context,
      backgroundColor: sc.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.backup, color: sc.primary),
                  const SizedBox(width: 10),
                  Text('Backup & Restore', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18, color: sc.primaryText)),
                ]),
                const SizedBox(height: 12),
                Text(
                  'Playlists, pasted lyrics, favorites and your 4D/8D conversion history live only on this device. '
                  'Export a backup file to keep or move to a new device, or restore one saved earlier.',
                  style: TextStyle(color: sc.secondaryText),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: sc.primary, padding: const EdgeInsets.symmetric(vertical: 14)),
                    icon: const Icon(Icons.ios_share, color: Colors.white),
                    label: const Text('Export & Share Backup', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    onPressed: busy
                        ? null
                        : () async {
                            setSheetState(() => busy = true);
                            try {
                              await BackupService.instance.exportAndShare();
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export failed: $e')));
                              }
                            } finally {
                              setSheetState(() => busy = false);
                            }
                          },
                  ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: Icon(Icons.file_download, color: sc.primary),
                    label: Text('Import from Downloads', style: TextStyle(color: sc.primary, fontWeight: FontWeight.w600)),
                    onPressed: busy
                        ? null
                        : () async {
                            setSheetState(() => busy = true);
                            try {
                              final summary = await BackupService.instance.importFromDownloads();
                              if (!ctx.mounted) return;
                              if (summary == null) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text('No "$kBackupDownloadsFileName" found in Downloads.'),
                                ));
                              } else {
                                Navigator.pop(ctx);
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(
                                    'Restored ${summary.playlistsImported} playlist(s), ${summary.lyricsImported} lyric(s), '
                                    '${summary.favoritesImported} favorite(s), ${summary.radioStationsImported} station(s), '
                                    '${summary.conversionsImported} conversion(s).',
                                  ),
                                ));
                              }
                            } catch (e) {
                              if (ctx.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e')));
                              }
                            } finally {
                              if (ctx.mounted) setSheetState(() => busy = false);
                            }
                          },
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'To import, save the shared backup file into Downloads as exactly "$kBackupDownloadsFileName" first.',
                  style: TextStyle(color: sc.secondaryText, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPositionMemorySettings() async {
    final svc = PositionMemoryService.instance;
    await svc.load();
    if (!mounted) return;
    final sc = SettingsColors(_effectiveIsDarkMode);
    await showModalBottomSheet(
      context: context,
      backgroundColor: sc.cardColor,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Audiobooks & long files', style: TextStyle(color: sc.primaryText, fontSize: 17, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('Resume long files where you left off. Use the seek buttons (below in Settings) for ±30 s skips.',
                  style: TextStyle(color: sc.secondaryText, fontSize: 12)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: svc.enabled,
                activeColor: sc.primary,
                title: Text('Remember position', style: TextStyle(color: sc.primaryText, fontWeight: FontWeight.w600)),
                subtitle: Text('${svc.rememberedCount} file${svc.rememberedCount == 1 ? '' : 's'} remembered',
                    style: TextStyle(color: sc.secondaryText, fontSize: 12)),
                onChanged: (v) async {
                  await svc.setOptions(enabled: v);
                  setSheet(() {});
                },
              ),
              Text('For files longer than', style: TextStyle(color: sc.primaryText, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final m in PositionMemoryService.minMinuteChoices)
                  ChoiceChip(
                    label: Text(m >= 60 ? '1 hour' : '$m min'),
                    selected: svc.minMinutes == m,
                    selectedColor: sc.primary.withOpacity(0.18),
                    onSelected: svc.enabled
                        ? (_) async {
                            await svc.setOptions(minMinutes: m);
                            setSheet(() {});
                          }
                        : null,
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: svc.audiobookFolders,
                activeColor: sc.primary,
                title: Text('Always for Audiobooks / Podcasts folders', style: TextStyle(color: sc.primaryText, fontWeight: FontWeight.w600)),
                subtitle: Text('Any length, if the folder name contains "audiobook", "podcast" or "books"',
                    style: TextStyle(color: sc.secondaryText, fontSize: 12)),
                onChanged: svc.enabled
                    ? (v) async {
                        await svc.setOptions(audiobookFolders: v);
                        setSheet(() {});
                      }
                    : null,
              ),
            ]),
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  _openSleepTimer() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SleepTimerPage(
          audioPlayer: widget.audioPlayer,
          isDark: _effectiveIsDarkMode,  onThemeChange: (isDark) async {

        },

        ),
      ),
    );
  }


  void _cancelSleepTimer() {
    SleepTimerService.instance.stop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sleep timer cancelled'), backgroundColor: Colors.orange));
  }

  String _formatDurationShort(Duration d) {
    final hrs = d.inHours;
    final mins = d.inMinutes.remainder(60);
    final secs = d.inSeconds.remainder(60);
    if (hrs > 0) return '${hrs}h ${mins}m';
    if (mins > 0) return '${mins}m ${secs}s';
    return '${secs}s';
  }

  Widget _buildSettingCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required String value,
    required VoidCallback onTap,
    Widget? trailingWidget,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      elevation: 2,
      color: colors.cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.divider, width: 1)),
      child: ListTile(
        leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: colors.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Icon(icon, color: colors.primary)),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: colors.primaryText)),
        subtitle: Text(subtitle, style: TextStyle(color: colors.secondaryText)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (value.isNotEmpty) Flexible(child: Text(value, style: TextStyle(color: colors.primary, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if (trailingWidget != null) ...[const SizedBox(width: 8), trailingWidget],
          const SizedBox(width: 8),
          // Changed to dynamic color
          Icon(Icons.chevron_right, color: colors.isDarkMode ? Colors.white : colors.divider),
        ]),
        onTap: onTap,
      ),
    );
  }

  // ---------------- Seek UI (new) ----------------

  Future<void> _selectSeekTime() async {
    final options = [5, 10, 30];
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        return SimpleDialog(
          title: const Text('Select seek time'),
          children: options.map((s) {
            return SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text('$s seconds'),
            );
          }).toList(),
        );
      },
    );

    if (result != null) {
      setState(() => _seekSeconds = result);
      await _saveSeekPrefs();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Seek time set to ${_seekSeconds}s')));
      // NOTE: Here you should forward this value to your fullscreen player when you implement it.
    }
  }

  // ---------------- Build ----------------

  @override
  Widget build(BuildContext context) {
    // If ThemeProvider present, subscribe to it for rebuilds via Provider
    ThemeProvider? prov;
    try {
      prov = Provider.of<ThemeProvider>(context);
    } catch (_) {
      prov = null;
    }

    // Determine currentMode and booleans for UI controls:
    ThemeMode currentMode;
    if (prov != null) {
      currentMode = prov.themeMode;
    } else {
      currentMode = _fallbackFollowSystem ? ThemeMode.system : (_fallbackIsDark ? ThemeMode.dark : ThemeMode.light);
    }

    final useSystem = currentMode == ThemeMode.system;
    final isDarkNow = _effectiveIsDarkMode;

    final timerActive = _timerState.active;
    final timerDisplay = timerActive
        ? (_timerState.endOfSong ? 'End of song' : _formatDurationShort(_timerState.remaining))
        : '';

    final sc = SettingsColors(isDarkNow);
    final bg = sc.backgroundColor;
    final cardColor = sc.cardColor;
    final textColor = sc.primaryText;
    final subTextColor = sc.secondaryText;
    final iconColor = isDarkNow ? const Color(0xFFDBEAFE) : const Color(0xFF1E3A8A);
    final dividerColor = sc.divider;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDarkNow ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppBar(
          title: const Text('Settings'),
          backgroundColor: sc.appBarBackground,
          foregroundColor: sc.appBarForeground,
          elevation: 0,
          centerTitle: true,
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: [
                  const SizedBox(height: 8),

                  // Equalizer card
                  _buildSettingCard(icon: Icons.equalizer, title: 'Equalizer', subtitle: 'Adjust audio bands and apply presets', value: '', onTap: _openEqualizer),
                  _buildSettingCard(
                    icon: Icons.surround_sound_rounded,
                    title: 'Sound effects',
                    subtitle: 'Bass boost, virtualizer, loudness, volume normalization',
                    value: AudioEffectsService.instance.normalize ? 'Normalized' : '',
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => SoundEffectsPage(isDark: isDarkNow, audioFiles: widget.audioFiles)));
                      if (mounted) setState(() {});
                    },
                  ),
                  _buildSettingCard(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Last.fm',
                    subtitle: 'Scrobble your listening history',
                    value: LastFmService.instance.isSignedIn ? (LastFmService.instance.username ?? 'On') : '',
                    onTap: () async {
                      await LastFmService.instance.load();
                      if (!mounted) return;
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LastFmPage(isDark: isDarkNow)));
                      if (mounted) setState(() {});
                    },
                  ),
                  if (DuoService.instance.supported)
                    _buildSettingCard(
                      icon: Icons.hearing_rounded,
                      title: 'Mono audio (Duo Mode)',
                      subtitle: _monoAudio == true
                          ? 'On — both ears get the same mix, so Duo Mode can\'t split songs. Tap to turn it off in Accessibility.'
                          : 'Must stay off so each ear gets its own song. Opens Accessibility settings.',
                      value: _monoAudio == null ? '' : (_monoAudio! ? 'On' : 'Off'),
                      trailingWidget: _monoAudio == true ? const Icon(Icons.warning_amber_rounded, color: Colors.orange) : null,
                      onTap: DuoService.instance.openAccessibilitySettings,
                    ),
                  // Internet Radio
                  _buildSettingCard(icon: Icons.radio, title: 'Internet Radio', subtitle: 'Listen to live stations from around the world', value: '', onTap: _openInternetRadio),
                  _buildSettingCard(
                    icon: Icons.system_update,
                    title: 'Check Latest Version',
                    subtitle: 'Open Play Store to update the app',
                    value: '',
                    onTap: _openLatestVersionCard,
                  ),
                  _buildSettingCard(
                    icon: Icons.apps,
                    title: 'Our Apps',
                    subtitle: 'Discover more apps from Zenocta Solutions',
                    value: '',
                    onTap: _openOurAppsCard,
                  ),

                  _buildSettingCard(
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    subtitle: 'Accent color, pure black theme, start screen',
                    value: AppPalette.amoled && isDarkNow ? 'Black' : (useSystem ? 'System' : (isDarkNow ? 'Dark' : 'Light')),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AppearancePage(isDark: isDarkNow))),
                  ),

                  _buildSettingCard(
                    icon: Icons.filter_alt_outlined,
                    title: 'Library filters',
                    subtitle: 'Hide short clips and exclude folders',
                    value: LibraryFilter.isActive ? 'On' : '',
                    onTap: () async {
                      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => LibraryFiltersPage(isDark: isDarkNow)));
                      if (mounted) setState(() {});
                    },
                  ),

                  // Sleep Timer card
                  _buildSettingCard(
                    icon: Icons.timer,
                    title: 'Sleep Timer',
                    subtitle: 'Stop after a set time or at the end of the song',
                    value: timerDisplay,
                    trailingWidget: timerActive
                        ? TextButton.icon(onPressed: _cancelSleepTimer, icon: Icon(Icons.cancel, color: Colors.orange.shade400), label: Text('Cancel', style: TextStyle(color: Colors.orange.shade400)))
                        : null,
                    onTap: _openSleepTimer,
                  ),

                  _buildSettingCard(
                    icon: Icons.menu_book_rounded,
                    title: 'Audiobooks & long files',
                    subtitle: 'Remember where you stopped and resume there',
                    value: PositionMemoryService.instance.enabled ? 'On' : 'Off',
                    onTap: _openPositionMemorySettings,
                  ),

                  // --- NEW: Combined Seek Buttons toggle & Seek time selector ---
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    child: Card(
                      color: cardColor,
                      elevation: 2,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: dividerColor, width: 1)),
                      child: Column(
                        children: [
                          ListTile(
                            leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: sc.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Icon(Icons.play_arrow, color: sc.primary)),
                            title: const Text('Enable Seek Buttons', style: TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: const Text('Show forward & backward seek controls in player'),
                            trailing: Switch(
                              value: _seekButtonsEnabled,
                              activeColor: sc.primary, // primary color for toggle
                              onChanged: (v) async {
                                setState(() => _seekButtonsEnabled = v);
                                await _saveSeekPrefs();
                              },
                            ),
                          ),
                          const Divider(height: 1),
                          ListTile(
                            leading: Container(width: 44, height: 44, decoration: BoxDecoration(color: sc.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(8)), child: Icon(Icons.timer, color: sc.primary)),
                            title: const Text('Seek Time', style: TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: const Text('Tap to choose amount of seconds to seek forward/backward'),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('$_seekSeconds s', style: TextStyle(color: sc.primary, fontWeight: FontWeight.w600)),
                                const SizedBox(width: 8),
                                // Changed to dynamic color
                                Icon(Icons.chevron_right, color: sc.isDarkMode ? Colors.white : sc.divider),
                              ],
                            ),
                            onTap: _selectSeekTime,
                          ),
                        ],
                      ),
                    ),
                  ),
                  // --- END NEW ---

                  // Audio Cutter
                  _buildSettingCard(icon: Icons.content_cut, title: 'Audio Cutter', subtitle: 'Trim local audio files', value: '', onTap: _openAudioCutterPicker),

                  // URL Downloader
                  _buildSettingCard(icon: Icons.cloud_download, title: 'URL Downloader', subtitle: 'Download MP3 audio files via links', value: '', onTap: _openUrlDownloader),

                  // Local backup / restore (playlists, lyrics, favorites, conversions)
                  _buildSettingCard(
                    icon: Icons.backup,
                    title: 'Backup & Restore',
                    subtitle: 'Save or restore playlists, lyrics and favorites',
                    value: '',
                    onTap: _openBackupRestore,
                  ),

                  Divider(color: colors.divider),

                  _buildSettingCard(
                    icon: Icons.info_outline,
                    title: _appName,
                    subtitle: _version.isNotEmpty ? 'Version $_version' : 'Version info not available',
                    value: '',
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AboutPage(appName: _appName, version: _version, isDark: _effectiveIsDarkMode))),
                  ),

                  const SizedBox(height: 16),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
// --- Audio Cutter song picker (Settings entry point) ---
//
// A minimal song list so "Settings -> Audio Cutter" can jump straight to
// AudioCutterPage without duplicating the songs page's storage scan — the
// list of files is handed down from SongsPage, which has already scanned
// and cached it.
class _AudioCutterSongPickerPage extends StatefulWidget {
  final List<File> songs;
  final bool isDark;
  final String Function(File file)? resolveTitle;

  const _AudioCutterSongPickerPage({required this.songs, required this.isDark, this.resolveTitle});

  @override
  State<_AudioCutterSongPickerPage> createState() => _AudioCutterSongPickerPageState();
}

class _AudioCutterSongPickerPageState extends State<_AudioCutterSongPickerPage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _titleFor(File file) => widget.resolveTitle?.call(file) ?? p.basenameWithoutExtension(file.path);

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? AppPalette.darkBackground : Colors.white;
    final cardColor = isDark ? AppPalette.darkCard : const Color(0xFFF8F9FA);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF666666);
    final primary = AppPalette.accent;

    final query = _query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? widget.songs
        : widget.songs.where((f) => _titleFor(f).toLowerCase().contains(query)).toList();

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Select a Song'),
        backgroundColor: bg,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: textColor),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search songs...',
                hintStyle: TextStyle(color: subColor),
                prefixIcon: Icon(Icons.search, color: subColor),
                filled: true,
                fillColor: cardColor,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(child: Text('No songs found', style: TextStyle(color: subColor)))
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final file = filtered[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 4),
                        color: cardColor,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        child: ListTile(
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration:
                                BoxDecoration(color: primary.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                            child: Icon(Icons.music_note, color: primary),
                          ),
                          title: Text(
                            _titleFor(file),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
                          ),
                          trailing: Icon(Icons.chevron_right, color: subColor),
                          onTap: () => Navigator.of(context).pop(file),
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

// --- SUB-PAGES ---

/// File List Page (kept intact — still useful elsewhere)
class AudioFileListPage extends StatelessWidget {
  final List<File> files;
  final AudioPlayer? audioPlayer;
  final bool isDarkMode;

  const AudioFileListPage({
    Key? key,
    required this.files,
    this.audioPlayer,
    this.isDarkMode = false,
  }) : super(key: key);

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    var i = 0;
    double dbl = bytes.toDouble();
    while (dbl >= 1024 && i < suffixes.length - 1) {
      dbl /= 1024;
      i++;
    }
    return '${dbl.toStringAsFixed(1)} ${suffixes[i]}';
  }

  @override
  Widget build(BuildContext context) {
    final bg = isDarkMode ? AppPalette.darkBackground : Colors.white;
    final text = isDarkMode ? Colors.white : Colors.black;
    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      appBar: AppBar(
        title: const Text('Select audio file'),
        backgroundColor: isDarkMode ? AppPalette.darkBackground : Colors.white,
        foregroundColor: isDarkMode ? Colors.white : Colors.black,
        elevation: 0,
      ),
      backgroundColor: bg,
      body: ListView.separated(
        itemCount: files.length,
        separatorBuilder: (_, __) => Divider(color: isDarkMode ? Colors.grey.shade700 : Colors.grey.shade200),
        itemBuilder: (context, index) {
          final f = files[index];
          String size = '';
          try {
            size = _formatBytes(f.lengthSync());
          } catch (_) {}
          final title = p.basename(f.path);
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isDarkMode ? Colors.grey.shade800 : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.music_note, color: isDarkMode ? Colors.white70 : Colors.black54, size: 22),
            ),
            title: Text(title, style: TextStyle(color: text, fontWeight: FontWeight.w600)),
            subtitle: Text(size, style: TextStyle(color: isDarkMode ? Colors.white70 : Colors.black54, fontSize: 12)),
            onTap: () async {
              // placeholder for audio trimmer navigation
            },
          );
        },
      ),
    );
  }
}

// --- SLEEP TIMER PAGE (kept intact) ---
class SleepTimerPage extends StatefulWidget {
  final AudioPlayer? audioPlayer;
  final bool isDark;

  const SleepTimerPage({
    Key? key,
    this.audioPlayer,
    required this.isDark, required Future<Null> Function(dynamic isDark) onThemeChange,
  }) : super(key: key);

  @override
  State<SleepTimerPage> createState() => _SleepTimerPageState();
}

class _SleepTimerPageState extends State<SleepTimerPage> {
  int _hours = 0;
  int _minutes = 15;
  int _seconds = 0;

  Duration? _remaining;
  bool _active = false;
  bool _endOfSong = false;
  int? _initialTotalSeconds;

  final List<int> _presetMinutes = [5, 10, 15, 30, 45, 60, 90];

  StreamSubscription<SleepTimerState>? _sub;

  SettingsColors get colors => SettingsColors(widget.isDark);

  @override
  void initState() {
    super.initState();
    SleepTimerService.instance.loadPrefs().then((_) {
      if (mounted) setState(() {});
    });
    _active = SleepTimerService.instance.isActive;
    _endOfSong = SleepTimerService.instance.isEndOfSong;
    _sub = SleepTimerService.instance.stream.listen((s) {
      if (mounted) {
        setState(() {
          _active = s.active;
          _endOfSong = s.endOfSong;
          _remaining = s.remaining;
          _initialTotalSeconds = s.initialTotalSeconds > 0 ? s.initialTotalSeconds : null;
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _startTimer() {
    final totalSeconds = _hours * 3600 + _minutes * 60 + _seconds;
    if (totalSeconds <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select a duration greater than zero')));
      return;
    }

    SleepTimerService.instance.start(Duration(seconds: totalSeconds), player: widget.audioPlayer);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Sleep timer started for ${_formatDuration(Duration(seconds: totalSeconds))}'),
      backgroundColor: Colors.green,
    ));
  }

  void _startEndOfSong() {
    final player = widget.audioPlayer;
    if (player == null || player.duration == null || !player.playing) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Play a song first — the timer stops when it ends.')));
      return;
    }
    SleepTimerService.instance.startEndOfSong(player: player);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Music will stop when this song ends'),
      backgroundColor: Colors.green,
    ));
  }

  void _stopTimer() {
    SleepTimerService.instance.stop();
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sleep timer stopped'), backgroundColor: Colors.orange));
  }

  String _formatDuration(Duration d) {
    final hrs = d.inHours;
    final mins = d.inMinutes.remainder(60);
    final secs = d.inSeconds.remainder(60);
    if (hrs > 0) return '${hrs}h ${mins}m ${secs}s';
    if (mins > 0) return '${mins}m ${secs}s';
    return '${secs}s';
  }

  String _formatTimeDisplay(Duration d) {
    final hrs = d.inHours;
    final mins = d.inMinutes.remainder(60);
    final secs = d.inSeconds.remainder(60);
    if (hrs > 0) return '${hrs.toString().padLeft(2, '0')}:${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  Widget _buildPresetChip(int minutes) {
    final isSelected = _minutes == minutes && _hours == 0 && _seconds == 0 && !_active;
    final bg = isSelected ? colors.primary : colors.surfaceColor;
    final textColor = isSelected ? Colors.white : colors.primaryText;

    return GestureDetector(
      onTap: () {
        if (!_active) {
          setState(() {
            _hours = 0;
            _minutes = minutes;
            _seconds = 0;
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
        child: Text('$minutes min', style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
      ),
    );
  }

  Widget _buildNumberInput(String label, int value, int max, ValueChanged<int> onChanged) {
    final disabled = _active;
    return Column(
      children: [
        Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: colors.primaryText)),
        const SizedBox(height: 8),
        Container(
          width: 92,
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
          decoration: BoxDecoration(
            color: colors.surfaceColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            children: [
              IconButton(
                onPressed: disabled ? null : () => onChanged((value < max) ? value + 1 : value),
                icon: Icon(Icons.add, size: 20, color: disabled ? colors.tertiaryText : colors.primaryText),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
              Text(value.toString().padLeft(2, '0'), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primaryText)),
              IconButton(
                onPressed: disabled ? null : () => onChanged((value > 0) ? value - 1 : value),
                icon: Icon(Icons.remove, size: 20, color: disabled ? colors.tertiaryText : colors.primaryText),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    final remaining = _remaining ?? Duration.zero;
    final total = _initialTotalSeconds ?? (_hours * 3600 + _minutes * 60 + _seconds);
    final progress = (total > 0) ? (remaining.inSeconds / total).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(
        title: const Text('Sleep Timer'),
        backgroundColor: colors.appBarBackground,
        foregroundColor: colors.appBarForeground,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          if (active)
            Card(
              color: colors.cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colors.primary),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(children: [
                  Text(_endOfSong ? 'Stops when this song ends' : 'Time Remaining',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primary)),
                  const SizedBox(height: 12),
                  Text(_formatTimeDisplay(remaining), style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: colors.primary)),
                  const SizedBox(height: 12),
                  LinearProgressIndicator(value: progress, minHeight: 6, backgroundColor: colors.surfaceColor, color: colors.primary),
                ]),
              ),
            ),
          const SizedBox(height: 20),
          Card(
            elevation: 2,
            color: colors.cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.divider)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Quick Presets', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primaryText)),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    GestureDetector(
                      onTap: active ? null : _startEndOfSong,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: _endOfSong ? colors.primary : colors.primary.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.music_off_rounded, size: 16, color: _endOfSong ? Colors.white : colors.primary),
                          const SizedBox(width: 6),
                          Text('End of song', style: TextStyle(color: _endOfSong ? Colors.white : colors.primary, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                    ..._presetMinutes.map(_buildPresetChip),
                  ]),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            elevation: 2,
            color: colors.cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.divider)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                Text('Custom Duration', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: colors.primaryText)),
                const SizedBox(height: 12),
                Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                  _buildNumberInput('Hrs', _hours, 23, (v) => setState(() => _hours = v)),
                  _buildNumberInput('Min', _minutes, 59, (v) => setState(() => _minutes = v)),
                  _buildNumberInput('Sec', _seconds, 59, (v) => setState(() => _seconds = v)),
                ]),
              ]),
            ),
          ),
          const SizedBox(height: 18),
          Card(
            elevation: 2,
            color: colors.cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.divider)),
            child: Column(children: [
              SwitchListTile(
                value: SleepTimerService.instance.fadeOut,
                activeColor: colors.primary,
                secondary: Icon(Icons.trending_down_rounded, color: colors.primary),
                title: Text('Fade out', style: TextStyle(color: colors.primaryText, fontWeight: FontWeight.w600)),
                subtitle: Text('Lower the volume gradually over the last ${SleepTimerService.fadeSeconds} seconds',
                    style: TextStyle(color: colors.secondaryText, fontSize: 12)),
                onChanged: (v) async {
                  await SleepTimerService.instance.setOptions(fade: v);
                  setState(() {});
                },
              ),
              Divider(height: 1, color: colors.divider),
              SwitchListTile(
                value: SleepTimerService.instance.finishSong,
                activeColor: colors.primary,
                secondary: Icon(Icons.queue_music_rounded, color: colors.primary),
                title: Text('Let the song finish', style: TextStyle(color: colors.primaryText, fontWeight: FontWeight.w600)),
                subtitle: Text("When time's up, stop at the end of the current song instead of mid-song",
                    style: TextStyle(color: colors.secondaryText, fontSize: 12)),
                onChanged: (v) async {
                  await SleepTimerService.instance.setOptions(finish: v);
                  setState(() {});
                },
              ),
            ]),
          ),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (!active)
              ElevatedButton.icon(
                onPressed: _startTimer,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Timer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              )
            else
              ElevatedButton.icon(
                onPressed: _stopTimer,
                icon: const Icon(Icons.stop),
                label: const Text('Stop Timer'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              )
          ]),
          const SizedBox(height: 20),
          Card(
            color: active ? Colors.green.shade900.withOpacity(0.12) : colors.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: active ? Colors.green.shade700 : colors.divider),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                Icon(active ? Icons.timer : Icons.timer_off, color: active ? Colors.green : colors.tertiaryText),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    active ? 'Sleep timer active - music will stop automatically' : 'Sleep timer is not active',
                    style: TextStyle(color: active ? Colors.green : colors.tertiaryText, fontWeight: FontWeight.w600),
                  ),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }
}

// --- ABOUT PAGE (kept intact) ---
class AboutPage extends StatelessWidget {
  final String appName;
  final String version;
  final bool isDark;

  const AboutPage({Key? key, required this.appName, required this.version, required this.isDark}) : super(key: key);

  SettingsColors get colors => SettingsColors(isDark);

  @override
  Widget build(BuildContext context) {
    final ver = version.isNotEmpty ? 'Version $version' : 'Unknown version';

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: colors.backgroundColor,
      appBar: AppBar(title: const Text('About'), backgroundColor: colors.appBarBackground, foregroundColor: colors.appBarForeground, elevation: 0),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(
            child: Column(children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  gradient: AppPalette.gradient,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Icon(Icons.music_note, color: Colors.white, size: 44),
              ),
              const SizedBox(height: 16),
              Text(appName, style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: colors.primaryText)),
              const SizedBox(height: 6),
              Text(ver, style: TextStyle(fontSize: 14, color: colors.secondaryText)),
            ]),
          ),
          const SizedBox(height: 28),
          Text('About This App', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colors.primaryText)),
          const SizedBox(height: 10),
          Text(
            'A beautiful music player application with advanced features including equalizer settings, sleep timer, playlist management, and high-quality audio playback.',
            style: TextStyle(fontSize: 15, height: 1.5, color: colors.secondaryText),
          ),
          const SizedBox(height: 22),
          Text('Features', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: colors.primaryText)),
          const SizedBox(height: 12),
          ..._buildFeatureList(),
          const SizedBox(height: 20),
          Card(
            elevation: 2,
            color: colors.cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: colors.divider)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('App Information', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: colors.primaryText)),
                const SizedBox(height: 12),
                _buildInfoItem('Developer', 'Zenocta Solutions'),
                _buildInfoItem('Contact', 'contact@zenocta.com'),
                _buildInfoItem('Website', 'www.zenocta.com'),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          Center(child: Text('© 2025 Music Player App. All rights reserved.', style: TextStyle(fontSize: 12, color: colors.tertiaryText))),
          const SizedBox(height: 24),
        ]),
      ),
    );
  }

  List<Widget> _buildFeatureList() {
    final features = [
      '5-band Graphic Equalizer',
      'Smart Sleep Timer with Countdown (seconds supported)',
      'High Quality Audio Playback',
      'Real-time Audio Processing (platform bridge)',
      'Playlist Management',
      'Favorite Songs Collection',
      'Notification play',
      'Background play support',
      'Set as Ringtone Feature'
    ];

    return features
        .map((f) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
        const SizedBox(width: 12),
        Expanded(child: Text(f, style: TextStyle(color: colors.primaryText))),
      ]),
    ))
        .toList();
  }

  Widget _buildInfoItem(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 120, child: Text(title, style: TextStyle(fontWeight: FontWeight.w600, color: colors.primaryText))),
        Expanded(child: Text(value, style: TextStyle(color: colors.secondaryText))),
      ]),
    );
  }
}