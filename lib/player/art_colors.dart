// lib/player/art_colors.dart
//
// Colours derived from cover art (via palette_generator, already a project
// dependency) and the clamps that keep text/controls readable on top of them.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class ArtColors {
  ArtColors._();

  // Small bounded cache: cover bytes -> extracted base colour (null = none).
  static final Map<int, Color?> _cache = <int, Color?>{};
  static final Map<int, Future<Color?>> _inflight = <int, Future<Color?>>{};

  static int _key(Uint8List b) {
    var h = b.length;
    final step = (b.length ~/ 64).clamp(1, 1 << 20);
    for (var i = 0; i < b.length; i += step) {
      h = 0x1fffffff & (h * 31 + b[i]);
    }
    return h;
  }

  /// Synchronous lookup; null when not extracted yet (or art has no colour).
  static Color? peek(Uint8List? cover) {
    if (cover == null || cover.isEmpty) return null;
    return _cache[_key(cover)];
  }

  /// Extracts (once per cover) the most vibrant colour. Never throws.
  static Future<Color?> extract(Uint8List? cover) {
    if (cover == null || cover.isEmpty) return Future.value(null);
    final k = _key(cover);
    if (_cache.containsKey(k)) return Future.value(_cache[k]);
    return _inflight[k] ??= PaletteGenerator.fromImageProvider(
      MemoryImage(cover),
      size: const Size(100, 100),
      maximumColorCount: 12,
    ).then<Color?>((palette) {
      final c = palette.vibrantColor?.color ??
          palette.lightVibrantColor?.color ??
          palette.dominantColor?.color ??
          palette.mutedColor?.color;
      if (_cache.length > 40) _cache.remove(_cache.keys.first);
      _cache[k] = c;
      return c;
    }).catchError((_) => null).whenComplete(() => _inflight.remove(k));
  }

  /// Accent for controls: saturated and inside a lightness band that stays
  /// legible on the (clamped) background. Near-greyscale art keeps [fallback].
  static Color accent(Color base, {required bool dark, required Color fallback}) {
    final hsl = HSLColor.fromColor(base);
    if (hsl.saturation < 0.14) return fallback;
    final s = hsl.saturation.clamp(0.45, 0.95).toDouble();
    final l = dark ? hsl.lightness.clamp(0.58, 0.74).toDouble() : hsl.lightness.clamp(0.30, 0.46).toDouble();
    return hsl.withSaturation(s).withLightness(l).toColor();
  }

  /// Top colour of the screen gradient. Lightness is clamped hard so white
  /// (dark mode) / navy (light mode) text keeps contrast even on bright art.
  static Color gradientTop(Color base, {required bool dark}) {
    final hsl = HSLColor.fromColor(base);
    final s = hsl.saturation.clamp(0.0, 0.7).toDouble();
    return hsl.withSaturation(s).withLightness(dark ? 0.24 : 0.86).toColor();
  }

  /// Readable foreground (icon/text) on top of a solid [bg].
  static Color onColor(Color bg) =>
      ThemeData.estimateBrightnessForColor(bg) == Brightness.dark ? Colors.white : const Color(0xFF15131F);
}
