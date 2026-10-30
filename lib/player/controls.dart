// lib/player/controls.dart
//
// Animated transport controls for the Now Playing screens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'art_colors.dart';
import 'press_scale.dart';

/// Play/pause icon that morphs between the two glyphs.
class PlayPauseIcon extends StatefulWidget {
  final bool playing;
  final Color color;
  final double size;

  const PlayPauseIcon({super.key, required this.playing, required this.color, this.size = 32});

  @override
  State<PlayPauseIcon> createState() => _PlayPauseIconState();
}

class _PlayPauseIconState extends State<PlayPauseIcon> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.playing ? 1 : 0,
  );

  @override
  void didUpdateWidget(covariant PlayPauseIcon old) {
    super.didUpdateWidget(old);
    if (old.playing != widget.playing) {
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (reduce) {
        _c.value = widget.playing ? 1 : 0;
      } else {
        widget.playing ? _c.forward() : _c.reverse();
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedIcon(
        icon: AnimatedIcons.play_pause,
        progress: _c,
        color: widget.color,
        size: widget.size,
      );
}

/// Large circular play/pause button tinted with the current accent.
class PlayPauseButton extends StatelessWidget {
  final bool playing;
  final Color accent;
  final double diameter;
  final VoidCallback onPressed;

  const PlayPauseButton({
    super.key,
    required this.playing,
    required this.accent,
    required this.onPressed,
    this.diameter = 70,
  });

  @override
  Widget build(BuildContext context) {
    final fg = ArtColors.onColor(accent);
    return PressScale(
      pressedScale: 0.92,
      semanticLabel: playing ? 'Pause' : 'Play',
      onTap: () {
        HapticFeedback.lightImpact();
        onPressed();
      },
      child: Container(
        width: diameter,
        height: diameter,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [accent, Color.lerp(accent, Colors.white, 0.28)!],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: [BoxShadow(color: accent.withOpacity(0.45), blurRadius: 20, offset: const Offset(0, 8))],
        ),
        child: Center(child: PlayPauseIcon(playing: playing, color: fg, size: diameter * 0.5)),
      ),
    );
  }
}

/// Skip / seek icon button with press-scale and haptics.
class TransportButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback? onPressed;
  final String? label;

  const TransportButton({
    super.key,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.size = 36,
    this.label,
  });

  @override
  Widget build(BuildContext context) => PressScale(
        onTap: onPressed,
        semanticLabel: label,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: Icon(icon, key: ValueKey(icon), size: size, color: color),
          ),
        ),
      );
}

/// Repeat/shuffle style toggle: the glyph cross-scales when it changes and a
/// soft accent pill fades in while active.
class AnimatedModeButton extends StatelessWidget {
  final IconData icon;
  final bool active;
  final Color accent;
  final Color inactiveColor;
  final String tooltip;
  final VoidCallback onPressed;

  const AnimatedModeButton({
    super.key,
    required this.icon,
    required this.active,
    required this.accent,
    required this.inactiveColor,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: PressScale(
        onTap: onPressed,
        semanticLabel: tooltip,
        semanticToggled: active,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? accent.withOpacity(0.18) : Colors.transparent,
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
            child: TweenAnimationBuilder<Color?>(
              key: ValueKey(icon),
              tween: ColorTween(end: active ? accent : inactiveColor),
              duration: const Duration(milliseconds: 220),
              builder: (_, c, __) => Icon(icon, size: 24, color: c),
            ),
          ),
        ),
      ),
    );
  }
}
