// lib/ui/app_page_bar.dart
//
// One header for every top-level screen (Library, Radio, Duo, Converter,
// Settings): a large, left-aligned title with consistent padding. Use it as
// `Scaffold.appBar`.

import 'package:flutter/material.dart';

import '../app_palette.dart';

class AppPageBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;

  /// Replaces the title text (e.g. a search field); the left alignment and
  /// padding stay the same.
  final Widget? titleWidget;
  final List<Widget>? actions;
  final Widget? leading;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final PreferredSizeWidget? bottom;

  const AppPageBar({
    super.key,
    required this.title,
    this.titleWidget,
    this.actions,
    this.leading,
    this.backgroundColor,
    this.foregroundColor,
    this.bottom,
  });

  static const double _height = 64;

  @override
  Size get preferredSize => Size.fromHeight(_height + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = foregroundColor ?? theme.appBarTheme.foregroundColor ?? theme.colorScheme.onSurface;
    final grad = AppPalette.backgroundGradient;
    final showGradient = AppPalette.isLogoTheme &&
        grad != null &&
        theme.brightness == Brightness.dark &&
        !AppPalette.amoled;
    return AppBar(
      flexibleSpace: showGradient
          ? DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    for (final c in grad) c.withValues(alpha: 0.4),
                  ],
                ),
              ),
            )
          : null,
      backgroundColor: backgroundColor,
      foregroundColor: fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: _height,
      centerTitle: false,
      leading: leading,
      // 20px gutter, matching the card padding used across screens.
      titleSpacing: leading == null && !Navigator.canPop(context) ? 20 : null,
      actionsPadding: const EdgeInsets.only(right: 8),
      actions: actions,
      bottom: bottom,
      title: titleWidget ??
          Text(
        title,
        style: TextStyle(color: fg, fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5),
      ),
    );
  }
}
