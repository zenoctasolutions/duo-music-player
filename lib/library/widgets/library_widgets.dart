// lib/library/widgets/library_widgets.dart
//
// Shared building blocks for the Albums and Artists screens: cover / avatar
// with a tinted placeholder, art-derived tint, restyled search field, shimmer
// skeletons, empty state, Play/Shuffle buttons and a remembered grid/list
// preference. Everything respects AppPalette and reduced motion.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shimmer/shimmer.dart';

import '../../app_palette.dart';
import '../../player/art_colors.dart';

/// Surface colours for the library screens, following dark / AMOLED / light.
class LibColors {
  final bool dark;
  final Color bg;
  final Color card;
  final Color text;
  final Color sub;
  final Color accent;

  LibColors._(this.dark, this.bg, this.card, this.text, this.sub, this.accent);

  factory LibColors.of(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LibColors._(
      dark,
      dark ? AppPalette.darkBackground : Colors.white,
      dark ? AppPalette.darkCard : const Color(0xFFF4F5F8),
      dark ? Colors.white : const Color(0xFF15131F),
      dark ? Colors.white60 : Colors.black54,
      AppPalette.accent,
    );
  }
}

/// Remembered grid/list choice per screen.
class LibViewPref {
  static Future<bool> loadGrid(String key, {bool fallback = true}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  static Future<void> saveGrid(String key, bool grid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, grid);
    } catch (_) {}
  }
}

String formatDuration(Duration d, {bool words = false}) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  if (words) {
    if (h > 0) return '$h hr $m min';
    return '${d.inMinutes} min';
  }
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '${d.inMinutes}:$ss';
}

/// Square (or circular) cover with a tinted gradient placeholder. The image is
/// decoded at [cacheSize] px, never at full resolution.
class LibCover extends StatelessWidget {
  final Uint8List? bytes;
  final double? size;
  final double radius;
  final bool circle;
  final String seed;

  /// When set (and there is no image) draws this letter instead of a note.
  final String? initial;
  final IconData icon;
  final int cacheSize;
  final bool shadow;

  const LibCover({
    super.key,
    required this.bytes,
    required this.seed,
    this.size,
    this.radius = 14,
    this.circle = false,
    this.initial,
    this.icon = Icons.music_note_rounded,
    this.cacheSize = 300,
    this.shadow = false,
  });

  static List<Color> gradientFor(String seed) {
    var h = 0;
    for (final c in seed.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = (h % 360).toDouble();
    final accentHue = HSLColor.fromColor(AppPalette.accent).hue;
    final a = HSLColor.fromAHSL(1, (hue * 0.5 + accentHue * 0.5) % 360, 0.45, 0.38).toColor();
    final b = HSLColor.fromAHSL(1, (hue + 40) % 360, 0.5, 0.24).toColor();
    return [a, b];
  }

  @override
  Widget build(BuildContext context) {
    final has = bytes != null && bytes!.isNotEmpty;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: gradientFor(seed)),
      ),
      child: LayoutBuilder(builder: (context, c) {
        final s = c.biggest.shortestSide;
        final fs = (s.isFinite ? s : 60.0) * 0.42;
        return Center(
          child: initial != null && initial!.isNotEmpty
              ? Text(initial!,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.92), fontSize: fs, fontWeight: FontWeight.w800))
              : Icon(icon, color: Colors.white.withValues(alpha: 0.75), size: fs),
        );
      }),
    );
    final BorderRadius br = BorderRadius.circular(circle ? 9999 : radius);
    final child = ClipRRect(
      borderRadius: br,
      child: has
          ? Image.memory(
              bytes!,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              cacheWidth: cacheSize,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              excludeFromSemantics: true,
              errorBuilder: (_, __, ___) => placeholder,
            )
          : placeholder,
    );
    final decorated = shadow
        ? DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: br,
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 18, offset: const Offset(0, 8)),
              ],
            ),
            child: child,
          )
        : child;
    if (size == null) return decorated;
    return SizedBox(width: size, height: size, child: decorated);
  }
}

/// Resolves the art-derived base colour (null until extracted / when none).
class ArtTint extends StatefulWidget {
  final Uint8List? bytes;
  final Widget Function(BuildContext context, Color? base) builder;
  const ArtTint({super.key, required this.bytes, required this.builder});

  @override
  State<ArtTint> createState() => _ArtTintState();
}

class _ArtTintState extends State<ArtTint> {
  Color? _color;

  @override
  void initState() {
    super.initState();
    _color = ArtColors.peek(widget.bytes);
    _resolve();
  }

  @override
  void didUpdateWidget(covariant ArtTint old) {
    super.didUpdateWidget(old);
    if (!identical(old.bytes, widget.bytes)) {
      _color = ArtColors.peek(widget.bytes);
      _resolve();
    }
  }

  Future<void> _resolve() async {
    if (_color != null) return;
    final c = await ArtColors.extract(widget.bytes);
    if (!mounted || c == null) return;
    setState(() => _color = c);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _color);
}

/// Soft top-to-background gradient used behind detail heroes.
class HeroGradient extends StatelessWidget {
  final Color? base;
  final LibColors colors;
  final double height;
  const HeroGradient({super.key, required this.base, required this.colors, this.height = 520});

  @override
  Widget build(BuildContext context) {
    final top = base != null
        ? ArtColors.gradientTop(base!, dark: colors.dark)
        : Color.alphaBlend(colors.accent.withValues(alpha: colors.dark ? 0.28 : 0.18), colors.bg);
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: height,
      child: IgnorePointer(
        child: TweenAnimationBuilder<Color?>(
          tween: ColorTween(end: top),
          duration: (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
              ? Duration.zero
              : const Duration(milliseconds: 500),
          builder: (context, c, _) => DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [c ?? top, colors.bg],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class LibSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final LibColors colors;
  const LibSearchField({super.key, required this.controller, required this.hint, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        style: TextStyle(color: colors.text, fontSize: 16),
        cursorColor: colors.accent,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: colors.sub),
          filled: true,
          fillColor: colors.dark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.05),
          prefixIcon: Icon(Icons.search_rounded, color: colors.sub),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (_, v, __) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear',
                    icon: Icon(Icons.close_rounded, color: colors.sub),
                    onPressed: controller.clear,
                  ),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
        ),
      ),
    );
  }
}

class LibEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final LibColors colors;
  const LibEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.colors,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(shape: BoxShape.circle, color: colors.accent.withValues(alpha: 0.14)),
              child: Icon(icon, size: 44, color: colors.accent),
            ),
            const SizedBox(height: 20),
            Text(title,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.text, fontSize: 20, fontWeight: FontWeight.w700)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: TextStyle(color: colors.sub, fontSize: 15)),
            ],
            if (onAction != null) ...[
              const SizedBox(height: 20),
              FilledButton(
                onPressed: onAction,
                style: FilledButton.styleFrom(
                    backgroundColor: colors.accent,
                    foregroundColor: ArtColors.onColor(colors.accent),
                    minimumSize: const Size(48, 48)),
                child: Text(actionLabel ?? 'Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shimmering skeleton for a grid (cover + two text lines) or a list.
class LibSkeleton extends StatelessWidget {
  final bool grid;
  final bool circle;
  final LibColors colors;
  const LibSkeleton({super.key, required this.grid, required this.colors, this.circle = false});

  @override
  Widget build(BuildContext context) {
    final base = colors.dark ? const Color(0xFF2A2A30) : const Color(0xFFE4E6EB);
    final hi = colors.dark ? const Color(0xFF3A3A42) : const Color(0xFFF4F5F8);
    final reduced = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    Widget bar(double w, double h) => Container(
        width: w, height: h, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6)));
    Widget content;
    if (grid) {
      content = GridView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, mainAxisSpacing: 18, crossAxisSpacing: 16, childAspectRatio: 0.8),
        itemCount: 6,
        itemBuilder: (_, __) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: base,
                  shape: circle ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: circle ? null : BorderRadius.circular(22),
                ),
                child: const SizedBox.expand(),
              ),
            ),
            const SizedBox(height: 10),
            bar(110, 12),
            const SizedBox(height: 6),
            bar(70, 10),
          ],
        ),
      );
    } else {
      content = ListView.builder(
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        itemCount: 8,
        itemBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: base,
                shape: circle ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: circle ? null : BorderRadius.circular(14),
              ),
            ),
            const SizedBox(width: 14),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [bar(150, 13), const SizedBox(height: 8), bar(90, 10)]),
          ]),
        ),
      );
    }
    if (reduced) return ExcludeSemantics(child: content);
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(child: Shimmer.fromColors(baseColor: base, highlightColor: hi, child: content)),
    );
  }
}

/// Prominent Play + Shuffle pair for detail heroes.
class PlayShuffleRow extends StatelessWidget {
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final LibColors colors;
  const PlayShuffleRow({super.key, required this.onPlay, required this.onShuffle, required this.colors});

  @override
  Widget build(BuildContext context) {
    final fg = ArtColors.onColor(colors.accent);
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            label: 'Play',
            child: FilledButton.icon(
              onPressed: onPlay,
              style: FilledButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: fg,
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
              ),
              icon: const Icon(Icons.play_arrow_rounded, size: 26),
              label: const Text('Play', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Semantics(
            button: true,
            label: 'Shuffle',
            child: OutlinedButton.icon(
              onPressed: onShuffle,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.text,
                side: BorderSide(color: colors.text.withValues(alpha: 0.28)),
                minimumSize: const Size.fromHeight(52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
              ),
              icon: const Icon(Icons.shuffle_rounded, size: 22),
              label: const Text('Shuffle', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
            ),
          ),
        ),
      ],
    );
  }
}

/// Grid/list toggle button for app bars.
class ViewToggleButton extends StatelessWidget {
  final bool grid;
  final VoidCallback onPressed;
  final Color color;
  const ViewToggleButton({super.key, required this.grid, required this.onPressed, required this.color});

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: grid ? 'Show as list' : 'Show as grid',
        icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded, color: color),
        onPressed: onPressed,
      );
}
