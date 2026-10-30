// lib/app_palette.dart
//
// App-wide appearance settings: the accent color, the optional pure-black
// (AMOLED) dark theme, and which bottom-nav tab the app opens on.
//
// Screens used to hard-code the blue accent (0xFF4A90E2) and the dark
// background/card greys (0xFF121212 / 0xFF1E1E1E) individually. They now
// read them from here, so one choice in Settings → Appearance recolors the
// whole app. Values are loaded once before runApp (see main.dart) and the
// root screen rebuilds on [changes].

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccentOption {
  final String name;
  final Color color;
  const AccentOption(this.name, this.color);
}

/// A multi-color gradient theme. The middle color (or the first of two) is
/// used wherever the app needs a single accent; the full list paints
/// gradient surfaces (buttons, headers, the now-playing hero, radio).
class GradientOption {
  final String name;
  final List<Color> colors;

  /// For themes whose [colors] are too dark to paint buttons/highlights with
  /// (the logo background): the gradient used for filled controls instead.
  final List<Color>? fillColors;

  /// Overrides the single accent, which defaults to the middle of [colors].
  final Color? accentColor;

  const GradientOption(this.name, this.colors, {this.fillColors, this.accentColor});

  Color get accent => accentColor ?? colors[colors.length == 3 ? 1 : 0];

  List<Color> get fill => fillColors ?? colors;
}

class AppPalette {
  AppPalette._();

  static const _kAccent = 'appearance_accent_color';
  static const _kGradient = 'appearance_gradient_index';
  static const _kAmoled = 'appearance_amoled_black';
  static const _kStartTab = 'appearance_start_tab';
  static const _kSystemColors = 'appearance_system_colors';
  static const MethodChannel _system = MethodChannel('music_app/system');

  static const Color defaultAccent = Color(0xFF4A90E2);

  static const List<AccentOption> accentOptions = [
    AccentOption('Duo Blue', defaultAccent),
    AccentOption('Violet', Color(0xFF7C4DFF)),
    AccentOption('Teal', Color(0xFF009688)),
    AccentOption('Green', Color(0xFF43A047)),
    AccentOption('Orange', Color(0xFFFB8C00)),
    AccentOption('Red', Color(0xFFE53935)),
    AccentOption('Pink', Color(0xFFE94E77)),
    AccentOption('Indigo', Color(0xFF3949AB)),
  ];

  static const List<GradientOption> gradientOptions = [
    GradientOption('Duo', [Color(0xFF4A90E2), Color(0xFF8E5CE6), Color(0xFFE94E77)]),
    GradientOption('Sunset', [Color(0xFFFF9A3C), Color(0xFFFF4E78), Color(0xFF8E3CF0)]),
    GradientOption('Ocean', [Color(0xFF22D3EE), Color(0xFF3B82F6), Color(0xFF4F46E5)]),
    GradientOption('Aurora', [Color(0xFF34D399), Color(0xFF14B8A6), Color(0xFF3B82F6)]),
    GradientOption('Neon', [Color(0xFF7C4DFF), Color(0xFFD946EF), Color(0xFFFF4DA6)]),
    GradientOption('Ember', [Color(0xFFFFB020), Color(0xFFFF6A3D), Color(0xFFE5254B)]),
    GradientOption('Lagoon', [Color(0xFF2DD4BF), Color(0xFF38BDF8)]),
    GradientOption('Midnight', [Color(0xFF312E81), Color(0xFF6D28D9), Color(0xFFDB2777)]),
    // The app icon's background (plum -> midnight -> deep blue). Appended, not
    // inserted, so saved indexes of the other themes stay valid. Buttons and
    // highlights use the icon's violet, since the background is too dark.
    GradientOption(
      'Duo Logo',
      [Color(0xFF46163A), Color(0xFF14142C), Color(0xFF122C60)],
      fillColors: [Color(0xFF9A6AE8), Color(0xFF6D4BD0)],
      accentColor: Color(0xFF9A6AE8),
    ),
  ];

  /// Index of the logo theme in [gradientOptions]; the default for new installs.
  static const int logoGradientIndex = 8;

  /// Bottom-nav destinations, in nav order (index = tab index).
  static const List<String> tabNames = ['Library', 'Radio', 'Duo', 'Converter', 'Settings'];

  static Color _accent = defaultAccent;
  static Color? _systemAccent;
  static bool _useSystemColors = false;
  static bool _systemColorsAvailable = false;
  static int _gradientIndex = -1; // -1 = solid accent
  static bool _amoled = false;
  static int _startTab = 0;

  /// Bumped on every change so listeners can rebuild.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static GradientOption? get gradientOption {
    if (_useSystemColors && _systemAccent != null) return null;
    return (_gradientIndex >= 0 && _gradientIndex < gradientOptions.length) ? gradientOptions[_gradientIndex] : null;
  }

  static int get gradientIndex => gradientOption == null ? -1 : _gradientIndex;

  /// The colors of gradient surfaces: the gradient theme's, or the accent
  /// fading to its darker shade.
  static List<Color> get gradientColors => gradientOption?.fill ?? [accent, accentDark];

  /// The logo-background gradient for large surfaces (nav bar, headers, hero
  /// cards), or null when the theme has no separate background gradient.
  static List<Color>? get backgroundGradient {
    final g = gradientOption;
    return g?.fillColors != null ? g!.colors : null;
  }

  static bool get isLogoTheme => backgroundGradient != null;

  static LinearGradient get gradient => LinearGradient(
        colors: gradientColors,
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static Color get accent {
    if (_useSystemColors && _systemAccent != null) return _systemAccent!;
    return gradientOption?.accent ?? _accent;
  }

  /// Whether the accent follows the wallpaper (Material You, Android 12+).
  static bool get useSystemColors => _useSystemColors && _systemAccent != null;
  static bool get systemColorsAvailable => _systemColorsAvailable;

  /// The user's picked accent (ignoring Material You).
  static Color get pickedAccent => _accent;

  /// A darker shade of the accent, used as the second stop of gradients
  /// (was the fixed 0xFF4178C0 alongside the default blue).
  static Color get accentDark {
    final g = gradientOption;
    if (g != null) return g.fill.last;
    final hsl = HSLColor.fromColor(accent);
    return hsl.withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0)).toColor();
  }

  /// WCAG contrast ratio (1..21) between two opaque colours.
  static double contrastRatio(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The accent, lightened just enough to read as TEXT (>= 4.5:1) on every
  /// dark surface (cards, page background and the logo gradient stops).
  /// Use for labels and links on dark surfaces; keep [accent] for fills,
  /// icons and indicators. In light mode the accent is returned unchanged.
  static Color accentText({required bool dark}) {
    final base = accent;
    if (!dark) return base;
    final surfaces = <Color>[darkCard, darkBackground, ...?backgroundGradient];
    var hsl = HSLColor.fromColor(base);
    Color c = base;
    for (var i = 0; i < 30; i++) {
      c = hsl.toColor();
      if (surfaces.every((s) => contrastRatio(c, s) >= 4.5)) return c;
      if (hsl.lightness >= 0.95) break;
      hsl = hsl.withLightness((hsl.lightness + 0.02).clamp(0.0, 0.95));
    }
    return c;
  }

  static bool get amoled => _amoled;
  static int get startTab => _startTab;

  /// Dark-mode page background (was 0xFF121212 everywhere).
  static Color get darkBackground =>
      _amoled ? Colors.black : (isLogoTheme ? const Color(0xFF0F0F1F) : const Color(0xFF121212));

  /// Dark-mode card/surface color (was 0xFF1E1E1E everywhere; now a touch
  /// lighter and cooler so cards read as elevated above the page).
  static Color get darkCard =>
      _amoled ? const Color(0xFF111113) : (isLogoTheme ? const Color(0xFF1C1C30) : const Color(0xFF212125));

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final a = prefs.getInt(_kAccent);
      if (a != null) _accent = Color(a);
      // Installs that never picked a colour get the logo theme; anyone who
      // chose an accent or gradient keeps it.
      final chose = prefs.containsKey(_kGradient) || prefs.containsKey(_kAccent);
      _gradientIndex = prefs.getInt(_kGradient) ?? (chose ? -1 : logoGradientIndex);
      _amoled = prefs.getBool(_kAmoled) ?? false;
      _startTab = (prefs.getInt(_kStartTab) ?? 0).clamp(0, tabNames.length - 1);
      _useSystemColors = prefs.getBool(_kSystemColors) ?? false;
      await refreshSystemAccent(notify: false);
    } catch (e) {
      debugPrint('AppPalette load failed: $e');
    }
  }

  /// Re-reads the wallpaper accent (call on app resume — it changes when
  /// the user changes wallpaper or theme colors).
  static Future<void> refreshSystemAccent({bool notify = true}) async {
    try {
      final v = await _system.invokeMethod<int>('getSystemAccent');
      final next = v == null ? null : Color(v);
      _systemColorsAvailable = next != null;
      if (next?.toARGB32() != _systemAccent?.toARGB32()) {
        _systemAccent = next;
        if (notify && _useSystemColors) changes.value++;
      }
    } catch (_) {
      _systemColorsAvailable = false;
    }
  }

  static Future<void> setUseSystemColors(bool v) async {
    _useSystemColors = v;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSystemColors, v);
  }

  static Future<void> setGradient(int index) async {
    _gradientIndex = index;
    _useSystemColors = false;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kGradient, index);
    await prefs.setBool(_kSystemColors, false);
  }

  static Future<void> setAccent(Color c) async {
    _accent = c;
    _gradientIndex = -1;
    _useSystemColors = false;
    (await SharedPreferences.getInstance()).setInt(_kGradient, -1);
    (await SharedPreferences.getInstance()).setBool(_kSystemColors, false);
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kAccent, c.toARGB32());
  }

  static Future<void> setAmoled(bool v) async {
    _amoled = v;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAmoled, v);
  }

  static Future<void> setStartTab(int index) async {
    _startTab = index.clamp(0, tabNames.length - 1);
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kStartTab, _startTab);
  }
}
