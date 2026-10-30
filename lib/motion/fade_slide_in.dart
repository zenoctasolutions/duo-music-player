// lib/motion/fade_slide_in.dart
//
// Entrance wrapper: fades and slides its child up the first time it is
// built. Give list items an increasing [index] to stagger them. With reduced
// motion the child is shown immediately.

import 'dart:async';

import 'package:flutter/material.dart';

import 'motion.dart';

class FadeSlideIn extends StatefulWidget {
  final Widget child;

  /// Position in a staggered sequence (0 = first). Delay = index * [Motion.stagger].
  final int index;
  final Duration? delay;
  final Duration duration;

  /// Slide distance in logical pixels (positive = rises from below).
  final double offset;
  final Axis axis;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.delay,
    this.duration = Motion.slow,
    this.offset = 18,
    this.axis = Axis.vertical,
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Motion.standard);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (Motion.reduced(context)) {
      _c.value = 1;
      return;
    }
    // Cap the stagger so long lists don't make the tail wait.
    final delay = widget.delay ?? Motion.stagger * widget.index.clamp(0, 10);
    if (delay == Duration.zero) {
      _c.forward();
    } else {
      _timer = Timer(delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) {
        final v = _t.value;
        final d = (1 - v) * widget.offset;
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: widget.axis == Axis.vertical ? Offset(0, d) : Offset(d, 0),
            child: child,
          ),
        );
      },
    );
  }
}
