// lib/main.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import     'songs_page.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'constants.dart';
import 'app_palette.dart';
import 'library_service.dart';
import 'app_update_service.dart';
import 'motion/motion.dart';
import 'ui/app_theme.dart';
import 'l10n/gen/app_localizations.dart';


class ThemeProvider extends ChangeNotifier {
  static const String _prefKey = 'app_theme_mode';

  /// Internal storage of choice as string: 'system', 'light', 'dark'
  String _modeString = 'system';

  ThemeProvider() {
    _loadThemePreference();
  }

  /// Expose as ThemeMode for MaterialApp
  ThemeMode get themeMode {
    switch (_modeString) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }

  /// Convenience getters
  bool get isUsingSystem => _modeString == 'system';
  bool get isLight => _modeString == 'light';
  bool get isDark => _modeString == 'dark';

  /// Set theme mode using ThemeMode
  Future<void> setThemeMode(ThemeMode mode) async {
    final val = _stringFromThemeMode(mode);
    if (val == _modeString) return;
    _modeString = val;
    notifyListeners();
    await _saveThemePreference();
  }

  /// Set to system
  Future<void> useSystemTheme() async => setThemeMode(ThemeMode.system);

  /// Set to light
  Future<void> useLightTheme() async => setThemeMode(ThemeMode.light);

  /// Set to dark
  Future<void> useDarkTheme() async => setThemeMode(ThemeMode.dark);

  /// Toggle between light <-> dark (if currently system, switching toggles to dark)
  Future<void> toggleLightDark() async {
    if (_modeString == 'dark') {
      await setThemeMode(ThemeMode.light);
    } else {
      await setThemeMode(ThemeMode.dark);
    }
  }

  String _stringFromThemeMode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
      default:
        return 'system';
    }
  }

  /// Persist selection
  Future<void> _saveThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, _modeString);
    } catch (e) {
      // ignore persistence errors silently
      debugPrint('Failed to save theme preference: $e');
    }
  }

  /// Load selection at startup (defaults to 'system' if missing)
  Future<void> _loadThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(_prefKey);
      if (stored != null && (stored == 'system' || stored == 'light' || stored == 'dark')) {
        _modeString = stored;
      } else {
        _modeString = 'system';
      }
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load theme preference: $e');
      _modeString = 'system';
      notifyListeners();
    }
  }
}

/// ------------------------------------------
/// APP ENTRY POINT
/// ------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Must run before anything writes SharedPreferences: tells a fresh install
  // apart from an update, so only updating users see "What's new".
  await AppUpdateService.captureInstallState();

  // Appearance (accent / AMOLED / start tab), song sort order and library
  // filters are read synchronously by the first frame, so load them first.
  // All are tiny SharedPreferences reads.
  await Future.wait([AppPalette.load(), SongSort.load(), LibraryFilter.load()]);

  // Screens used to init Hive lazily, which only worked because the Songs
  // tab happened to load first. Overview is now the default tab and reads
  // playlists straight away, so Hive must be ready before the first frame.
  await Hive.initFlutter();

  // NOTE: The media notification/MediaSession is owned solely by the
  // AudioService.init() call in songs_page.dart's _NotificationAudioHandler.
  // just_audio_background also calls AudioService.init() internally, so
  // initializing it here as well used to register a SECOND AudioHandler
  // that raced with the first to push PlaybackState/MediaItem updates to
  // the same native notification — the root cause of the Play/Pause and
  // Stop button flickering. Do not re-add JustAudioBackground.init() here
  // unless the hand-rolled AudioHandler in songs_page.dart is removed too.

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const MyApp(),
    ),
  );

  // "What's new" after an update, then the Google Play in-app update check.
  WidgetsBinding.instance.addPostFrameCallback((_) => AppUpdateService.start());
}

/// ------------------------------------------
/// ROOT APP WIDGET
/// ------------------------------------------
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Listen to ThemeProvider; when it changes, MaterialApp rebuilds
    final themeProvider = context.watch<ThemeProvider>();

    // Rebuild the theme when the accent color / AMOLED setting changes.
    return ValueListenableBuilder<int>(
      valueListenable: AppPalette.changes,
      builder: (context, _, __) => MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: AppUpdateService.navigatorKey,
      scaffoldMessengerKey: AppUpdateService.messengerKey,
      title: 'Music Player',

      // Localization scaffold (English template only for now).
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,

      // Use provider's ThemeMode — supports system / light / dark
      themeMode: themeProvider.themeMode,

      // Built in ui/app_theme.dart: accent colour scheme, shared card/sheet
      // radii, text hierarchy and the Android page-transition style.
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),

      // Home: keep your existing screen
      home: const _LaunchFade(child: AudioPlayerScreen()),
      ),
    );
  }
}

/// Fades and lifts the first frame in so the app doesn't pop on launch.
class _LaunchFade extends StatefulWidget {
  final Widget child;
  const _LaunchFade({required this.child});

  @override
  State<_LaunchFade> createState() => _LaunchFadeState();
}

class _LaunchFadeState extends State<_LaunchFade> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.slow);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Motion.standard);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _t,
      child: AnimatedBuilder(
        animation: _t,
        child: widget.child,
        builder: (context, child) => Transform.translate(offset: Offset(0, (1 - _t.value) * 12), child: child),
      ),
    );
  }
}
