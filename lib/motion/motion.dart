// lib/motion/motion.dart
//
// Shared motion constants for the app. Use these instead of ad-hoc
// Durations/Curves so every animation feels like part of one system.

import 'package:flutter/material.dart';

class Motion {
  Motion._();

  // Durations
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 420);

  // Curves
  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// Overshoots slightly then settles (selected nav icon, play/pause morph).
  static const Curve spring = Cubic(0.34, 1.4, 0.64, 1.0);

  /// Time between consecutive items of a staggered entrance.
  static const Duration stagger = Duration(milliseconds: 45);

  /// True when the user (or battery saver) asked for no animation.
  static bool reduced(BuildContext context) => MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// [d], or zero when animations are disabled.
  static Duration of(BuildContext context, Duration d) => reduced(context) ? Duration.zero : d;
}
