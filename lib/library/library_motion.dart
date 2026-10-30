// lib/library/library_motion.dart
//
// Shared motion for the Library area: a one-shot staggered entrance for list
// rows / cards and the animated "now playing" equalizer bars. Everything
// respects reduced motion (MediaQuery.disableAnimations) and never replays
// on scroll or rebuild.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

class LibraryMotion {
  LibraryMotion._();

  /// Only the first rows of a list stagger in, so long lists stay fast.
  static const int staggerCap = 12;
  static const Duration staggerStep = Duration(milliseconds: 35);

  static bool reduced(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// Keys that already played their entrance (survives rows being scrolled
  /// out and rebuilt). Cleared per list via [reset].
  static final Set<String> _played = <String>{};
  static void reset([String? prefix]) {
    if (prefix == null) {
      _played.clear();
    } else {
      _played.removeWhere((k) => k.startsWith(prefix));
    }
  }
}

/// Fades + slides [child] in once, delayed by [index] (capped). Rows past
/// [LibraryMotion.staggerCap], rows that already played, and reduced-motion
/// users get [child] untouched.
class StaggerIn extends StatefulWidget {
  /// Unique per row (e.g. "songs:/path/a.mp3") so each plays at most once.
  final String playKey;
  final int index;
  final Widget child;

  const StaggerIn({
    super.key,
    required this.playKey,
    required this.index,
    required this.child,
  });

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn> {
  bool? _play;

  @override
  Widget build(BuildContext context) {
    _play ??=
        widget.index < LibraryMotion.staggerCap &&
        !LibraryMotion.reduced(context) &&
        LibraryMotion._played.add(widget.playKey);
    if (_play != true) return widget.child;
    return widget.child
        .animate(delay: LibraryMotion.staggerStep * widget.index)
        .fadeIn(duration: 260.ms, curve: Curves.easeOut)
        .slideY(
          begin: 0.12,
          end: 0,
          duration: 260.ms,
          curve: Curves.easeOutCubic,
        );
  }
}

/// Three bouncing bars shown on the active row. Animates only while
/// [playing] (and motion is allowed); otherwise draws static bars.
class EqualizerBars extends StatefulWidget {
  final Color color;
  final bool playing;
  final double size;

  const EqualizerBars({
    super.key,
    required this.color,
    required this.playing,
    this.size = 20,
  });

  @override
  State<EqualizerBars> createState() => _EqualizerBarsState();
}

class _EqualizerBarsState extends State<EqualizerBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  bool _animating = false;

  void _sync(bool shouldAnimate) {
    if (shouldAnimate == _animating) return;
    _animating = shouldAnimate;
    if (shouldAnimate) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _sync(widget.playing && !LibraryMotion.reduced(context));
    return ExcludeSemantics(
      child: RepaintBoundary(
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              double h(double phase) {
                if (!_animating) return 0.5;
                return 0.25 +
                    0.75 *
                        (0.5 +
                            0.5 *
                                math.sin(
                                  (_controller.value + phase) * 2 * math.pi,
                                ));
              }

              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final phase in const [0.0, 0.33, 0.66])
                    Container(
                      width: widget.size * 0.2,
                      height: widget.size * h(phase),
                      decoration: BoxDecoration(
                        color: widget.color,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
