import 'package:flutter_test/flutter_test.dart';
import 'package:music/player/ab_loop.dart';

void main() {
  const s = Duration(seconds: 1);
  test('state machine idle -> aSet -> active -> idle', () {
    final l = AbLoop();
    expect(l.tap(s * 10), AbTapResult.aSet);
    expect(l.phase, AbLoopPhase.aSet);
    expect(l.tap(s * 11), AbTapResult.rejectedTooShort);
    expect(l.phase, AbLoopPhase.aSet);
    expect(l.tap(s * 20), AbTapResult.activated);
    expect(l.isActive, true);
    expect(l.tap(s * 25), AbTapResult.cleared);
    expect(l.isIdle, true);
    expect(l.a, isNull);
  });

  test('onPosition seeks to A at B, ignores before, clears far past B', () {
    final l = AbLoop()..tap(s * 10)..tap(s * 20);
    expect(l.onPosition(s * 15).seekTo, isNull);
    expect(l.onPosition(s * 5).seekTo, isNull);
    expect(l.isActive, true);
    expect(l.onPosition(s * 20).seekTo, s * 10);
    expect(l.onPosition(const Duration(milliseconds: 20500)).seekTo, s * 10);
    final t = l.onPosition(s * 30);
    expect(t.cleared, true);
    expect(t.seekTo, isNull);
    expect(l.isIdle, true);
  });

  test('idle ignores positions', () {
    expect(AbLoop().onPosition(s * 99).seekTo, isNull);
  });

  test('semitone helpers', () {
    expect(semitonesToRatio(0), 1.0);
    expect(semitonesToRatio(12 - 12), 1.0);
    expect(semitonesToRatio(6), closeTo(1.41421, 1e-4));
    expect(semitonesToRatio(-6), closeTo(0.70711, 1e-4));
    expect(semitoneLabel(0), '0 (original)');
    expect(semitoneLabel(2), '+2 st');
    expect(semitoneLabel(-3), '-3 st');
  });
}
