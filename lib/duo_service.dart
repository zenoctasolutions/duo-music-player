// lib/duo_service.dart
//
// Dart side of Duo Mode: two different songs playing at once, one in the
// left ear and one in the right, so two people can share a pair of
// earphones. Playback itself runs natively (android/.../DuoEngine.kt) — a
// pair of ExoPlayers whose audio is downmixed to mono and routed to a single
// output channel each — so it is independent of the app's main just_audio
// player and keeps going in the background via DuoPlaybackService.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum DuoSide { left, right }

extension DuoSideX on DuoSide {
  String get key => this == DuoSide.left ? 'left' : 'right';
  DuoSide get other => this == DuoSide.left ? DuoSide.right : DuoSide.left;
}

class DuoSideState {
  final String? path;
  final int index;
  final int queueLength;
  final bool playing;
  final bool ended;
  final Duration position;
  final Duration duration;
  final bool shuffle;
  final String repeat; // off | all | one

  const DuoSideState({
    this.path,
    this.index = 0,
    this.queueLength = 0,
    this.playing = false,
    this.ended = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.shuffle = false,
    this.repeat = 'off',
  });

  bool get loaded => path != null;

  factory DuoSideState.fromMap(Map? m) {
    if (m == null || m['path'] == null) return const DuoSideState();
    return DuoSideState(
      path: m['path'] as String?,
      index: (m['index'] as num?)?.toInt() ?? 0,
      queueLength: (m['queueLength'] as num?)?.toInt() ?? 0,
      playing: m['playing'] == true,
      ended: m['ended'] == true,
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
      shuffle: m['shuffle'] == true,
      repeat: (m['repeat'] as String?) ?? 'off',
    );
  }
}

class DuoState {
  /// Name of the connected earphones/earbuds, or null when none are connected.
  final String? headphones;

  /// Android's accessibility "Mono audio" is on — Duo can't split ears.
  final bool monoAudio;
  final bool bothEars;
  final DuoSideState left;
  final DuoSideState right;

  const DuoState({
    this.headphones,
    this.monoAudio = false,
    this.bothEars = false,
    this.left = const DuoSideState(),
    this.right = const DuoSideState(),
  });

  DuoSideState side(DuoSide s) => s == DuoSide.left ? left : right;
  bool get anyLoaded => left.loaded || right.loaded;
  bool get anyPlaying => left.playing || right.playing;

  factory DuoState.fromMap(Map m) => DuoState(
        headphones: m['headphones'] as String?,
        monoAudio: m['monoAudio'] == true,
        bothEars: m['bothEars'] == true,
        left: DuoSideState.fromMap(m['left'] as Map?),
        right: DuoSideState.fromMap(m['right'] as Map?),
      );
}

class DuoService with WidgetsBindingObserver {
  DuoService._();
  static final DuoService instance = DuoService._();

  static const _channel = MethodChannel('music_app/duo');
  static const _prefsKey = 'duo_session_v1';

  /// Set by the host screen: pauses the main player/radio before Duo starts,
  /// so the two playback systems never talk over each other.
  VoidCallback? onBeforePlay;

  bool _supported = true;
  bool get supported => _supported;

  /// Whether a Duo session might be producing sound (cheap guard so the main
  /// player doesn't make a platform call on every play when Duo is unused).
  bool _maybeActive = false;
  bool _observing = false;

  final Map<DuoSide, List<String>> _queues = {DuoSide.left: [], DuoSide.right: []};
  final Map<DuoSide, List<String>> _titles = {DuoSide.left: [], DuoSide.right: []};

  /// User volume per ear (0..1) and the L/R balance (-1 = all left, 1 = all right).
  final Map<DuoSide, double> volumes = {DuoSide.left: 1.0, DuoSide.right: 1.0};
  double balance = 0.0;

  DuoState _last = const DuoState();
  DuoState get lastState => _last;

  void _ensureObserving() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      unawaited(saveSession());
    }
  }

  Future<T?> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    if (!_supported) return null;
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      // Duo Mode is implemented natively on Android only.
      _supported = false;
      return null;
    } catch (e) {
      debugPrint('Duo $method failed: $e');
      return null;
    }
  }

  Future<DuoState?> getState() async {
    final m = await _invoke<Map>('getState');
    if (m == null) return null;
    _last = DuoState.fromMap(m);
    _maybeActive = _last.anyPlaying;
    return _last;
  }

  Future<String?> headphones() => _invoke<String>('headphones');

  Future<void> setQueue(DuoSide side, List<String> paths, List<String> titles, int startIndex, {bool play = true}) async {
    _ensureObserving();
    _queues[side] = List.of(paths);
    _titles[side] = List.of(titles);
    if (play) {
      _beforePlay();
      // Before the native call, so the foreground service's notification
      // is posted with the permission already granted.
      await _ensureNotificationPermission();
    }
    await _invoke('setQueue', {
      'side': side.key,
      'paths': paths,
      'titles': titles,
      'startIndex': startIndex,
      'play': play,
    });
    await _applyVolume(side);
  }

  void _beforePlay() {
    _maybeActive = true;
    onBeforePlay?.call();
  }

  Future<void> play([DuoSide? side]) async {
    _beforePlay();
    await _ensureNotificationPermission();
    await _invoke('play', {'side': side?.key});
  }

  /// Android 13+ hides the Duo notification (and with it the per-ear
  /// controls once the app is left) until notifications are allowed.
  /// Asks once; a "Don't allow" is respected and surfaced on the Duo page
  /// via [notificationsAllowed] instead of asking again.
  Future<void> _ensureNotificationPermission() async {
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) await Permission.notification.request();
    } catch (_) {}
  }

  Future<bool> notificationsAllowed() async {
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return true;
    }
  }

  Future<void> pause([DuoSide? side]) => _invoke('pause', {'side': side?.key});

  /// Called whenever the main player starts: Duo yields to it.
  Future<void> pauseIfActive() async {
    if (!_maybeActive) return;
    _maybeActive = false;
    await pause();
  }

  Future<void> seek(DuoSide side, Duration pos) => _invoke('seek', {'side': side.key, 'positionMs': pos.inMilliseconds});
  Future<void> next(DuoSide side) => _invoke('next', {'side': side.key});
  Future<void> previous(DuoSide side) => _invoke('previous', {'side': side.key});
  Future<void> setShuffle(DuoSide side, bool enabled) => _invoke('setShuffle', {'side': side.key, 'enabled': enabled});
  Future<void> setRepeat(DuoSide side, String mode) => _invoke('setRepeat', {'side': side.key, 'mode': mode});
  Future<void> setBothEars(bool enabled) => _invoke('setBothEars', {'enabled': enabled});
  Future<void> openAccessibilitySettings() => _invoke('openAccessibilitySettings');

  Future<void> setVolume(DuoSide side, double v) async {
    volumes[side] = v.clamp(0.0, 1.0);
    await _applyVolume(side);
  }

  Future<void> setBalance(double b) async {
    balance = b.clamp(-1.0, 1.0);
    await _applyVolume(DuoSide.left);
    await _applyVolume(DuoSide.right);
  }

  /// Effective ear volume = user volume × balance attenuation for that ear.
  double effectiveVolume(DuoSide side) {
    final attenuation = side == DuoSide.left ? (1.0 - balance).clamp(0.0, 1.0) : (1.0 + balance).clamp(0.0, 1.0);
    return (volumes[side] ?? 1.0) * attenuation;
  }

  Future<void> _applyVolume(DuoSide side) => _invoke('setVolume', {'side': side.key, 'volume': effectiveVolume(side)});

  Future<void> swapSides() async {
    await _invoke('swapSides');
    final q = _queues[DuoSide.left]!;
    _queues[DuoSide.left] = _queues[DuoSide.right]!;
    _queues[DuoSide.right] = q;
    final t = _titles[DuoSide.left]!;
    _titles[DuoSide.left] = _titles[DuoSide.right]!;
    _titles[DuoSide.right] = t;
    final v = volumes[DuoSide.left]!;
    volumes[DuoSide.left] = volumes[DuoSide.right]!;
    volumes[DuoSide.right] = v;
    await _applyVolume(DuoSide.left);
    await _applyVolume(DuoSide.right);
  }

  Future<void> stop() async {
    _maybeActive = false;
    await saveSession();
    await _invoke('stop');
  }

  // ------------------------------------------------------------ persistence

  /// Remembers each ear's queue, song and position so the next session can
  /// pick up where it left off (a top complaint about competing duo apps:
  /// "every time it starts from the first song").
  Future<void> saveSession() async {
    try {
      final st = await getState();
      if (st == null || !st.anyLoaded) return;
      final data = <String, dynamic>{'balance': balance};
      for (final side in DuoSide.values) {
        final s = st.side(side);
        data[side.key] = {
          'paths': _queues[side],
          'titles': _titles[side],
          'index': s.index,
          'positionMs': s.position.inMilliseconds,
          'volume': volumes[side],
          'shuffle': s.shuffle,
          'repeat': s.repeat,
        };
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(data));
    } catch (e) {
      debugPrint('Duo saveSession failed: $e');
    }
  }

  /// Loads the last saved session (paused) if the engine is idle. Only keeps
  /// songs that still exist in [availablePaths].
  Future<bool> restoreSession(Set<String> availablePaths) async {
    try {
      final st = await getState();
      if (st == null || st.anyLoaded) return false;
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return false;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      balance = ((data['balance'] as num?) ?? 0).toDouble();
      var restored = false;
      for (final side in DuoSide.values) {
        final m = data[side.key] as Map<String, dynamic>?;
        if (m == null) continue;
        final paths = List<String>.from(m['paths'] ?? const []);
        final titles = List<String>.from(m['titles'] ?? const []);
        if (paths.isEmpty) continue;
        final index = ((m['index'] as num?) ?? 0).toInt().clamp(0, paths.length - 1);
        final current = paths[index];
        if (!availablePaths.contains(current)) continue;
        // Drop songs deleted since, keeping the current one's position.
        final keptPaths = <String>[];
        final keptTitles = <String>[];
        for (var i = 0; i < paths.length; i++) {
          if (availablePaths.contains(paths[i])) {
            keptPaths.add(paths[i]);
            keptTitles.add(i < titles.length ? titles[i] : '');
          }
        }
        volumes[side] = ((m['volume'] as num?) ?? 1.0).toDouble();
        await setQueue(side, keptPaths, keptTitles, keptPaths.indexOf(current), play: false);
        await seek(side, Duration(milliseconds: ((m['positionMs'] as num?) ?? 0).toInt()));
        if (m['shuffle'] == true) await setShuffle(side, true);
        final repeat = m['repeat'] as String?;
        if (repeat != null && repeat != 'off') await setRepeat(side, repeat);
        restored = true;
      }
      return restored;
    } catch (e) {
      debugPrint('Duo restoreSession failed: $e');
      return false;
    }
  }
}
