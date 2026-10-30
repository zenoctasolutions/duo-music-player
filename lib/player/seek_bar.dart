// lib/player/seek_bar.dart
//
// Progress slider + time labels. Listens to the position itself so only this
// small subtree repaints on every position tick, not the whole player.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/l10n.dart';

String formatDuration(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  if (d.inHours > 0) return '${d.inHours}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  return '${two(d.inMinutes)}:${two(d.inSeconds.remainder(60))}';
}

class NowPlayingSeekBar extends StatefulWidget {
  final ValueListenable<Duration> position;
  final Duration duration;
  final Color accent;
  final Color inactive;
  final Color labelColor;
  final void Function(Duration) onSeek;

  /// Optional A-B loop markers (A set only, or A and B).
  final Duration? loopStart;
  final Duration? loopEnd;

  const NowPlayingSeekBar({
    super.key,
    required this.position,
    required this.duration,
    required this.accent,
    required this.inactive,
    required this.labelColor,
    required this.onSeek,
    this.loopStart,
    this.loopEnd,
  });

  @override
  State<NowPlayingSeekBar> createState() => _NowPlayingSeekBarState();
}

class _NowPlayingSeekBarState extends State<NowPlayingSeekBar> with SingleTickerProviderStateMixin {
  // 0 = resting, 1 = dragging (thumb and track grow).
  late final AnimationController _grow =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 160));
  double? _dragFraction;

  @override
  void dispose() {
    _grow.dispose();
    super.dispose();
  }

  double _fractionAt(double dx, double width) => (dx / width).clamp(0.0, 1.0);

  void _start(double dx, double width) {
    HapticFeedback.selectionClick();
    _grow.forward();
    setState(() => _dragFraction = _fractionAt(dx, width));
  }

  void _update(double dx, double width) => setState(() => _dragFraction = _fractionAt(dx, width));

  void _end() {
    final f = _dragFraction;
    _grow.reverse();
    if (f != null && widget.duration > Duration.zero) {
      widget.onSeek(Duration(milliseconds: (widget.duration.inMilliseconds * f).round()));
    }
    // Keep the dragged value one frame so the thumb doesn't jump back before
    // the player reports the new position.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _dragFraction = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final labelStyle = TextStyle(
      color: widget.labelColor,
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return ValueListenableBuilder<Duration>(
      valueListenable: widget.position,
      builder: (context, pos, _) {
        final frac = _dragFraction ??
            (totalMs <= 0 ? 0.0 : (pos.inMilliseconds / totalMs).clamp(0.0, 1.0));
        final shown = _dragFraction != null
            ? Duration(milliseconds: (totalMs * _dragFraction!).round())
            : pos;
        return RepaintBoundary(
          child: Column(
            children: [
              LayoutBuilder(builder: (context, c) {
                final w = c.maxWidth;
                final l = context.l10n;
                void nudge(int seconds) {
                  if (totalMs <= 0) return;
                  final target = (pos.inMilliseconds + seconds * 1000).clamp(0, totalMs);
                  widget.onSeek(Duration(milliseconds: target));
                }

                return Semantics(
                  slider: true,
                  label: l.seekSlider,
                  value: l.seekValue(formatDuration(shown), formatDuration(widget.duration)),
                  increasedValue: l.seekValue(
                      formatDuration(Duration(milliseconds: (pos.inMilliseconds + 10000).clamp(0, totalMs))),
                      formatDuration(widget.duration)),
                  decreasedValue: l.seekValue(
                      formatDuration(Duration(milliseconds: (pos.inMilliseconds - 10000).clamp(0, totalMs))),
                      formatDuration(widget.duration)),
                  onIncrease: () => nudge(10),
                  onDecrease: () => nudge(-10),
                  excludeSemantics: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: (d) => _start(d.localPosition.dx, w),
                    onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, w),
                    onHorizontalDragEnd: (_) => _end(),
                    onHorizontalDragCancel: _end,
                    onTapDown: (d) => _start(d.localPosition.dx, w),
                    onTapUp: (_) => _end(),
                    onTapCancel: () => _grow.reverse(),
                    child: SizedBox(
                      height: 48, // 48dp touch target
                      width: w,
                      child: AnimatedBuilder(
                        animation: _grow,
                        builder: (context, _) => CustomPaint(
                          painter: _SeekPainter(
                            fraction: frac,
                            grow: Curves.easeOut.transform(_grow.value),
                            active: widget.accent,
                            inactive: widget.inactive,
                            loopStart: totalMs <= 0 || widget.loopStart == null
                                ? null
                                : (widget.loopStart!.inMilliseconds / totalMs).clamp(0.0, 1.0),
                            loopEnd: totalMs <= 0 || widget.loopEnd == null
                                ? null
                                : (widget.loopEnd!.inMilliseconds / totalMs).clamp(0.0, 1.0),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              // The slider's value already announces both times.
              ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(formatDuration(shown), style: labelStyle),
                    Text(formatDuration(widget.duration), style: labelStyle),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SeekPainter extends CustomPainter {
  final double fraction;
  final double grow;
  final Color active;
  final Color inactive;
  final double? loopStart;
  final double? loopEnd;

  _SeekPainter({
    required this.fraction,
    required this.grow,
    required this.active,
    required this.inactive,
    this.loopStart,
    this.loopEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final trackH = 4.0 + 3.0 * grow;
    final r = Radius.circular(trackH / 2);
    final left = 8.0, right = size.width - 8.0;
    final x = left + (right - left) * fraction;
    canvas.drawRRect(RRect.fromLTRBR(left, cy - trackH / 2, right, cy + trackH / 2, r), Paint()..color = inactive);
    final ls = loopStart, le = loopEnd;
    if (ls != null && le != null) {
      final xa = left + (right - left) * ls, xb = left + (right - left) * le;
      canvas.drawRRect(
          RRect.fromLTRBR(xa, cy - trackH / 2 - 3, xb, cy + trackH / 2 + 3, const Radius.circular(3)),
          Paint()..color = active.withOpacity(0.28));
    }
    canvas.drawRRect(RRect.fromLTRBR(left, cy - trackH / 2, x, cy + trackH / 2, r), Paint()..color = active);
    final tick = Paint()
      ..color = active
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    for (final f in [ls, le]) {
      if (f == null) continue;
      final tx = left + (right - left) * f;
      canvas.drawLine(Offset(tx, cy - 9), Offset(tx, cy + 9), tick);
    }
    final thumbR = 6.0 + 5.0 * grow;
    if (grow > 0) {
      canvas.drawCircle(Offset(x, cy), thumbR + 6 * grow, Paint()..color = active.withOpacity(0.18 * grow));
    }
    canvas.drawCircle(Offset(x, cy), thumbR, Paint()..color = active);
  }

  @override
  bool shouldRepaint(covariant _SeekPainter o) =>
      o.fraction != fraction || o.grow != grow || o.active != active || o.inactive != inactive ||
      o.loopStart != loopStart || o.loopEnd != loopEnd;
}
