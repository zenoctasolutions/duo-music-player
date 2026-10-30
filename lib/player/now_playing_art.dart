// lib/player/now_playing_art.dart
//
// Rounded-square album art card for the full player: art-tinted shadow,
// spring scale (smaller while paused), cross-fade + slide when the track
// changes, and a horizontal swipe to skip with spring-back.
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'now_playing_route.dart';

class NowPlayingArt extends StatefulWidget {
  /// Identity of the current track; a change triggers the transition.
  final String trackKey;

  /// Slide direction for the incoming art: 1 = next (from right), -1 = previous.
  final int direction;
  final bool playing;
  final Color shadowColor;
  final String heroTag;
  final double radius;

  /// Already-built art (BoxFit.cover) for the current track.
  final Widget child;
  final VoidCallback? onSwipeNext;
  final VoidCallback? onSwipePrevious;

  const NowPlayingArt({
    super.key,
    required this.trackKey,
    required this.direction,
    required this.playing,
    required this.shadowColor,
    required this.heroTag,
    required this.child,
    this.radius = 24,
    this.onSwipeNext,
    this.onSwipePrevious,
  });

  @override
  State<NowPlayingArt> createState() => _NowPlayingArtState();
}

class _NowPlayingArtState extends State<NowPlayingArt> with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(vsync: this);
  double _dx = 0;

  @override
  void initState() {
    super.initState();
    _spring.addListener(() => setState(() => _dx = _spring.value));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onEnd(DragEndDetails d) {
    final v = d.velocity.pixelsPerSecond.dx;
    final w = context.size?.width ?? 300;
    var fired = false;
    if ((v < -450 || _dx < -w * 0.25) && widget.onSwipeNext != null) {
      HapticFeedback.selectionClick();
      widget.onSwipeNext!();
      fired = true;
    } else if ((v > 450 || _dx > w * 0.25) && widget.onSwipePrevious != null) {
      HapticFeedback.selectionClick();
      widget.onSwipePrevious!();
      fired = true;
    }
    // New art slides in via AnimatedSwitcher; just settle the card.
    _spring.value = fired ? 0 : _dx;
    if (!fired) {
      _spring.animateWith(SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 300, damping: 24),
        _dx,
        0,
        v,
      ));
    } else {
      setState(() => _dx = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final card = AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 380),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final incoming = child.key == ValueKey<String>(widget.trackKey);
        final dir = widget.direction.toDouble();
        final slide = Tween<Offset>(
          begin: Offset(incoming ? 0.25 * dir : -0.25 * dir, 0),
          end: Offset.zero,
        ).animate(anim);
        return FadeTransition(opacity: anim, child: SlideTransition(position: slide, child: child));
      },
      layoutBuilder: (current, previous) => Stack(
        fit: StackFit.expand,
        children: [...previous, if (current != null) current],
      ),
      child: DecoratedBox(
        key: ValueKey<String>(widget.trackKey),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          boxShadow: [
            BoxShadow(
              color: widget.shadowColor.withOpacity(0.5),
              blurRadius: 40,
              spreadRadius: -4,
              offset: const Offset(0, 18),
            ),
            BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 6)),
          ],
        ),
        child: ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: widget.child),
      ),
    );

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragStart: (_) => _spring.stop(),
      onHorizontalDragUpdate: (d) => setState(() => _dx += d.delta.dx * 0.6),
      onHorizontalDragEnd: _onEnd,
      child: Transform.translate(
        offset: Offset(_dx, 0),
        child: AnimatedScale(
          // Slightly pressed-in while paused, springs back when playing.
          scale: widget.playing ? 1.0 : 0.86,
          duration: reduce ? Duration.zero : const Duration(milliseconds: 250),
          curve: widget.playing ? Curves.easeOutBack : Curves.easeOut,
          child: NowPlayingHero(tag: widget.heroTag, fullRadius: widget.radius, child: card),
        ),
      ),
    );
  }
}
