// lib/sound_effects_page.dart
//
// Sound effects (bass boost, virtualizer, loudness) and volume
// normalization settings. Opened from Settings and from the Equalizer.

import 'dart:io';

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'audio_effects_service.dart';
import 'settings_page.dart' show SettingsColors;
import 'crossfade_service.dart';
import 'ad_widgets.dart';

class SoundEffectsPage extends StatefulWidget {
  final bool isDark;

  /// Library songs, for "Analyze library" (optional).
  final List<File> audioFiles;
  const SoundEffectsPage({super.key, required this.isDark, this.audioFiles = const []});

  @override
  State<SoundEffectsPage> createState() => _SoundEffectsPageState();
}

class _SoundEffectsPageState extends State<SoundEffectsPage> {
  final fx = AudioEffectsService.instance;
  SettingsColors get c => SettingsColors(widget.isDark);

  bool _analyzing = false;
  int _done = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    fx.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Widget _card(Widget child) => Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
        decoration: BoxDecoration(color: c.cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.divider)),
        child: child,
      );

  Widget _effectSlider({
    required IconData icon,
    required String title,
    required String subtitle,
    required double value,
    required double max,
    required String Function(double) label,
    required bool supported,
    required ValueChanged<double> onChangeEnd,
  }) {
    final accent = AppPalette.accent;
    return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: supported ? accent : c.tertiaryText),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700, fontSize: 15)),
            Text(supported ? subtitle : 'Not supported on this device',
                style: TextStyle(color: c.secondaryText, fontSize: 12)),
          ]),
        ),
        Text(value <= 0 ? 'Off' : label(value),
            style: TextStyle(color: value <= 0 ? c.tertiaryText : accent, fontWeight: FontWeight.w700)),
      ]),
      _LiveSlider(
        value: value,
        max: max,
        enabled: supported,
        color: accent,
        onChangeEnd: onChangeEnd,
        onChanged: (_) {},
      ),
    ]));
  }

  Future<void> _analyze() async {
    final paths = widget.audioFiles.map((f) => f.path).toList();
    if (paths.isEmpty) return;
    setState(() {
      _analyzing = true;
      _done = 0;
      _total = paths.length;
    });
    await fx.analyzeAll(paths, onProgress: (d, t) {
      if (mounted) setState(() => _done = d);
    });
    if (mounted) setState(() => _analyzing = false);
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.accent;
    return ValueListenableBuilder<int>(
      valueListenable: fx.changes,
      builder: (context, _, __) => Scaffold(
        bottomNavigationBar: const BannerAdWidget(),
        backgroundColor: c.backgroundColor,
        appBar: AppBar(
          title: const Text('Sound effects'),
          backgroundColor: c.appBarBackground,
          foregroundColor: c.appBarForeground,
          elevation: 0,
        ),
        body: ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
          _effectSlider(
            icon: Icons.speaker_rounded,
            title: 'Bass boost',
            subtitle: 'Stronger low end',
            value: fx.bass.toDouble(),
            max: 1000,
            label: (v) => '${(v / 10).round()}%',
            supported: fx.bassSupported,
            onChangeEnd: (v) => fx.setBass(v.round()),
          ),
          _effectSlider(
            icon: Icons.surround_sound_rounded,
            title: 'Virtualizer',
            subtitle: 'Wider, 3D-like stereo — best with headphones',
            value: fx.virtualizer.toDouble(),
            max: 1000,
            label: (v) => '${(v / 10).round()}%',
            supported: fx.virtualizerSupported,
            onChangeEnd: (v) => fx.setVirtualizer(v.round()),
          ),
          _effectSlider(
            icon: Icons.volume_up_rounded,
            title: 'Loudness boost',
            subtitle: 'Louder output without clipping — great for quiet songs',
            value: fx.loudnessMb.toDouble(),
            max: 1000,
            label: (v) => '+${(v / 100).toStringAsFixed(1)} dB',
            supported: fx.loudnessSupported,
            onChangeEnd: (v) => fx.setLoudness(v.round()),
          ),
          ValueListenableBuilder<int>(
            valueListenable: CrossfadeService.instance.changes,
            builder: (context, _, __) {
              final secs = CrossfadeService.instance.crossfadeSeconds;
              return _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.compare_arrows_rounded, color: accent),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Crossfade', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700, fontSize: 15)),
                      Text('Blend the end of one song into the start of the next', style: TextStyle(color: c.secondaryText, fontSize: 12)),
                    ]),
                  ),
                  Text(secs == 0 ? 'Off' : '$secs s', style: TextStyle(color: secs == 0 ? c.tertiaryText : accent, fontWeight: FontWeight.w700)),
                ]),
                Slider(
                  value: secs.toDouble(),
                  max: CrossfadeService.maxSeconds.toDouble(),
                  divisions: CrossfadeService.maxSeconds,
                  activeColor: accent,
                  label: secs == 0 ? 'Off' : '$secs s',
                  onChanged: (v) => CrossfadeService.instance.setSeconds(v.round()),
                ),
                Text('Off = gapless playback. Not used for radio or repeat-one.',
                    style: TextStyle(color: c.tertiaryText, fontSize: 11)),
              ]));
            },
          ),
          _card(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: fx.normalize,
              activeColor: accent,
              secondary: Icon(Icons.equalizer_rounded, color: accent),
              title: Text('Volume normalization', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700)),
              subtitle: Text(
                'Plays every song at a similar loudness (ReplayGain). Uses the song\'s ReplayGain tag, '
                'or measures it once on first play.',
                style: TextStyle(color: c.secondaryText, fontSize: 12),
              ),
              onChanged: (v) => fx.setNormalize(v),
            ),
            if (fx.normalize) ...[
              const SizedBox(height: 4),
              Text(
                'Current song: ${fx.currentGainDb >= 0 ? '+' : ''}${fx.currentGainDb.toStringAsFixed(1)} dB  ·  '
                '${fx.analyzedCount} song${fx.analyzedCount == 1 ? '' : 's'} measured',
                style: TextStyle(color: c.secondaryText, fontSize: 12),
              ),
              if (widget.audioFiles.isNotEmpty) ...[
                const SizedBox(height: 8),
                if (_analyzing)
                  Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    LinearProgressIndicator(value: _total == 0 ? null : _done / _total, color: accent),
                    const SizedBox(height: 6),
                    Text('Measuring $_done of $_total…', style: TextStyle(color: c.secondaryText, fontSize: 12)),
                  ])
                else
                  OutlinedButton.icon(
                    onPressed: _analyze,
                    icon: Icon(Icons.graphic_eq_rounded, color: accent),
                    label: Text('Measure whole library now', style: TextStyle(color: accent)),
                    style: OutlinedButton.styleFrom(side: BorderSide(color: accent)),
                  ),
                const SizedBox(height: 4),
                Text('Optional — avoids the short level change the first time a song plays. Runs on-device.',
                    style: TextStyle(color: c.tertiaryText, fontSize: 11)),
              ],
            ],
          ])),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Text(
              'Effects apply to the main player (not Duo Mode) and work together with the Equalizer.',
              style: TextStyle(color: c.tertiaryText, fontSize: 12),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Slider that updates its label live but only applies on release.
class _LiveSlider extends StatefulWidget {
  final double value;
  final double max;
  final bool enabled;
  final Color color;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  const _LiveSlider({
    required this.value,
    required this.max,
    required this.enabled,
    required this.color,
    required this.onChanged,
    required this.onChangeEnd,
  });

  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    return Slider(
      value: (_drag ?? widget.value).clamp(0, widget.max),
      max: widget.max,
      divisions: 20,
      activeColor: widget.color,
      onChanged: widget.enabled ? (v) => setState(() => _drag = v) : null,
      onChangeEnd: (v) {
        widget.onChangeEnd(v);
        setState(() => _drag = null);
      },
    );
  }
}
