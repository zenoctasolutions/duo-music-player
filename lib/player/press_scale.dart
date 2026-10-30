// lib/player/press_scale.dart
//
// Tap target that shrinks slightly while pressed and fires a haptic tick.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double pressedScale;
  final bool haptic;
  final String? semanticLabel;

  /// For on/off buttons (repeat, shuffle, visualizer): announced as toggled.
  final bool? semanticToggled;

  /// Minimum hit-target size (dp). 48 is the Material/TalkBack minimum.
  final double minTapSize;

  const PressScale({
    super.key,
    required this.child,
    required this.onTap,
    this.pressedScale = 0.88,
    this.haptic = true,
    this.semanticLabel,
    this.semanticToggled,
    this.minTapSize = 48,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.semanticLabel,
      toggled: widget.semanticToggled,
      // A labelled control announces its label only, not any caption text
      // drawn inside it.
      excludeSemantics: widget.semanticLabel != null,
      onTap: enabled ? widget.onTap : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _set(true) : null,
        onTapUp: enabled ? (_) => _set(false) : null,
        onTapCancel: enabled ? () => _set(false) : null,
        onTap: enabled
            ? () {
                if (widget.haptic) HapticFeedback.selectionClick();
                widget.onTap!();
              }
            : null,
        child: AnimatedScale(
          scale: _down && !reduce ? widget.pressedScale : 1.0,
          duration: const Duration(milliseconds: 110),
          curve: Curves.easeOut,
          child: widget.minTapSize > 0
              ? ConstrainedBox(
                  constraints: BoxConstraints(minWidth: widget.minTapSize, minHeight: widget.minTapSize),
                  child: Align(widthFactor: 1, heightFactor: 1, child: widget.child),
                )
              : widget.child,
        ),
      ),
    );
  }
}
