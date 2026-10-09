// lib/home_widget_service.dart
//
// Pushes now-playing state to the native home-screen widget via the
// home_widget package's SharedPreferences bridge. This file only ever
// WRITES state — widget button taps (play/pause/next/prev) are handled
// entirely natively by NowPlayingWidgetProvider.kt, which broadcasts
// standard Android media-button intents through the same
// MediaButtonReceiver path hardware buttons and the playback notification
// already use, rather than routing through a home_widget background Dart
// callback (a second, separate interactivity mechanism this app doesn't
// need since its MediaSession already handles transport controls).
import 'package:home_widget/home_widget.dart';

const String kNowPlayingWidgetProviderName = 'NowPlayingWidgetProvider';

/// Every widget style reads the same data; all must be refreshed.
const List<String> kWidgetProviderNames = [
  kNowPlayingWidgetProviderName,
  'ArtTileWidgetProvider',
  'LargePlayerWidgetProvider',
];

Future<void> _updateAllWidgets() async {
  for (final name in kWidgetProviderNames) {
    try {
      await HomeWidget.updateWidget(name: name);
    } catch (_) {}
  }
}

class HomeWidgetService {
  HomeWidgetService._internal();
  static final HomeWidgetService instance = HomeWidgetService._internal();

  String? _lastTitle;
  String? _lastArtist;
  bool? _lastIsPlaying;
  String? _lastCoverPath;

  /// Full refresh — called on every track change. Skips the native update
  /// call if nothing actually changed, since this is invoked from the same
  /// notification-refresh path that can fire redundantly.
  Future<void> updateNowPlaying({
    required String title,
    required String artist,
    required bool isPlaying,
    String? coverPath,
  }) async {
    if (_lastTitle == title &&
        _lastArtist == artist &&
        _lastIsPlaying == isPlaying &&
        _lastCoverPath == coverPath) {
      return;
    }
    _lastTitle = title;
    _lastArtist = artist;
    _lastIsPlaying = isPlaying;
    _lastCoverPath = coverPath;

    try {
      await Future.wait([
        HomeWidget.saveWidgetData<String>('title', title),
        HomeWidget.saveWidgetData<String>('artist', artist),
        HomeWidget.saveWidgetData<bool>('isPlaying', isPlaying),
        HomeWidget.saveWidgetData<String>('coverPath', coverPath ?? ''),
      ]);
      await _updateAllWidgets();
    } catch (_) {
      // Best-effort — a widget update failure should never affect playback.
    }
  }

  /// Lighter update for a play/pause toggle that doesn't change the current
  /// track — avoids rewriting title/artist/art on every pause/resume.
  Future<void> updatePlayingState(bool isPlaying) async {
    if (_lastIsPlaying == isPlaying) return;
    _lastIsPlaying = isPlaying;
    try {
      await HomeWidget.saveWidgetData<bool>('isPlaying', isPlaying);
      await _updateAllWidgets();
    } catch (_) {}
  }
}
