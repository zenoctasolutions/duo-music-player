// lib/motion/animated_gradient_hero.dart
//
// A hero card whose gradient slowly drifts. The motion is deliberately
// subtle (the gradient's begin/end alignments orbit) and stops entirely when
// animations are disabled.

import 'dart:math' as math;

import 'package:flutter/material.dart';

class AnimatedGradientHero extends StatefulWidget {
  final List<Color> colors;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Duration period;

  /// Colored drop shadow under the card (defaults to the last color).
  final Color? glowColor;

  const AnimatedGradientHero({
    super.key,
    required this.colors,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = 24,
    this.period = const Duration(seconds: 9),
    this.glowColor,
  });

  @override
  State<AnimatedGradientHero> createState() => _AnimatedGradientHeroState();
}

class _AnimatedGradientHeroState extends State<AnimatedGradientHero> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);
  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduced && _running) {
      _c.stop();
      _running = false;
    } else if (!reduced && !_running) {
      _c.repeat();
      _running = true;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        child: Padding(padding: widget.padding, child: widget.child),
        builder: (context, child) {
          final a = _c.value * 2 * math.pi;
          // Small orbit around the usual top-left -> bottom-right diagonal.
          final dx = math.cos(a) * 0.35;
          final dy = math.sin(a) * 0.35;
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: widget.colors,
                begin: Alignment(-1 + dx, -1 + dy),
                end: Alignment(1 - dx, 1 - dy),
              ),
              borderRadius: BorderRadius.circular(widget.radius),
              boxShadow: [
                BoxShadow(
                  color: (widget.glowColor ?? widget.colors.last).withOpacity(0.25),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          );
        },
      ),
    );
  }
}
