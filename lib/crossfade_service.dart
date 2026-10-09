// lib/crossfade_service.dart
//
// Crossfade between songs (0 = off, up to 12 s).
//
// The app's main just_audio player stays the single source of truth for
// the queue, notification, widget, EQ and UI. Crossfade never replaces
// it: [crossfadeSeconds] before a song ends, a short-lived "tail" player
// starts playing the *same* song from the same position and fades it
// out, while the main player immediately advances to the next song and
// fades it in (equal-power curves). When the fade finishes the tail
// player is disposed. So the only thing that changes is that two songs
// overlap for a few seconds instead of playing back-to-back.
//
// Skipped automatically for radio, repeat-one, very short songs, and
// when the sleep timer is set to stop at the end of the song.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'audio_effects_service.dart';
import 'player_screen.dart' show PlaylistContext;
import 'radio_service.dart' show RadioPlaybackContext;
import 'settings_page.dart' show SleepTimerService;

class CrossfadeService {
  CrossfadeService._();
  static final CrossfadeService instance = CrossfadeService._();

  static const _kSeconds = 'crossfade_seconds';
  static const int maxSeconds = 12;

  int crossfadeSeconds = 0;
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  AudioPlayer? _main;
  Future<void> Function()? _advance;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  AudioPlayer? _tail;
  bool _busy = false;
  String? _triggeredKey;

  bool get isActive => _busy;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      crossfadeSeconds = (prefs.getInt(_kSeconds) ?? 0).clamp(0, maxSeconds);
    } catch (_) {}
  }

  Future<void> setSeconds(int s) async {
    crossfadeSeconds = s.clamp(0, maxSeconds);
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSeconds, crossfadeSeconds);
  }

  /// [advance] must start the next song on [main] using the app's own
  /// next-track logic (queue order, shuffle, wrap-around).
  Future<void> attach(AudioPlayer main, {required Future<void> Function() advance}) async {
    await load();
    _main = main;
    _advance = advance;
    _posSub?.cancel();
    _playingSub?.cancel();
    _posSub = main.positionStream.listen(_onPosition);
    _playingSub = main.playingStream.listen((playing) {
      // Paused mid-crossfade: silence the outgoing tail too.
      if (!playing && _busy) _tail?.pause();
      if (playing && _busy) _tail?.play();
    });
  }

  /// Pure trigger rule (unit-tested): whether a crossfade should start now.
  @visibleForTesting
  static bool shouldStart({
    required int seconds,
    required Duration position,
    required Duration? duration,
    required bool playing,
  }) {
    if (seconds <= 0 || !playing || duration == null) return false;
    // Songs shorter than ~2 fades + 5 s just play normally.
    if (duration < Duration(seconds: seconds * 2 + 5)) return false;
    final remaining = duration - position;
    return remaining <= Duration(seconds: seconds) && remaining > const Duration(milliseconds: 400);
  }

  void _onPosition(Duration pos) {
    final main = _main;
    if (main == null || _busy) return;
    if (!shouldStart(seconds: crossfadeSeconds, position: pos, duration: main.duration, playing: main.playing)) return;
    if (RadioPlaybackContext.isActive || main.loopMode == LoopMode.one) return;
    if (SleepTimerService.instance.isEndOfSong) return;
    final path = PlaylistContext.currentPathNotifier.value;
    if (path == null || !File(path).existsSync()) return;
    final key = '$path@${main.duration?.inMilliseconds}';
    if (key == _triggeredKey) return;
    _triggeredKey = key;
    unawaited(_run(path));
  }

  Future<void> _run(String path) async {
    final main = _main!;
    _busy = true;
    final fx = AudioEffectsService.instance;
    AudioPlayer? tail;
    try {
      tail = AudioPlayer(
        handleInterruptions: false,
        handleAudioSessionActivation: false,
        androidApplyAudioAttributes: false,
      );
      _tail = tail;
      await tail.setFilePath(path);
      await tail.setSpeed(main.speed);
      // Sample the position as late as possible so both copies line up.
      await tail.seek(main.position);
      final startVolume = main.volume;
      await tail.setVolume(startVolume);
      unawaited(tail.play());

      final remaining = (main.duration ?? Duration.zero) - main.position;
      final fadeMs = remaining.inMilliseconds.clamp(500, crossfadeSeconds * 1000);

      await fx.setFadeMultiplier(0);
      await _advance?.call();

      const stepMs = 50;
      final steps = (fadeMs / stepMs).ceil();
      var pausedTicks = 0;
      for (var i = 1; i <= steps; i++) {
        await Future.delayed(const Duration(milliseconds: stepMs));
        if (!main.playing) {
          // Wait out a short pause without advancing the fade; after ~20 s
          // paused, just finish (the tail is already paused).
          i--;
          if (++pausedTicks > 100) break;
          await Future.delayed(const Duration(milliseconds: 150));
          continue;
        }
        final t = i / steps;
        // Equal-power crossfade keeps perceived loudness constant.
        await tail.setVolume(startVolume * math.cos(t * math.pi / 2));
        await fx.setFadeMultiplier(math.sin(t * math.pi / 2));
      }
    } catch (e) {
      debugPrint('Crossfade failed: $e');
    } finally {
      await fx.setFadeMultiplier(1);
      _tail = null;
      try {
        await tail?.stop();
        await tail?.dispose();
      } catch (_) {}
      _busy = false;
    }
  }
}
