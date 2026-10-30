// lib/ui/animated_nav_bar.dart
//
// Bottom navigation with a sliding pill behind the selected tab, a lifted /
// scaled selected icon, a fading label, and a raised gradient centre button
// that breathes while selected. Drop-in replacement for the
// BottomNavigationBar in songs_page.dart's shell.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../motion/motion.dart';
import '../motion/press_scale.dart';

class NavDestination {
  final IconData icon;
  final String label;
  const NavDestination(this.icon, this.label);
}

class AnimatedNavBar extends StatelessWidget {
  final List<NavDestination> destinations;
  final int currentIndex;
  final ValueChanged<int> onTap;
  final Color selectedColor;
  final Color unselectedColor;

  /// Index rendered as the raised gradient button (null = none).
  final int? centerIndex;
  final List<Color> centerColors;
  final double height;

  /// Screen-reader hint per tab, e.g. 'Tab 2 of 5'. Optional.
  final String Function(int index, int total)? tabHint;

  /// Label text is allowed to grow with the system font size up to this
  /// factor (five labels share the width); the bar grows in height with it.
  static const double maxLabelScale = 1.3;

  const AnimatedNavBar({
    super.key,
    required this.destinations,
    required this.currentIndex,
    required this.onTap,
    required this.selectedColor,
    required this.unselectedColor,
    this.centerIndex,
    this.centerColors = const [Color(0xFF4A90E2), Color(0xFFE94E77)],
    this.height = 76,
    this.tabHint,
  });

  @override
  Widget build(BuildContext context) {
    final n = destinations.length;
    // Labels scale with the system font (clamped); grow the bar to fit.
    final labelScale = MediaQuery.textScalerOf(context)
        .clamp(maxScaleFactor: maxLabelScale)
        .scale(12) /
        12;
    final barHeight = height + (labelScale - 1) * 12 * 1.25;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: maxLabelScale,
      child: SizedBox(
      height: barHeight,
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth / n;
        final pillIsCenter = currentIndex == centerIndex;
        return Stack(children: [
          // Sliding indicator pill (hidden behind the centre button).
          AnimatedPositioned(
            duration: Motion.of(context, Motion.medium),
            curve: Motion.emphasized,
            left: currentIndex * w + (w - 56) / 2,
            top: 10,
            width: 56,
            height: 32,
            child: AnimatedOpacity(
              duration: Motion.of(context, Motion.fast),
              opacity: pillIsCenter ? 0 : 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selectedColor.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Row(children: [
            for (var i = 0; i < n; i++)
              Expanded(
                child: i == centerIndex
                    ? _CenterItem(
                        dest: destinations[i],
                        selected: i == currentIndex,
                        colors: centerColors,
                        labelColor: i == currentIndex ? selectedColor : unselectedColor,
                        onTap: () => _tap(i),
                        hint: tabHint?.call(i, n),
                      )
                    : _Item(
                        dest: destinations[i],
                        selected: i == currentIndex,
                        color: i == currentIndex ? selectedColor : unselectedColor,
                        onTap: () => _tap(i),
                        hint: tabHint?.call(i, n),
                      ),
              ),
          ]),
        ]);
      }),
    ));
  }

  void _tap(int i) {
    if (i != currentIndex) HapticFeedback.selectionClick();
    onTap(i);
  }
}

class _Item extends StatelessWidget {
  final NavDestination dest;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  final String? hint;
  const _Item({required this.dest, required this.selected, required this.color, required this.onTap, this.hint});

  @override
  Widget build(BuildContext context) {
    final dur = Motion.of(context, Motion.medium);
    return Semantics(
      button: true,
      selected: selected,
      label: dest.label,
      hint: hint,
      excludeSemantics: true,
      onTap: onTap,
      child: PressScale(
        onTap: onTap,
        pressedScale: 0.9,
        child: Column(mainAxisAlignment: MainAxisAlignment.start, children: [
          const SizedBox(height: 10),
          SizedBox(
            height: 32,
            child: Center(
              child: AnimatedScale(
                duration: dur,
                curve: Motion.spring,
                scale: selected ? 1.12 : 1.0,
                child: AnimatedSlide(
                  duration: dur,
                  curve: Motion.spring,
                  offset: selected ? const Offset(0, -0.06) : Offset.zero,
                  child: Icon(dest.icon, color: color, size: 24),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          AnimatedDefaultTextStyle(
            duration: dur,
            style: TextStyle(
              fontSize: 12,
              color: color.withOpacity(selected ? 1 : 0.8),
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
            child: Text(dest.label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }
}

class _CenterItem extends StatefulWidget {
  final NavDestination dest;
  final bool selected;
  final List<Color> colors;
  final Color labelColor;
  final VoidCallback onTap;
  final String? hint;
  const _CenterItem({
    this.hint,
    required this.dest,
    required this.selected,
    required this.colors,
    required this.labelColor,
    required this.onTap,
  });

  @override
  State<_CenterItem> createState() => _CenterItemState();
}

class _CenterItemState extends State<_CenterItem> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));

  void _sync() {
    final reduced = Motion.reduced(context);
    if (widget.selected && !reduced) {
      if (!_breath.isAnimating) _breath.repeat(reverse: true);
    } else {
      _breath.stop();
      _breath.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_CenterItem old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _sync();
  }

  @override
  void dispose() {
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dur = Motion.of(context, Motion.medium);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.dest.label,
      hint: widget.hint,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: PressScale(
        onTap: widget.onTap,
        pressedScale: 0.9,
        child: Column(children: [
          const SizedBox(height: 10),
          // Lays out at a normal icon's 32px height; the 46px circle
          // overflows upward, as before.
          SizedBox(
            height: 32,
            width: 56,
            child: OverflowBox(
              maxHeight: 54,
              maxWidth: 56,
              alignment: Alignment.bottomCenter,
              child: AnimatedBuilder(
                animation: _breath,
                builder: (context, child) {
                  final glow = widget.selected ? 0.4 + 0.3 * _breath.value : 0.25;
                  return AnimatedScale(
                    duration: dur,
                    curve: Motion.spring,
                    scale: widget.selected ? 1.08 + 0.03 * _breath.value : 1.0,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: widget.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
                        border: Border.all(color: Colors.white.withOpacity(widget.selected ? 0.9 : 0.0), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: widget.colors.last.withOpacity(glow),
                            blurRadius: widget.selected ? 14 + 8 * _breath.value : 10,
                            spreadRadius: widget.selected ? 1.5 * _breath.value : 0,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: child,
                    ),
                  );
                },
                child: const Icon(Icons.headphones_rounded, color: Colors.white, size: 24),
              ),
            ),
          ),
          const SizedBox(height: 4),
          AnimatedDefaultTextStyle(
            duration: dur,
            style: TextStyle(
              fontSize: 12,
              color: widget.labelColor,
              fontWeight: widget.selected ? FontWeight.w700 : FontWeight.w500,
            ),
            child: Text(widget.dest.label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center),
          ),
        ]),
      ),
    );
  }
}
