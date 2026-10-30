// lib/player/visualizer.dart
//
// SIMULATED audio visualizer. The Android side exposes no FFT / Visualizer
// data (checked android/app/src/main/kotlin), so these bars are NOT derived
// from the audio signal. They are a deterministic pseudo-spectrum (layered
// sines) driven by the playback position and play state, so seeking changes
// the pattern and pausing makes the bars fall to rest.
//
// The Ticker only runs while bars are moving: it stops once playback is
// paused and the bars have settled, when motion is reduced, and it is
// muted automatically (TickerMode) when the route is not visible.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class SimulatedVisualizer extends StatefulWidget {
  final bool playing;
  final Color color;
  final int seed;
  final int bars;

  /// Current playback position, read on every frame without rebuilding.
  final ValueListenable<Duration>? position;

  const SimulatedVisualizer({
    super.key,
    required this.playing,
    required this.color,
    this.seed = 0,
    this.bars = 28,
    this.position,
  });

  @override
  State<SimulatedVisualizer> createState() => _SimulatedVisualizerState();
}

class _SimulatedVisualizerState extends State<SimulatedVisualizer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  late List<double> _levels = List<double>.filled(widget.bars, 0.04);
  final ValueNotifier<int> _frame = ValueNotifier<int>(0);
  Duration _last = Duration.zero;
  double _clock = 0; // seconds, advances only while playing
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant SimulatedVisualizer old) {
    super.didUpdateWidget(old);
    if (old.bars != widget.bars) _levels = List<double>.filled(widget.bars, 0.04);
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _syncTicker() {
    if (_reduceMotion) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }
    if (widget.playing && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
    // When paused the ticker keeps running just long enough to settle bars.
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    if (widget.playing) _clock += dt;
    final posSec = (widget.position?.value.inMilliseconds ?? 0) / 1000.0;
    var moving = false;
    final n = _levels.length;
    for (var i = 0; i < n; i++) {
      double target;
      if (widget.playing) {
        final x = i / n;
        final ph = widget.seed * 0.37 + i * 1.7;
        // low bins swing harder, like real music; position makes it seek-aware
        final env = 0.35 + 0.65 * (1 - x * 0.7);
        final a = math.sin(_clock * (2.3 + (i % 5) * 0.6) + ph);
        final b = math.sin(posSec * (1.1 + (i % 3) * 0.45) + ph * 1.3);
        final c = math.sin(_clock * 7.1 + i * 0.9 + posSec * 0.5);
        target = (0.5 + 0.28 * a + 0.2 * b + 0.12 * c).clamp(0.05, 1.0) * env;
      } else {
        target = 0.04;
      }
      // fast attack, slower release
      final k = target > _levels[i] ? 0.35 : 0.12;
      final next = _levels[i] + (target - _levels[i]) * k;
      if ((next - _levels[i]).abs() > 0.002) moving = true;
      _levels[i] = next;
    }
    _frame.value++;
    if (!widget.playing && !moving) _ticker.stop();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _BarsPainter(_levels, widget.color, _frame),
        size: Size.infinite,
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<double> levels;
  final Color color;

  _BarsPainter(this.levels, this.color, Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final gap = size.width / n * 0.35;
    final w = (size.width - gap * (n - 1)) / n;
    final paint = Paint()..color = color;
    for (var i = 0; i < n; i++) {
      final h = math.max(3.0, levels[i] * size.height);
      final x = i * (w + gap);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, size.height - h, w, h), Radius.circular(w / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) => old.color != color || !identical(old.levels, levels);
}
