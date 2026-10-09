// lib/favorite_button.dart
//
// Heart toggle used in the song lists. The icon springs (grow → overshoot
// → settle) the moment it's tapped, instead of silently swapping when the
// async favourites write finishes — the swap alone read as "nothing
// happened" (tester sheet TC6).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AnimatedFavoriteButton extends StatefulWidget {
  final bool isFavorite;
  final VoidCallback onPressed;
  final Color inactiveColor;
  final Color activeColor;
  final double? size;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  const AnimatedFavoriteButton({
    super.key,
    required this.isFavorite,
    required this.onPressed,
    required this.inactiveColor,
    this.activeColor = Colors.red,
    this.size,
    this.padding = const EdgeInsets.all(8),
    this.constraints,
  });

  @override
  State<AnimatedFavoriteButton> createState() => _AnimatedFavoriteButtonState();
}

class _AnimatedFavoriteButtonState extends State<AnimatedFavoriteButton> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  // 1 → 1.35 → 0.9 → 1: a quick pop with a small rebound.
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
    TweenSequenceItem(tween: Tween(begin: 1.35, end: 0.9).chain(CurveTween(curve: Curves.easeInOut)), weight: 30),
    TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 35),
  ]).animate(_controller);

  /// Shown state: flips on tap right away, then follows [widget.isFavorite]
  /// once the parent has saved it.
  late bool _shown = widget.isFavorite;

  @override
  void didUpdateWidget(covariant AnimatedFavoriteButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isFavorite != widget.isFavorite) _shown = widget.isFavorite;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onTap() {
    HapticFeedback.lightImpact();
    setState(() => _shown = !_shown);
    _controller.forward(from: 0);
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _onTap,
      padding: widget.padding,
      constraints: widget.constraints,
      tooltip: _shown ? 'Remove from favorites' : 'Add to favorites',
      icon: ScaleTransition(
        scale: _scale,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
          child: Icon(
            _shown ? Icons.favorite : Icons.favorite_border,
            key: ValueKey(_shown),
            size: widget.size,
            color: _shown ? widget.activeColor : widget.inactiveColor,
          ),
        ),
      ),
    );
  }
}
