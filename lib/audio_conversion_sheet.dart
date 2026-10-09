// lib/audio_conversion_sheet.dart
//
// UI entry point for 4D/8D audio conversion — a bottom sheet (matching the
// app's existing bottom-sheet style) offering the two effects, a progress
// dialog while ffmpeg renders the file, and success/error SnackBars using
// the same color conventions used everywhere else in the app.
import 'dart:io';

import 'package:flutter/material.dart';

import 'audio_analysis_service.dart';
import 'audio_conversion_service.dart';
import 'preset_recommender.dart';
import 'app_palette.dart';

Color get _kPrimary => AppPalette.accent;

Future<void> showAudioConversionSheet({
  required BuildContext context,
  required File song,
  required String title,
  required bool isDark,
  required void Function(ConversionRecord record) onConverted,
}) async {
  final cardBg = isDark ? AppPalette.darkCard : Colors.white;
  final textColor = isDark ? Colors.white : Colors.black87;
  final subtitleColor = isDark ? Colors.grey[400] : Colors.grey[600];

  ConversionRecord? existing4D;
  ConversionRecord? existing8D;
  ConversionType? selfConvertedType;
  try {
    existing4D = await AudioConversionService.instance.findExisting(song.path, ConversionType.fourD);
    existing8D = await AudioConversionService.instance.findExisting(song.path, ConversionType.eightD);
    selfConvertedType = await AudioConversionService.instance.typeOfConvertedFile(song.path);
  } catch (_) {}

  if (!context.mounted) return;

  await showModalBottomSheet(
    context: context,
    backgroundColor: cardBg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
            child: Row(
              children: [
                Icon(Icons.graphic_eq, color: _kPrimary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Audio Conversion',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: textColor)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(title,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: subtitleColor, fontSize: 13)),
          ),
          if (selfConvertedType == null)
            _RecommendationBanner(
              song: song,
              textColor: textColor,
              subtitleColor: subtitleColor,
              onApply: (preset) {
                final type = PresetRecommender.toConversionType(preset);
                Navigator.pop(ctx);
                final existing = type == ConversionType.fourD ? existing4D : existing8D;
                _handleConversionTap(context, song, title, type, isDark, onConverted, existing);
              },
            ),
          const SizedBox(height: 8),
          _ConversionOptionTile(
            icon: Icons.blur_circular,
            type: ConversionType.fourD,
            existing: existing4D,
            selfConverted: selfConvertedType == ConversionType.fourD,
            textColor: textColor,
            subtitleColor: subtitleColor,
            onTap: () {
              Navigator.pop(ctx);
              _handleConversionTap(context, song, title, ConversionType.fourD, isDark, onConverted, existing4D);
            },
          ),
          _ConversionOptionTile(
            icon: Icons.threed_rotation,
            type: ConversionType.eightD,
            existing: existing8D,
            selfConverted: selfConvertedType == ConversionType.eightD,
            textColor: textColor,
            subtitleColor: subtitleColor,
            onTap: () {
              Navigator.pop(ctx);
              _handleConversionTap(context, song, title, ConversionType.eightD, isDark, onConverted, existing8D);
            },
          ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
}

class _RecommendationBanner extends StatefulWidget {
  final File song;
  final Color textColor;
  final Color? subtitleColor;
  final void Function(RecommendedPreset preset) onApply;

  const _RecommendationBanner({
    required this.song,
    required this.textColor,
    required this.subtitleColor,
    required this.onApply,
  });

  @override
  State<_RecommendationBanner> createState() => _RecommendationBannerState();
}

class _RecommendationBannerState extends State<_RecommendationBanner> {
  PresetRecommendation? _rec;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    AudioAnalysisService.instance.analyze(widget.song.path).then((a) {
      if (!mounted) return;
      setState(() => _rec = PresetRecommender.recommend(a));
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) return const SizedBox.shrink();

    final rec = _rec;
    if (rec == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
        child: Row(
          children: [
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: _kPrimary),
            ),
            const SizedBox(width: 8),
            Text('Analyzing track…', style: TextStyle(color: widget.subtitleColor, fontSize: 12)),
          ],
        ),
      );
    }
    if (rec.preset == RecommendedPreset.none) return const SizedBox.shrink();

    final label = rec.preset == RecommendedPreset.eightD ? '8D Audio' : '4D Audio';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => widget.onApply(rec.preset),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _kPrimary.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
          child: Row(
            children: [
              Icon(Icons.auto_awesome, color: _kPrimary, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Recommended: $label',
                        style: TextStyle(color: widget.textColor, fontWeight: FontWeight.w700, fontSize: 13)),
                    const SizedBox(height: 2),
                    Text(rec.reason, style: TextStyle(color: widget.subtitleColor, fontSize: 11)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConversionOptionTile extends StatelessWidget {
  final IconData icon;
  final ConversionType type;
  final ConversionRecord? existing;
  final bool selfConverted;
  final Color textColor;
  final Color? subtitleColor;
  final VoidCallback onTap;

  const _ConversionOptionTile({
    required this.icon,
    required this.type,
    required this.existing,
    required this.selfConverted,
    required this.textColor,
    required this.subtitleColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasExisting = existing != null;
    // A file that is itself a converted output can't be converted to that
    // same effect again — the tile is fully disabled instead of offering an
    // action, rather than just relabeled like the "already converted, tap to
    // play" state below (which applies to the *original* song).
    if (selfConverted) {
      return ListTile(
        enabled: false,
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: Colors.grey.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: subtitleColor),
        ),
        title: Text(type.label, style: TextStyle(color: subtitleColor, fontWeight: FontWeight.w600)),
        subtitle: Text('This file is already ${type.label}', style: TextStyle(color: subtitleColor, fontSize: 12)),
        trailing: Icon(Icons.block, color: subtitleColor),
      );
    }
    return ListTile(
      leading: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: _kPrimary.withOpacity(0.12), borderRadius: BorderRadius.circular(10)),
        child: Icon(icon, color: _kPrimary),
      ),
      title: Text(type.label, style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
      subtitle: Text(
        hasExisting ? 'Already converted • Tap to play' : type.description,
        style: TextStyle(color: hasExisting ? _kPrimary : subtitleColor, fontSize: 12),
      ),
      trailing: Icon(hasExisting ? Icons.play_circle_fill : Icons.chevron_right,
          color: hasExisting ? _kPrimary : subtitleColor),
      onTap: onTap,
    );
  }
}

Future<void> _handleConversionTap(
  BuildContext context,
  File song,
  String title,
  ConversionType type,
  bool isDark,
  void Function(ConversionRecord) onConverted,
  ConversionRecord? existing,
) async {
  if (existing != null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Already converted to ${type.label} — playing existing file'),
        backgroundColor: _kPrimary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ));
    }
    onConverted(existing);
    return;
  }

  // 4D/8D conversion is free for everyone — Duo Music Player has no
  // premium tier and no ads.
  await _startConversion(context, song, title, type, isDark, onConverted);
}

Future<void> _startConversion(
  BuildContext context,
  File song,
  String title,
  ConversionType type,
  bool isDark,
  void Function(ConversionRecord) onConverted,
) async {
  final cardBg = isDark ? AppPalette.darkCard : Colors.white;
  final textColor = isDark ? Colors.white : Colors.black87;

  final progressNotifier = ValueNotifier<double>(0.0);

  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogCtx) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: ValueListenableBuilder<double>(
          valueListenable: progressNotifier,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Converting to ${type.label}…',
                  style: TextStyle(color: textColor, fontWeight: FontWeight.w600)),
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: value > 0 ? value : null,
                color: _kPrimary,
                backgroundColor: Colors.grey.withOpacity(0.3),
              ),
              const SizedBox(height: 8),
              Text('${(value * 100).toStringAsFixed(0)}%', style: TextStyle(color: textColor)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  AudioConversionService.instance.cancelActive();
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void closeProgressDialog() {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  try {
    final record = await AudioConversionService.instance.convert(
      originalPath: song.path,
      type: type,
      baseTitle: title,
      onProgress: (p) => progressNotifier.value = p,
    );
    closeProgressDialog();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${type.suffix} audio saved to Downloads'),
      backgroundColor: Colors.green,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
    onConverted(record);
  } catch (e) {
    closeProgressDialog();
    if (!context.mounted) return;
    final isCancel = e is ConversionException && e.type == ConversionErrorType.cancelled;
    final message = e is ConversionException ? e.message : 'Conversion failed: $e';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(isCancel ? 'Conversion cancelled' : message),
      backgroundColor: isCancel ? Colors.orange : Colors.red,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }
}
