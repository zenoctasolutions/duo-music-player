// lib/motion/press_scale.dart
//
// Wraps any tappable child with a press-down scale (and optional haptic).
// It does not draw ink; keep your InkWell/Material inside [child] if you want
// a ripple, and leave [onTap] null on the inner widget so the tap is handled
// here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';

class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale while pressed.
  final double pressedScale;

  /// Light haptic tick on tap down.
  final bool haptic;
  final HitTestBehavior behavior;

  /// Only animate; never take part in gesture handling. Use this around a
  /// widget that already handles its own tap (ListTile/InkWell) so its ripple
  /// and tap callback keep working. A drag past the touch slop (scrolling)
  /// releases the press.
  final bool passive;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.96,
    this.haptic = false,
    this.behavior = HitTestBehavior.opaque,
    this.passive = false,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;
  Offset? _downAt;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final reduced = Motion.reduced(context);
    final scaled = AnimatedScale(
      scale: (_down && !reduced) ? widget.pressedScale : 1.0,
      duration: _down ? const Duration(milliseconds: 90) : Motion.fast,
      curve: _down ? Curves.easeOut : Motion.spring,
      child: widget.child,
    );
    if (widget.passive) {
      return Listener(
        onPointerDown: (e) {
          _downAt = e.position;
          _set(true);
        },
        onPointerMove: (e) {
          if (_down && _downAt != null && (e.position - _downAt!).distance > 12) _set(false);
        },
        onPointerUp: (_) => _set(false),
        onPointerCancel: (_) => _set(false),
        child: scaled,
      );
    }
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: enabled
          ? (_) {
              _set(true);
              if (widget.haptic) HapticFeedback.selectionClick();
            }
          : null,
      onTapCancel: () => _set(false),
      onTapUp: (_) => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: scaled,
    );
  }
}
