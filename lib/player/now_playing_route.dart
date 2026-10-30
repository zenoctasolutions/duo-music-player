// lib/player/now_playing_route.dart
//
// Route + Hero helpers for opening the full player from the mini-player.
//
// Callers that push FullScreenPlayer should use [nowPlayingRoute] instead of
// MaterialPageRoute: it is non-opaque (so the screen underneath stays visible
// while the player is dragged down) and slides/fades in alongside the art
// Hero. Falling back to MaterialPageRoute still works — the player's own
// drag-to-dismiss and Hero keep working there.
import 'package:flutter/material.dart';

Route<T> nowPlayingRoute<T>(WidgetBuilder builder) {
  return PageRouteBuilder<T>(
    opaque: false,
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 380),
    reverseTransitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (context, _, __) => builder(context),
    transitionsBuilder: (context, animation, secondary, child) {
      if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
        return FadeTransition(opacity: animation, child: child);
      }
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: const Interval(0.0, 0.6)),
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0, 0.12), end: Offset.zero).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Hero for the album art whose rounded corners morph between the mini
/// player's radius and the full player's radius during the flight. Put the
/// rounding *outside* this widget (the flight draws its own clip).
class NowPlayingHero extends StatelessWidget {
  final String tag;
  final Widget child;
  final double miniRadius;
  final double fullRadius;

  const NowPlayingHero({
    super.key,
    required this.tag,
    required this.child,
    this.miniRadius = 12,
    this.fullRadius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Hero(
      tag: tag,
      flightShuttleBuilder: (ctx, animation, direction, fromCtx, toCtx) {
        final dest = (direction == HeroFlightDirection.push ? toCtx : fromCtx).widget as Hero;
        return AnimatedBuilder(
          animation: animation,
          builder: (context, _) {
            final r = Tween<double>(begin: miniRadius, end: fullRadius)
                .transform(Curves.easeInOut.transform(animation.value.clamp(0.0, 1.0)));
            return ClipRRect(borderRadius: BorderRadius.circular(r), child: dest.child);
          },
        );
      },
      child: child,
    );
  }
}
