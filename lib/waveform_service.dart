// lib/waveform_service.dart
//
// Generates the amplitude bars shown by the Audio Cutter's waveform trimmer.
// No waveform package is added — ffmpeg is already a dependency (used by
// AudioConversionService/AudioCutterService), so it's reused here to decode
// the song to a small raw mono PCM stream, which is then downsampled into a
// fixed number of bars. Mirrors those services' architecture: a private temp
// work dir, an in-flight map keyed per song so a duplicate request reuses
// the same future instead of starting a second ffmpeg session, and a single
// tracked session id so the page can cancel generation on dispose.
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Number of amplitude bars rendered by the waveform trimmer.
const int kWaveformBarCount = 220;

enum WaveformErrorType { invalidFile, generationFailed, cancelled }

class WaveformException implements Exception {
  final WaveformErrorType type;
  final String message;
  WaveformException(this.type, this.message);
  @override
  String toString() => message;
}

class _PcmDecodeArgs {
  final String pcmPath;
  final int barCount;
  _PcmDecodeArgs(this.pcmPath, this.barCount);
}

/// Downsamples a raw 16-bit little-endian mono PCM file into [barCount]
/// normalized (0..1) peak-amplitude bars. Runs via [compute] on a background
/// isolate so parsing a long song's samples never blocks the UI thread.
List<double> _downsamplePcm(_PcmDecodeArgs args) {
  final bytes = File(args.pcmPath).readAsBytesSync();
  final sampleCount = bytes.lengthInBytes ~/ 2;
  final barCount = args.barCount;
  if (sampleCount <= 0) return List<double>.filled(barCount, 0.04);

  final data = ByteData.sublistView(bytes);
  final samplesPerBar = (sampleCount / barCount).ceil().clamp(1, sampleCount);
  final bars = List<double>.filled(barCount, 0.0);

  for (var bar = 0; bar < barCount; bar++) {
    final start = bar * samplesPerBar;
    if (start >= sampleCount) break;
    final end = (start + samplesPerBar).clamp(0, sampleCount);
    var peak = 0;
    for (var i = start; i < end; i++) {
      final sample = data.getInt16(i * 2, Endian.little).abs();
      if (sample > peak) peak = sample;
    }
    bars[bar] = peak / 32768.0;
  }

  final maxBar = bars.fold<double>(0.0, (m, v) => v > m ? v : m);
  final scale = maxBar > 0.02 ? (1.0 / maxBar) : 1.0;
  return bars.map((v) => (v * scale).clamp(0.04, 1.0)).toList(growable: false);
}

class WaveformService {
  WaveformService._internal();
  static final WaveformService instance = WaveformService._internal();

  // Low sample rate keeps the decoded PCM small (~16KB/s) since only a peak
  // envelope is needed, not audio quality — a 10 minute song is under 10MB.
  static const int _sampleRateHz = 8000;
  static const int _maxCacheEntries = 12;

  final Map<String, List<double>> _cache = {};
  final Map<String, Future<List<double>>> _inFlight = {};
  int? _activeSessionId;

  Future<Directory> _tempWorkDir() async {
    final tmp = await getTemporaryDirectory();
    final target = Directory(p.join(tmp.path, 'zen_waveforms'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  String _cacheKey(String path, int sizeBytes, int barCount) => '$path::$sizeBytes::$barCount';

  /// Generates (or reuses a cached/in-flight) amplitude envelope for
  /// [sourcePath]. Cached by path+size so a stale entry for a replaced file
  /// at the same path is never served.
  Future<List<double>> generate(String sourcePath, {int barCount = kWaveformBarCount}) {
    final file = File(sourcePath);
    if (!file.existsSync()) {
      return Future.error(WaveformException(WaveformErrorType.invalidFile, 'Source file not found.'));
    }

    final int size;
    try {
      size = file.lengthSync();
    } catch (e) {
      return Future.error(WaveformException(WaveformErrorType.invalidFile, 'Could not read source file: $e'));
    }

    final key = _cacheKey(sourcePath, size, barCount);

    final cached = _cache[key];
    if (cached != null) return Future.value(cached);

    final existingInFlight = _inFlight[key];
    if (existingInFlight != null) return existingInFlight;

    final future = _generate(sourcePath, key, barCount);
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<List<double>> _generate(String sourcePath, String key, int barCount) async {
    Directory workDir;
    try {
      workDir = await _tempWorkDir();
    } on FileSystemException catch (e) {
      throw WaveformException(WaveformErrorType.generationFailed, 'Could not prepare a temporary workspace: ${e.message}');
    }

    final pcmPath = p.join(
      workDir.path,
      '${DateTime.now().microsecondsSinceEpoch}_${p.basenameWithoutExtension(sourcePath)}.pcm',
    );
    final pcmFile = File(pcmPath);

    String escape(String path) => path.replaceAll('"', '\\"');
    final command =
        '-y -i "${escape(sourcePath)}" -vn -ac 1 -ar $_sampleRateHz -f s16le "${escape(pcmPath)}"';

    final completer = Completer<List<double>>();

    final session = await FFmpegKit.executeAsync(command, (s) {
      () async {
        try {
          final returnCode = await s.getReturnCode();
          if (_activeSessionId == s.getSessionId()) {
            _activeSessionId = null;
          }

          if (ReturnCode.isSuccess(returnCode)) {
            if (!await pcmFile.exists() || await pcmFile.length() <= 0) {
              completer.completeError(
                WaveformException(WaveformErrorType.generationFailed, 'No audio data could be decoded for the waveform.'),
              );
              return;
            }
            try {
              final bars = await compute(_downsamplePcm, _PcmDecodeArgs(pcmPath, barCount));
              _cache[key] = bars;
              if (_cache.length > _maxCacheEntries) {
                _cache.remove(_cache.keys.first);
              }
              completer.complete(bars);
            } catch (e) {
              completer.completeError(
                WaveformException(WaveformErrorType.generationFailed, 'Failed to process waveform data: $e'),
              );
            }
          } else if (ReturnCode.isCancel(returnCode)) {
            completer.completeError(WaveformException(WaveformErrorType.cancelled, 'Waveform generation cancelled.'));
          } else {
            completer.completeError(
              WaveformException(WaveformErrorType.generationFailed, 'Could not decode audio for waveform preview.'),
            );
          }
        } catch (e) {
          if (!completer.isCompleted) {
            completer.completeError(WaveformException(WaveformErrorType.generationFailed, 'Waveform generation failed: $e'));
          }
        } finally {
          try {
            if (await pcmFile.exists()) await pcmFile.delete();
          } catch (_) {}
        }
      }();
    });
    _activeSessionId = session.getSessionId();

    return completer.future;
  }

  /// Cancels whichever waveform decode is currently running — called when
  /// the Audio Cutter page is closed before generation finishes, so no
  /// orphaned ffmpeg session keeps running in the background.
  Future<void> cancelActive() async {
    if (_activeSessionId != null) {
      try {
        await FFmpegKit.cancel(_activeSessionId);
      } catch (_) {}
      _activeSessionId = null;
    }
  }
}
