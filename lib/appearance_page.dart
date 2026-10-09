// lib/appearance_page.dart
//
// Settings → Appearance: gradient themes, accent color, pure-black (AMOLED) dark theme and
// the screen the app opens on. Backed by AppPalette (app_palette.dart).

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'settings_page.dart' show SettingsColors;
import 'artwork_service.dart';
import 'ad_widgets.dart';

class AppearancePage extends StatefulWidget {
  final bool isDark;
  const AppearancePage({super.key, required this.isDark});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  SettingsColors get c => SettingsColors(widget.isDark);

  Widget _card({required Widget child}) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: c.cardColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: c.divider),
        ),
        child: child,
      );

  Widget _heading(String title, String subtitle) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700, fontSize: 16)),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: c.secondaryText, fontSize: 13)),
        const SizedBox(height: 14),
      ]);

  Widget _gradientSwatch(int i) {
    final opt = AppPalette.gradientOptions[i];
    final selected = AppPalette.gradientIndex == i;
    return Semantics(
      label: '${opt.name} gradient',
      selected: selected,
      button: true,
      child: GestureDetector(
        onTap: () => AppPalette.setGradient(selected ? -1 : i),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 72,
            height: 46,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: opt.colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? c.primaryText : Colors.transparent, width: 3),
              boxShadow: [BoxShadow(color: opt.accent.withOpacity(0.35), blurRadius: 8, offset: const Offset(0, 3))],
            ),
            child: selected ? const Icon(Icons.check_rounded, color: Colors.white) : null,
          ),
          const SizedBox(height: 6),
          Text(opt.name, style: TextStyle(color: c.secondaryText, fontSize: 11)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AppPalette.changes,
      builder: (context, _, __) => Scaffold(
        bottomNavigationBar: const BannerAdWidget(),
        backgroundColor: c.backgroundColor,
        appBar: AppBar(
          title: const Text('Appearance'),
          backgroundColor: c.appBarBackground,
          foregroundColor: c.appBarForeground,
          elevation: 0,
        ),
        body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          if (AppPalette.systemColorsAvailable)
            _card(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: AppPalette.useSystemColors,
                activeColor: AppPalette.accent,
                secondary: Icon(Icons.wallpaper_rounded, color: AppPalette.accent),
                title: Text('Match wallpaper (Material You)', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700)),
                subtitle: Text('Use your phone\'s wallpaper color as the accent. Picking a color below turns this off.',
                    style: TextStyle(color: c.secondaryText, fontSize: 13)),
                onChanged: (v) => AppPalette.setUseSystemColors(v),
              ),
            ),
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _heading('Gradient themes', 'Multi-color gradients for buttons, headers, the player and radio. Tap the selected one again to go back to a solid color.'),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (var i = 0; i < AppPalette.gradientOptions.length; i++)
                    _gradientSwatch(i),
                ],
              ),
            ]),
          ),
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _heading('Accent color', 'Used for buttons, highlights, the seek bar and the now-playing screen.'),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final opt in AppPalette.accentOptions)
                    Semantics(
                      label: opt.name,
                      selected: (!AppPalette.useSystemColors && AppPalette.pickedAccent.toARGB32() == opt.color.toARGB32()),
                      button: true,
                      child: GestureDetector(
                        onTap: () => AppPalette.setAccent(opt.color),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: opt.color,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: (!AppPalette.useSystemColors && AppPalette.pickedAccent.toARGB32() == opt.color.toARGB32()) ? c.primaryText : Colors.transparent,
                                width: 3,
                              ),
                              boxShadow: [BoxShadow(color: opt.color.withOpacity(0.35), blurRadius: 8, offset: const Offset(0, 3))],
                            ),
                            child: (!AppPalette.useSystemColors && AppPalette.pickedAccent.toARGB32() == opt.color.toARGB32())
                                ? const Icon(Icons.check_rounded, color: Colors.white)
                                : null,
                          ),
                          const SizedBox(height: 6),
                          Text(opt.name, style: TextStyle(color: c.secondaryText, fontSize: 11)),
                        ]),
                      ),
                    ),
                ],
              ),
            ]),
          ),
          _card(
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: AppPalette.amoled,
              activeColor: AppPalette.accent,
              title: Text('Pure black dark theme', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'True black (AMOLED) backgrounds in dark mode — saves battery on OLED screens. '
                'Light/dark still follows your system setting.',
                style: TextStyle(color: c.secondaryText, fontSize: 13),
              ),
              onChanged: (v) => AppPalette.setAmoled(v),
            ),
          ),
          _card(
            child: FutureBuilder(
              future: ArtworkService.instance.load(),
              builder: (context, _) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: ArtworkService.instance.enabled,
                activeColor: AppPalette.accent,
                secondary: Icon(Icons.image_search_rounded, color: AppPalette.accent),
                title: Text('Download missing album art', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700)),
                subtitle: Text(
                  'For songs without a cover, look up the album online (iTunes) and save the art on your phone. '
                  'Needs artist tags; about 60 KB per album.',
                  style: TextStyle(color: c.secondaryText, fontSize: 13),
                ),
                onChanged: (v) async {
                  await ArtworkService.instance.setEnabled(v);
                  setState(() {});
                },
              ),
            ),
          ),
          _card(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _heading('Start screen', 'Which tab the app opens on.'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < AppPalette.tabNames.length; i++)
                    ChoiceChip(
                      label: Text(AppPalette.tabNames[i]),
                      selected: AppPalette.startTab == i,
                      selectedColor: AppPalette.accent.withOpacity(0.18),
                      labelStyle: TextStyle(
                        color: AppPalette.startTab == i ? AppPalette.accent : c.primaryText,
                        fontWeight: AppPalette.startTab == i ? FontWeight.w700 : FontWeight.normal,
                      ),
                      onSelected: (_) => AppPalette.setStartTab(i),
                    ),
                ],
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
