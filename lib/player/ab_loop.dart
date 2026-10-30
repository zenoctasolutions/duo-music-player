// lib/player/ab_loop.dart
//
// Pure logic for A-B repeat and pitch helpers (no Flutter / player deps).
import 'dart:math' as math;

enum AbLoopPhase { idle, aSet, active }

/// Result of a tap on the A-B button.
enum AbTapResult { aSet, activated, cleared, rejectedTooShort }

/// Result of a position tick.
class AbLoopTick {
  final Duration? seekTo;
  final bool cleared;
  const AbLoopTick({this.seekTo, this.cleared = false});
  static const none = AbLoopTick();
}

class AbLoop {
  /// Minimum length of the looped region.
  static const Duration minLength = Duration(seconds: 1);

  /// If playback is further than this past B the loop is cleared (the user
  /// seeked out of the loop) rather than pulled back.
  static const Duration overshootTolerance = Duration(seconds: 1);

  AbLoopPhase phase = AbLoopPhase.idle;
  Duration? a;
  Duration? b;

  bool get isIdle => phase == AbLoopPhase.idle;
  bool get isActive => phase == AbLoopPhase.active;

  /// Advance the idle -> aSet -> active -> idle state machine.
  AbTapResult tap(Duration position) {
    switch (phase) {
      case AbLoopPhase.idle:
        a = position;
        b = null;
        phase = AbLoopPhase.aSet;
        return AbTapResult.aSet;
      case AbLoopPhase.aSet:
        if (position <= a! + minLength) return AbTapResult.rejectedTooShort;
        b = position;
        phase = AbLoopPhase.active;
        return AbTapResult.activated;
      case AbLoopPhase.active:
        clear();
        return AbTapResult.cleared;
    }
  }

  void clear() {
    phase = AbLoopPhase.idle;
    a = null;
    b = null;
  }

  /// Feed a playback position. While active: at/after B (within tolerance)
  /// returns A to seek to; far past B clears the loop.
  AbLoopTick onPosition(Duration pos) {
    if (!isActive) return AbLoopTick.none;
    final end = b!;
    if (pos > end + overshootTolerance) {
      clear();
      return const AbLoopTick(cleared: true);
    }
    if (pos >= end) return AbLoopTick(seekTo: a);
    return AbLoopTick.none;
  }
}

/// Pitch range in semitones offered by the UI.
const int kMinSemitones = -6;
const int kMaxSemitones = 6;

/// Playback pitch ratio for a semitone offset (equal temperament).
double semitonesToRatio(int semitones) => math.pow(2, semitones / 12).toDouble();

String semitoneLabel(int semitones) =>
    semitones == 0 ? '0 (original)' : '${semitones > 0 ? '+' : ''}$semitones st';
