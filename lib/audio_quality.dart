// lib/audio_quality.dart
//
// "Audio quality" display: codec, bitrate, sample rate and bit depth of the
// playing file, read natively (MediaExtractor / MediaMetadataRetriever via
// MediaStoreService.getAudioInfo) and cached per path.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'media_store_service.dart';

class AudioQuality {
  AudioQuality._();

  static String codecName(AudioFileInfo? info, String path) {
    final mime = info?.mime?.toLowerCase() ?? '';
    if (mime.contains('mpeg') && !mime.contains('mpeg-l2')) return 'MP3';
    if (mime.contains('flac')) return 'FLAC';
    if (mime.contains('mp4a') || mime.contains('aac')) return 'AAC';
    if (mime.contains('opus')) return 'Opus';
    if (mime.contains('vorbis')) return 'Vorbis';
    if (mime.contains('alac')) return 'ALAC';
    if (mime.contains('amr')) return 'AMR';
    // Some Android versions report decoded PCM ("audio/raw") for FLAC and
    // WAV alike, so fall back to the file extension for those.
    final ext = p.extension(path).replaceFirst('.', '').toUpperCase();
    switch (ext) {
      case 'FLAC':
        return 'FLAC';
      case 'WAV':
      case 'WAVE':
        return 'WAV';
      case 'OGG':
        return 'Vorbis';
      case 'M4A':
        return 'AAC';
    }
    if (mime.contains('raw') || mime.contains('wav')) return 'WAV';
    return ext.isEmpty ? 'Audio' : ext;
  }

  static bool isLossless(AudioFileInfo? info, String path) {
    final c = codecName(info, path);
    return c == 'FLAC' || c == 'WAV' || c == 'ALAC';
  }

  static bool isHiRes(AudioFileInfo? info) =>
      (info?.sampleRate ?? 0) > 48000 || (info?.bitsPerSample ?? 0) > 16;

  static String sampleRate(int hz) {
    final k = hz / 1000;
    return '${k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1)} kHz';
  }

  static String bitrate(int bps) => '${(bps / 1000).round()} kbps';

  static String channels(int n) => n == 1 ? 'Mono' : (n == 2 ? 'Stereo' : '$n channels');

  /// e.g. "FLAC · 24-bit · 96 kHz" or "MP3 · 320 kbps · 44.1 kHz".
  static String compact(AudioFileInfo? info, String path) {
    final parts = <String>[codecName(info, path)];
    if (info != null) {
      if (isLossless(info, path)) {
        if (info.bitsPerSample != null) parts.add('${info.bitsPerSample}-bit');
      } else if (info.bitrate != null) {
        parts.add(bitrate(info.bitrate!));
      }
      if (info.sampleRate != null) parts.add(sampleRate(info.sampleRate!));
    }
    return parts.join(' · ');
  }
}

/// Small pill under the Now Playing title showing the file's quality.
class AudioQualityBadge extends StatefulWidget {
  final String path;
  final Color color;
  final VoidCallback? onTap;
  const AudioQualityBadge({super.key, required this.path, required this.color, this.onTap});

  @override
  State<AudioQualityBadge> createState() => _AudioQualityBadgeState();
}

/// Keeps one lookup per song. The full player rebuilds on every position
/// tick; a stateless badge created a new future each time, so the
/// FutureBuilder reset to "waiting", collapsed to its placeholder and popped
/// back — the whole Now Playing layout jumped several times a second
/// (tester sheet TC1 "flickering").
class _AudioQualityBadgeState extends State<AudioQualityBadge> {
  late Future<AudioFileInfo?> _future;

  @override
  void initState() {
    super.initState();
    _future = MediaStoreService.instance.getAudioInfo(widget.path);
  }

  @override
  void didUpdateWidget(covariant AudioQualityBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) _future = MediaStoreService.instance.getAudioInfo(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final color = widget.color;
    final cached = MediaStoreService.instance.cachedAudioInfo(path);
    return FutureBuilder<AudioFileInfo?>(
      future: _future,
      initialData: cached,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done && snap.data == null) return const SizedBox(height: 28);
        final info = snap.data;
        final hiRes = AudioQuality.isHiRes(info);
        final lossless = AudioQuality.isLossless(info, path);
        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (hiRes || lossless) ...[
                Text(hiRes ? 'HI-RES' : 'LOSSLESS',
                    style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                const SizedBox(width: 6),
              ],
              Text(AudioQuality.compact(info, path),
                  style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ]),
          ),
        );
      },
    );
  }
}
