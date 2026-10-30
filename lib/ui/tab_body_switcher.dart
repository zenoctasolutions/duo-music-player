// lib/ui/tab_body_switcher.dart
//
// Shows one of several tab bodies with a Material fade-through (package
// `animations`) while KEEPING every visited tab alive in an IndexedStack, so
// scroll positions and state survive a tab switch. Tabs are built lazily on
// first visit.

import 'package:animations/animations.dart';
import 'package:flutter/material.dart';

import '../motion/motion.dart';

class TabBodySwitcher extends StatefulWidget {
  final int index;
  final List<WidgetBuilder> builders;

  const TabBodySwitcher({super.key, required this.index, required this.builders});

  @override
  State<TabBodySwitcher> createState() => _TabBodySwitcherState();
}

class _TabBodySwitcherState extends State<TabBodySwitcher> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Motion.medium, value: 1);
  late final Set<int> _built = {widget.index};

  @override
  void didUpdateWidget(TabBodySwitcher old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _built.add(widget.index);
      if (Motion.reduced(context)) {
        _c.value = 1;
      } else {
        _c.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeThroughTransition(
      animation: _c,
      secondaryAnimation: kAlwaysDismissedAnimation,
      fillColor: Colors.transparent,
      child: IndexedStack(
        index: widget.index,
        sizing: StackFit.expand,
        children: [
          for (var i = 0; i < widget.builders.length; i++)
            _built.contains(i) ? widget.builders[i](context) : const SizedBox.shrink(),
        ],
      ),
    );
  }
}
