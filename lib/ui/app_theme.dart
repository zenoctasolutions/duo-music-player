// lib/ui/app_theme.dart
//
// Builds the app's ThemeData (see main.dart). Keeps the accent-driven
// ColorScheme and AppPalette surfaces, and adds the shared shape language
// (22px cards, 24px sheets), text hierarchy and page transitions.

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import '../app_palette.dart';

class AppTheme {
  AppTheme._();

  static const double cardRadius = 22;
  static const double sheetRadius = 24;

  /// Fade-forwards on Android (Flutter's current Material 3 default feel),
  /// native slide on iOS/macOS.
  static const PageTransitionsTheme pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    },
  );

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final isDark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(seedColor: AppPalette.accent, brightness: b);
    final bg = isDark ? AppPalette.darkBackground : Colors.white;
    final card = isDark ? AppPalette.darkCard : Colors.white;
    final fg = isDark ? Colors.white : Colors.black;

    final base = ThemeData(brightness: b, useMaterial3: true);
    final text = base.textTheme;

    return ThemeData(
      brightness: b,
      useMaterial3: true,
      scaffoldBackgroundColor: bg,
      colorScheme: isDark ? scheme.copyWith(surface: AppPalette.amoled ? Colors.black : null) : scheme,
      pageTransitionsTheme: pageTransitions,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: fg,
        elevation: 0,
        // Material 3 otherwise layers a surface-tint overlay onto the
        // AppBar once content scrolls underneath it, making the bar look
        // like it changed color. All AppBars in the app inherit this
        // theme (none set their own scrolledUnderElevation), so fixing it
        // here covers every screen without duplicating the property.
        scrolledUnderElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(sheetRadius)),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(sheetRadius))),
        showDragHandle: false,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      // Text hierarchy: stronger titles, calmer body copy.
      textTheme: text.copyWith(
        headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.4),
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.35),
        labelLarge: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}
