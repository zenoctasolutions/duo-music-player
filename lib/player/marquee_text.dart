// lib/player/marquee_text.dart
//
// Single-line text that auto-scrolls when it does not fit. Pauses at both
// ends, only animates while it actually overflows, and is driven by one
// AnimationController (no Timers), so disposal is just controller.dispose().
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextAlign textAlign;

  /// Scroll speed in logical pixels per second.
  final double velocity;
  final Duration pause;

  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.textAlign = TextAlign.start,
    this.velocity = 38,
    this.pause = const Duration(milliseconds: 1600),
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(vsync: this);
  double _overflow = 0;
  bool _reduceMotion = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// (Re)configures the loop for the current overflow; stops it when the
  /// text fits or motion is reduced.
  void _sync(double overflow, bool reduceMotion) {
    if (overflow == _overflow && reduceMotion == _reduceMotion) return;
    _overflow = overflow;
    _reduceMotion = reduceMotion;
    if (overflow <= 0 || reduceMotion) {
      _controller.stop();
      _controller.value = 0;
      return;
    }
    final scrollMs = (overflow / widget.velocity * 1000).round().clamp(600, 60000);
    final pauseMs = widget.pause.inMilliseconds;
    // hold, scroll out, hold, scroll back (faster) — one full cycle.
    _controller.duration = Duration(milliseconds: pauseMs * 2 + scrollMs + 500);
    _controller.repeat();
  }

  double _offsetAt(double t) {
    final pauseMs = widget.pause.inMilliseconds;
    final scrollMs = (_overflow / widget.velocity * 1000).round().clamp(600, 60000);
    final total = pauseMs * 2 + scrollMs + 500;
    final ms = t * total;
    if (ms < pauseMs) return 0;
    if (ms < pauseMs + scrollMs) return _overflow * Curves.easeInOut.transform((ms - pauseMs) / scrollMs);
    if (ms < pauseMs * 2 + scrollMs) return _overflow;
    return _overflow * (1 - Curves.easeInOut.transform((ms - pauseMs * 2 - scrollMs) / 500));
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(widget.style);
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        textDirection: Directionality.of(context),
        maxLines: 1,
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final textWidth = painter.width;
      final maxWidth = constraints.maxWidth;
      final overflow = math.max(0.0, textWidth - maxWidth);
      // Defer controller changes out of the build phase.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _sync(overflow, reduce);
      });

      if (overflow <= 0 || reduce) {
        return Text(
          widget.text,
          style: style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textAlign: widget.textAlign,
        );
      }
      return ClipRect(
        child: SizedBox(
          height: painter.height,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_offsetAt(_controller.value), 0),
              child: child,
            ),
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: 0,
              maxWidth: textWidth + 1,
              child: Text(widget.text, style: style, maxLines: 1, softWrap: false),
            ),
          ),
        ),
      );
    });
  }
}
