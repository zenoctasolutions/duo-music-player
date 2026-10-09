// lib/audio_analysis_service.dart
//
// On-device, DSP-only heuristic audio analysis: tempo (BPM), an energy
// (loudness) proxy and a brightness (zero-crossing-rate) proxy, decoded via
// the same ffmpeg PCM pipeline WaveformService already uses. No ML model,
// no network call — mood buckets are simple thresholds over these three
// features. Used to (a) offer a mood-based tag for songs with no ID3
// genre/album/artist at all, (b) build Smart Mix playlists, and (c)
// recommend a 4D/8D preset. Results are cached in Hive keyed by path+size
// so a given song is only ever decoded once.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum MoodBucket { energetic, upbeat, balanced, mellow, chill }

extension MoodBucketX on MoodBucket {
  String get label => switch (this) {
        MoodBucket.energetic => 'Energetic',
        MoodBucket.upbeat => 'Upbeat',
        MoodBucket.balanced => 'Balanced',
        MoodBucket.mellow => 'Mellow',
        MoodBucket.chill => 'Chill',
      };

  static MoodBucket fromName(String? name) => MoodBucket.values.firstWhere(
        (m) => m.name == name,
        orElse: () => MoodBucket.balanced,
      );
}

class AudioAnalysis {
  final double bpm; // estimated tempo; 0 when undetectable
  final double energy; // 0..1 RMS-based loudness proxy
  final double brightness; // 0..1 zero-crossing-rate proxy
  final MoodBucket mood;

  const AudioAnalysis({
    required this.bpm,
    required this.energy,
    required this.brightness,
    required this.mood,
  });

  Map<String, dynamic> toMap() => {
        'bpm': bpm,
        'energy': energy,
        'brightness': brightness,
        'mood': mood.name,
      };

  static AudioAnalysis fromMap(Map map) => AudioAnalysis(
        bpm: (map['bpm'] as num?)?.toDouble() ?? 0,
        energy: (map['energy'] as num?)?.toDouble() ?? 0,
        brightness: (map['brightness'] as num?)?.toDouble() ?? 0,
        mood: MoodBucketX.fromName(map['mood'] as String?),
      );
}

class _PcmAnalyzeArgs {
  final String pcmPath;
  final double sampleRateHz;
  _PcmAnalyzeArgs(this.pcmPath, this.sampleRateHz);
}

MoodBucket _bucketFor({required double bpm, required double energy, required double brightness}) {
  final tempoHigh = bpm >= 120;
  final tempoLow = bpm > 0 && bpm < 85;
  if (tempoHigh && energy > 0.55) return MoodBucket.energetic;
  if (tempoLow && energy < 0.35) return MoodBucket.chill;
  if (energy < 0.4 && brightness < 0.35) return MoodBucket.mellow;
  if (tempoHigh || (energy > 0.45 && brightness > 0.4)) return MoodBucket.upbeat;
  return MoodBucket.balanced;
}

/// Runs on a background isolate (via [compute]) — parsing a full window of
/// raw PCM samples never blocks the UI thread.
AudioAnalysis _analyzePcm(_PcmAnalyzeArgs args) {
  final bytes = File(args.pcmPath).readAsBytesSync();
  final sampleCount = bytes.lengthInBytes ~/ 2;
  const empty = AudioAnalysis(bpm: 0, energy: 0, brightness: 0, mood: MoodBucket.balanced);
  if (sampleCount <= 0) return empty;

  final data = ByteData.sublistView(bytes);

  // ~46ms frames at the decode sample rate — the basis for both an
  // onset-strength signal (for tempo) and an overall loudness estimate.
  const frameSize = 1024;
  final frameCount = sampleCount ~/ frameSize;
  if (frameCount < 4) return empty;

  final energyEnvelope = List<double>.filled(frameCount, 0.0);
  double sumSq = 0;
  int zeroCrossings = 0;
  int prevSample = 0;

  for (var frame = 0; frame < frameCount; frame++) {
    final start = frame * frameSize;
    double frameSumSq = 0;
    for (var i = 0; i < frameSize; i++) {
      final sample = data.getInt16((start + i) * 2, Endian.little);
      final sq = (sample * sample).toDouble();
      frameSumSq += sq;
      sumSq += sq;
      if (frame > 0 || i > 0) {
        if ((sample >= 0) != (prevSample >= 0)) zeroCrossings++;
      }
      prevSample = sample;
    }
    energyEnvelope[frame] = math.sqrt(frameSumSq / frameSize);
  }

  final rms = math.sqrt(sumSq / (frameCount * frameSize));
  // 6000 (of a possible 32768 full-scale int16) maps typical music RMS
  // into a fuller 0..1 range — real masters rarely approach full scale.
  final energy = (rms / 6000.0).clamp(0.0, 1.0);
  final brightness = ((zeroCrossings / sampleCount) * 2).clamp(0.0, 1.0);

  // Onset strength: half-wave-rectified frame-to-frame energy increase.
  final onset = List<double>.filled(frameCount, 0.0);
  for (var i = 1; i < frameCount; i++) {
    final d = energyEnvelope[i] - energyEnvelope[i - 1];
    onset[i] = d > 0 ? d : 0;
  }

  // Autocorrelation of the onset curve over the lag range spanning
  // 60–200 BPM at this frame rate — a standard cheap tempo estimate when a
  // full beat tracker is out of scope for a DSP-only v1.
  final frameRate = args.sampleRateHz / frameSize; // frames per second
  final minLag = (frameRate * 60 / 200).round().clamp(1, frameCount - 1);
  final maxLag = (frameRate * 60 / 60).round().clamp(minLag + 1, frameCount - 1);

  double bestScore = 0;
  int bestLag = 0;
  for (var lag = minLag; lag <= maxLag; lag++) {
    double score = 0;
    for (var i = lag; i < frameCount; i++) {
      score += onset[i] * onset[i - lag];
    }
    if (score > bestScore) {
      bestScore = score;
      bestLag = lag;
    }
  }

  final bpm = bestLag > 0 ? (60.0 * frameRate / bestLag) : 0.0;
  final mood = _bucketFor(bpm: bpm, energy: energy, brightness: brightness);

  return AudioAnalysis(bpm: bpm, energy: energy, brightness: brightness, mood: mood);
}

class AudioAnalysisService {
  AudioAnalysisService._internal();
  static final AudioAnalysisService instance = AudioAnalysisService._internal();

  static const String _boxName = 'audio_analysis';
  static const double _sampleRateHz = 22050;
  static const int _windowSeconds = 60;
  static const int _startOffsetSeconds = 10;

  Box? _box;
  final Map<String, Future<AudioAnalysis>> _inFlight = {};

  Future<Box> _getBox() async {
    if (_box != null && _box!.isOpen) return _box!;
    if (!Hive.isBoxOpen(_boxName)) {
      await Hive.initFlutter();
      _box = await Hive.openBox(_boxName);
    } else {
      _box = Hive.box(_boxName);
    }
    return _box!;
  }

  String _keyFor(String path, int sizeBytes) => '$path::$sizeBytes';

  Future<Directory> _tempWorkDir() async {
    final tmp = await getTemporaryDirectory();
    final target = Directory(p.join(tmp.path, 'zen_analysis'));
    if (!await target.exists()) await target.create(recursive: true);
    return target;
  }

  /// Returns a cached analysis if one exists, without ever triggering a
  /// decode — safe to call frequently (e.g. from a build method).
  Future<AudioAnalysis?> cached(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final size = await file.length();
      final box = await _getBox();
      final raw = box.get(_keyFor(path, size));
      if (raw == null) return null;
      return AudioAnalysis.fromMap(Map<String, dynamic>.from(raw as Map));
    } catch (_) {
      return null;
    }
  }

  Future<String> _escapeAndDecode(String sourcePath, String pcmPath, {int? startOffset}) async {
    String escape(String s) => s.replaceAll('"', '\\"');
    final offset = startOffset != null ? '-ss $startOffset ' : '';
    return '-y ${offset}-t $_windowSeconds -i "${escape(sourcePath)}" -vn -ac 1 '
        '-ar ${_sampleRateHz.round()} -f s16le "${escape(pcmPath)}"';
  }

  Future<AudioAnalysis> _decodeAndAnalyze(String sourcePath, {int? startOffset}) async {
    final workDir = await _tempWorkDir();
    final pcmPath = p.join(
      workDir.path,
      '${DateTime.now().microsecondsSinceEpoch}_${startOffset ?? 0}.pcm',
    );
    final pcmFile = File(pcmPath);
    final command = await _escapeAndDecode(sourcePath, pcmPath, startOffset: startOffset);

    final completer = Completer<AudioAnalysis>();
    await FFmpegKit.executeAsync(command, (session) {
      () async {
        try {
          final returnCode = await session.getReturnCode();
          if (!ReturnCode.isSuccess(returnCode) || !await pcmFile.exists() || await pcmFile.length() <= 0) {
            completer.completeError(Exception('Could not decode audio for analysis.'));
            return;
          }
          final result = await compute(_analyzePcm, _PcmAnalyzeArgs(pcmPath, _sampleRateHz));
          completer.complete(result);
        } catch (e) {
          if (!completer.isCompleted) completer.completeError(e);
        } finally {
          try {
            if (await pcmFile.exists()) await pcmFile.delete();
          } catch (_) {}
        }
      }();
    });
    return completer.future;
  }

  /// Analyzes [path] (reusing a cached result or an in-flight decode for the
  /// same file) and persists the result so it's never decoded twice.
  Future<AudioAnalysis> analyze(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return Future.error(Exception('File not found: $path'));
    }
    final size = file.lengthSync();
    final key = _keyFor(path, size);

    final existingInFlight = _inFlight[key];
    if (existingInFlight != null) return existingInFlight;

    final future = _analyze(path, key);
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<AudioAnalysis> _analyze(String path, String key) async {
    final cachedResult = await cached(path);
    if (cachedResult != null) return cachedResult;

    AudioAnalysis result;
    try {
      result = await _decodeAndAnalyze(path, startOffset: _startOffsetSeconds);
    } catch (_) {
      // A short song can be shorter than the offset window — retry once
      // decoding from the very start instead.
      result = await _decodeAndAnalyze(path);
    }

    try {
      final box = await _getBox();
      await box.put(key, result.toMap());
    } catch (_) {}
    return result;
  }

  /// Analyzes many files with bounded concurrency, so a Smart Mix build or a
  /// genre-backfill pass never spawns dozens of simultaneous ffmpeg
  /// sessions. Skips files that already have a cached result. Files that
  /// fail to decode (corrupt/unsupported) are silently skipped rather than
  /// aborting the whole batch.
  Future<Map<String, AudioAnalysis>> analyzeAll(
    List<String> paths, {
    void Function(int done, int total)? onProgress,
    int concurrency = 2,
  }) async {
    final results = <String, AudioAnalysis>{};
    if (paths.isEmpty) return results;

    var done = 0;
    final queue = List<String>.from(paths);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final path = queue.removeLast();
        try {
          results[path] = await analyze(path);
        } catch (_) {
          // skip
        } finally {
          done++;
          onProgress?.call(done, paths.length);
        }
      }
    }

    await Future.wait(List.generate(concurrency, (_) => worker()));
    return results;
  }
}
