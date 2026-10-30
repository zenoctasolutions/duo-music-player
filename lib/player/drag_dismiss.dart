// lib/player/drag_dismiss.dart
//
// Wraps a full-screen page so a downward drag moves the content with the
// finger; releasing past a distance/velocity threshold calls [onDismiss],
// otherwise it springs back.
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

class DragToDismiss extends StatefulWidget {
  final Widget child;
  final VoidCallback onDismiss;
  final bool enabled;

  const DragToDismiss({super.key, required this.child, required this.onDismiss, this.enabled = true});

  @override
  State<DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<DragToDismiss> with SingleTickerProviderStateMixin {
  late final AnimationController _spring = AnimationController.unbounded(vsync: this);
  double _dy = 0;
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _spring.addListener(() => setState(() => _dy = _spring.value.clamp(0.0, 4000.0)));
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  void _onStart(DragStartDetails d) {
    _spring.stop();
    _dragging = true;
  }

  void _onUpdate(DragUpdateDetails d) {
    if (!_dragging) return;
    // Rubber-band if the user pushes upward past the resting position.
    final next = _dy + d.delta.dy;
    setState(() => _dy = next < 0 ? next * 0.2 : next);
  }

  void _onEnd(DragEndDetails d) {
    if (!_dragging) return;
    _dragging = false;
    final h = MediaQuery.sizeOf(context).height;
    final v = d.velocity.pixelsPerSecond.dy;
    if (_dy > h * 0.22 || v > 800) {
      widget.onDismiss(); // route animation continues from the current offset
      return;
    }
    _spring.value = _dy;
    _spring.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 320, damping: 26),
      _dy,
      0,
      v,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final h = MediaQuery.sizeOf(context).height;
    final t = (_dy / h).clamp(0.0, 1.0);
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _onStart,
      onVerticalDragUpdate: _onUpdate,
      onVerticalDragEnd: _onEnd,
      onVerticalDragCancel: () {
        _dragging = false;
        if (_dy != 0) _spring.animateWith(SpringSimulation(const SpringDescription(mass: 1, stiffness: 320, damping: 26), _dy, 0, 0));
      },
      child: Transform.translate(
        offset: Offset(0, _dy),
        child: Transform.scale(
          scale: 1 - 0.06 * t,
          alignment: Alignment.topCenter,
          child: ClipRRect(
            borderRadius: BorderRadius.vertical(top: Radius.circular(28 * (t * 6).clamp(0.0, 1.0))),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
