// lib/audio_waveform_view.dart
//
// Waveform-based trim control for the Audio Cutter: renders amplitude bars
// for the song plus two draggable Start/End markers with the selected
// region highlighted between them. Pure presentation + gesture handling —
// the caller owns the actual Duration state (audio_cutter.dart) and just
// receives onStartChanged/onEndChanged as the user drags a marker, the same
// way RangeSlider's onChanged worked before this replaced it.
//
// The waveform bars/region/marker lines are still painted on a CustomPaint
// (cheap, stateless), but the Start/End handles themselves are real
// widgets laid out in a Stack on top of it: each gets its own
// full-height, 48dp-wide hit box (well above the visual ~26dp knob) with
// its own drag recognizer, so there's no ambiguity about which marker a
// touch is grabbing and no small-circle hit-testing to get wrong.
import 'package:flutter/material.dart';
import 'app_palette.dart';

class AudioWaveformTrimmer extends StatefulWidget {
  final List<double> amplitudes; // normalized 0..1
  final Duration duration;
  final Duration start;
  final Duration end;
  final Duration? playhead;
  final bool enabled;
  final Color activeColor;
  final Color inactiveColor;
  final Color markerColor;
  final ValueChanged<Duration> onStartChanged;
  final ValueChanged<Duration> onEndChanged;

  AudioWaveformTrimmer({
    super.key,
    required this.amplitudes,
    required this.duration,
    required this.start,
    required this.end,
    required this.onStartChanged,
    required this.onEndChanged,
    this.playhead,
    this.enabled = true,
    Color? activeColor,
    Color? inactiveColor,
    Color? markerColor,
  })  : activeColor = activeColor ?? AppPalette.accent,
        inactiveColor = inactiveColor ?? AppPalette.accent.withOpacity(0.33),
        markerColor = markerColor ?? AppPalette.accent;

  @override
  State<AudioWaveformTrimmer> createState() => _AudioWaveformTrimmerState();
}

class _AudioWaveformTrimmerState extends State<AudioWaveformTrimmer> {
  // The draggable hit area is intentionally much wider than the visual knob
  // (a 48dp touch target is the standard minimum recommended for mobile),
  // so users don't have to precisely land a finger on a thin line.
  static const double _handleHitWidth = 48;
  static const double _knobSize = 26;
  static const Duration _minGap = Duration(milliseconds: 300);

  // Pixel position tracked locally for whichever handle is mid-drag, so a
  // drag is a pure running pixel offset independent of how fast
  // widget.start/end round-trip back through the parent's setState — avoids
  // jitter from reading widget.start/end (which lag one frame behind).
  double? _startDragX;
  double? _endDragX;

  double _timeToX(Duration t, double width) {
    final totalMs = widget.duration.inMilliseconds;
    if (totalMs <= 0) return 0;
    return (t.inMilliseconds / totalMs).clamp(0.0, 1.0) * width;
  }

  Duration _xToTime(double x, double width) {
    final totalMs = widget.duration.inMilliseconds;
    if (totalMs <= 0 || width <= 0) return Duration.zero;
    final ms = (x / width * totalMs).round().clamp(0, totalMs);
    return Duration(milliseconds: ms);
  }

  void _onStartDragStart(double width) {
    if (!widget.enabled) return;
    _startDragX = _timeToX(widget.start, width);
  }

  void _onStartDragUpdate(DragUpdateDetails details, double width) {
    if (!widget.enabled || _startDragX == null) return;
    _startDragX = (_startDragX! + details.delta.dx).clamp(0.0, width);
    // Start can never cross past End (with a small minimum gap so it can't
    // land directly on top of it either).
    final maxStart = widget.end - _minGap;
    var next = _xToTime(_startDragX!, width);
    if (next < Duration.zero) next = Duration.zero;
    if (next > maxStart) next = maxStart < Duration.zero ? Duration.zero : maxStart;
    widget.onStartChanged(next);
  }

  void _onEndDragStart(double width) {
    if (!widget.enabled) return;
    _endDragX = _timeToX(widget.end, width);
  }

  void _onEndDragUpdate(DragUpdateDetails details, double width) {
    if (!widget.enabled || _endDragX == null) return;
    _endDragX = (_endDragX! + details.delta.dx).clamp(0.0, width);
    // End can never cross before Start.
    final minEnd = widget.start + _minGap;
    var next = _xToTime(_endDragX!, width);
    if (next > widget.duration) next = widget.duration;
    if (next < minEnd) next = minEnd > widget.duration ? widget.duration : minEnd;
    widget.onEndChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      const height = 120.0;
      final startX = _timeToX(widget.start, width);
      final endX = _timeToX(widget.end, width);

      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _WaveformPainter(
                  amplitudes: widget.amplitudes,
                  duration: widget.duration,
                  start: widget.start,
                  end: widget.end,
                  playhead: widget.playhead,
                  activeColor: widget.activeColor,
                  inactiveColor: widget.inactiveColor,
                  markerColor: widget.markerColor,
                ),
              ),
            ),
            _handle(
              x: startX,
              height: height,
              isStart: true,
              onDragStart: () => _onStartDragStart(width),
              onDragUpdate: (d) => _onStartDragUpdate(d, width),
              onDragEnd: () => _startDragX = null,
            ),
            _handle(
              x: endX,
              height: height,
              isStart: false,
              onDragStart: () => _onEndDragStart(width),
              onDragUpdate: (d) => _onEndDragUpdate(d, width),
              onDragEnd: () => _endDragX = null,
            ),
          ],
        ),
      );
    });
  }

  Widget _handle({
    required double x,
    required double height,
    required bool isStart,
    required VoidCallback onDragStart,
    required ValueChanged<DragUpdateDetails> onDragUpdate,
    required VoidCallback onDragEnd,
  }) {
    return Positioned(
      left: x - _handleHitWidth / 2,
      top: 0,
      width: _handleHitWidth,
      height: height,
      child: Semantics(
        label: isStart ? 'Start trim handle' : 'End trim handle',
        slider: true,
        enabled: widget.enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.enabled ? (_) => onDragStart() : null,
          onHorizontalDragUpdate: widget.enabled ? onDragUpdate : null,
          onHorizontalDragEnd: widget.enabled ? (_) => onDragEnd() : null,
          onHorizontalDragCancel: widget.enabled ? onDragEnd : null,
          child: Center(
            child: Container(
              width: _knobSize,
              height: _knobSize,
              decoration: BoxDecoration(
                color: widget.enabled ? widget.markerColor : widget.markerColor.withOpacity(0.5),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1))],
              ),
              child: Icon(
                isStart ? Icons.chevron_right : Icons.chevron_left,
                color: Colors.white,
                size: 16,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final Duration duration;
  final Duration start;
  final Duration end;
  final Duration? playhead;
  final Color activeColor;
  final Color inactiveColor;
  final Color markerColor;

  _WaveformPainter({
    required this.amplitudes,
    required this.duration,
    required this.start,
    required this.end,
    required this.playhead,
    required this.activeColor,
    required this.inactiveColor,
    required this.markerColor,
  });

  double _timeToX(Duration t, double width) {
    final totalMs = duration.inMilliseconds;
    if (totalMs <= 0) return 0;
    return (t.inMilliseconds / totalMs).clamp(0.0, 1.0) * width;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty || size.width <= 0) return;

    final startX = _timeToX(start, size.width);
    final endX = _timeToX(end, size.width);

    final regionPaint = Paint()..color = activeColor.withOpacity(0.16);
    canvas.drawRect(Rect.fromLTRB(startX, 0, endX, size.height), regionPaint);

    final barCount = amplitudes.length;
    final barSlot = size.width / barCount;
    final barWidth = (barSlot * 0.7).clamp(1.0, barSlot);
    final centerY = size.height / 2;

    for (var i = 0; i < barCount; i++) {
      final x = i * barSlot + (barSlot - barWidth) / 2;
      final amp = amplitudes[i].clamp(0.04, 1.0);
      final barHeight = amp * size.height * 0.9;
      final inSelection = (x + barWidth / 2) >= startX && (x + barWidth / 2) <= endX;
      final paint = Paint()..color = inSelection ? activeColor : inactiveColor;
      final rect = Rect.fromCenter(center: Offset(x + barWidth / 2, centerY), width: barWidth, height: barHeight);
      canvas.drawRRect(RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)), paint);
    }

    final markerPaint = Paint()
      ..color = markerColor
      ..strokeWidth = 2;
    canvas.drawLine(Offset(startX, 0), Offset(startX, size.height), markerPaint);
    canvas.drawLine(Offset(endX, 0), Offset(endX, size.height), markerPaint);

    if (playhead != null) {
      final px = _timeToX(playhead!, size.width);
      final playPaint = Paint()
        ..color = Colors.orangeAccent
        ..strokeWidth = 2;
      canvas.drawLine(Offset(px, 0), Offset(px, size.height), playPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.amplitudes != amplitudes ||
        oldDelegate.start != start ||
        oldDelegate.end != end ||
        oldDelegate.playhead != playhead ||
        oldDelegate.duration != duration ||
        oldDelegate.activeColor != activeColor ||
        oldDelegate.inactiveColor != inactiveColor;
  }
}
