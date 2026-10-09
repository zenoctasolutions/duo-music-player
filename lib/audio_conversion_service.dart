// lib/audio_conversion_service.dart
//
// Real offline 4D/8D audio DSP conversion. Renders a brand new audio file
// (never touches the original) using ffmpeg audio filters — stereo widening,
// a sine-wave-driven left/right pan LFO (the standard "8D audio" technique)
// and a light chorus/echo — run natively via ffmpeg_kit_flutter_new_audio.
// FFmpegKit.executeAsync hands the render off to a native worker thread and
// returns immediately, so this never blocks the Dart/UI isolate.
import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'public_storage_service.dart';

enum ConversionType { fourD, eightD }

extension ConversionTypeX on ConversionType {
  String get suffix => this == ConversionType.fourD ? '4D' : '8D';
  String get label => this == ConversionType.fourD ? '4D Audio' : '8D Audio';
  String get description => this == ConversionType.fourD
      ? 'Gentle stereo widening with smooth left/right movement'
      : 'Stronger circular spatial movement with wider stereo';

  static ConversionType fromName(String? name) =>
      name == 'eightD' ? ConversionType.eightD : ConversionType.fourD;
}

enum ConversionErrorType {
  invalidFile,
  unsupportedFormat,
  conversionFailed,
  storageFailure,
  permissionFailure,
  cancelled,
}

class ConversionException implements Exception {
  final ConversionErrorType type;
  final String message;
  ConversionException(this.type, this.message);
  @override
  String toString() => message;
}

class ConversionRecord {
  final String originalPath;
  final String convertedPath;
  final ConversionType type;
  final String fileName;
  final DateTime createdAt;

  ConversionRecord({
    required this.originalPath,
    required this.convertedPath,
    required this.type,
    required this.fileName,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'originalPath': originalPath,
        'convertedPath': convertedPath,
        'type': type.name,
        'fileName': fileName,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  static ConversionRecord fromMap(Map map) => ConversionRecord(
        originalPath: map['originalPath'] as String,
        convertedPath: map['convertedPath'] as String,
        type: ConversionTypeX.fromName(map['type'] as String?),
        fileName: map['fileName'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      );
}

class AudioConversionService {
  AudioConversionService._internal();
  static final AudioConversionService instance = AudioConversionService._internal();

  static const String _boxName = 'audio_conversions';
  static const Set<String> _supportedExtensions = {
    '.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.opus'
  };

  Box? _box;
  final Map<String, Future<ConversionRecord>> _inFlight = {};
  int? _activeSessionId;

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

  String _keyFor(String originalPath, ConversionType type) =>
      '$originalPath::${type.name}';

  /// Returns a previously converted file for [originalPath]/[type] if the
  /// record exists AND the file it points to is still on disk — prevents
  /// unnecessary duplicate conversions of the same song.
  Future<ConversionRecord?> findExisting(String originalPath, ConversionType type) async {
    try {
      final box = await _getBox();
      final raw = box.get(_keyFor(originalPath, type));
      if (raw == null) return null;
      final record = ConversionRecord.fromMap(Map<String, dynamic>.from(raw as Map));
      if (await File(record.convertedPath).exists()) return record;
      await box.delete(_keyFor(originalPath, type));
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<List<ConversionRecord>> allRecords() async {
    try {
      final box = await _getBox();
      return box.values
          .whereType<Map>()
          .map((m) => ConversionRecord.fromMap(Map<String, dynamic>.from(m)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Reverse lookup: if [path] is itself a file this service previously
  /// produced, returns which effect it already has. Used to keep the Audio
  /// Conversion sheet from ever offering to convert an already-converted
  /// file to that same effect again — checked separately from
  /// [findExisting], which is keyed by the *original* song's path and can't
  /// answer "is this path itself a converted output".
  ///
  /// Prefers the Hive-tracked conversion records (reliable even if the file
  /// was renamed); falls back to this service's own `name_4D`/`name_8D.mp3`
  /// naming convention only for legacy files whose record is missing (e.g.
  /// after clearing app data).
  Future<ConversionType?> typeOfConvertedFile(String path) async {
    try {
      final normalized = p.normalize(path);
      final records = await allRecords();
      for (final r in records) {
        if (p.normalize(r.convertedPath) == normalized) return r.type;
      }
    } catch (_) {}

    final base = p.basenameWithoutExtension(path);
    if (base.endsWith('_${ConversionType.eightD.suffix}')) return ConversionType.eightD;
    if (base.endsWith('_${ConversionType.fourD.suffix}')) return ConversionType.fourD;
    return null;
  }

  /// Private scratch space ffmpeg renders into before the finished file is
  /// copied into the public Downloads folder (see [PublicStorageService]).
  /// Scoped storage on Android 10+ doesn't allow ffmpeg to write directly
  /// into /storage/emulated/0/Download, so every conversion lands here
  /// first and is deleted once it's been published (or on any failure).
  Future<Directory> _tempWorkDir() async {
    final tmp = await getTemporaryDirectory();
    final target = Directory(p.join(tmp.path, 'zen_conversions'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  /// `apulsator` alternates L/R amplitude on a sine LFO — the standard
  /// technique behind most "8D audio" effects. 4D uses a slower/shallower
  /// LFO with a lighter chorus; 8D widens the stereo field further and adds
  /// a stronger continuous pan plus a touch of echo for depth. `alimiter` at
  /// the end keeps the result from ever clipping.
  String _filterChainFor(ConversionType type) {
    switch (type) {
      case ConversionType.fourD:
        return 'extrastereo=m=1.10,chorus=0.6:0.9:55:0.4:0.25:2,'
            'apulsator=hz=0.08:mode=sine,alimiter=limit=0.95';
      case ConversionType.eightD:
        return 'extrastereo=m=1.35,stereotools=mlev=1.2,'
            'apulsator=hz=0.20:mode=sine,aecho=0.8:0.9:40|60:0.35|0.25,'
            'alimiter=limit=0.95';
    }
  }

  /// Converts [originalPath] to [type], reusing an in-flight conversion of
  /// the same song+type instead of starting a second one if called twice in
  /// a row (e.g. a double tap).
  Future<ConversionRecord> convert({
    required String originalPath,
    required ConversionType type,
    required String baseTitle,
    void Function(double progress)? onProgress,
  }) {
    final key = _keyFor(originalPath, type);
    final existingInFlight = _inFlight[key];
    if (existingInFlight != null) return existingInFlight;

    final future = _runConversion(
      originalPath: originalPath,
      type: type,
      baseTitle: baseTitle,
      key: key,
      onProgress: onProgress,
    );
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<int> _probeDurationMs(String path) async {
    try {
      final session = await FFprobeKit.getMediaInformation(path);
      final info = session.getMediaInformation();
      final secondsStr = info?.getDuration();
      final seconds = secondsStr != null ? double.tryParse(secondsStr) : null;
      if (seconds != null && seconds > 0) return (seconds * 1000).round();
    } catch (_) {}
    return 0;
  }

  Future<ConversionRecord> _runConversion({
    required String originalPath,
    required ConversionType type,
    required String baseTitle,
    required String key,
    void Function(double progress)? onProgress,
  }) async {
    final inputFile = File(originalPath);
    if (!await inputFile.exists()) {
      throw ConversionException(ConversionErrorType.invalidFile, 'Original file not found.');
    }

    final existing = await findExisting(originalPath, type);
    if (existing != null) return existing;

    // Defense in depth: the sheet UI already disables re-converting a file
    // that is itself a converted output, but guard here too so no other
    // call site can accidentally double-process the same audio.
    final selfType = await typeOfConvertedFile(originalPath);
    if (selfType == type) {
      throw ConversionException(
        ConversionErrorType.invalidFile,
        'This file is already ${type.label} — convert the original song instead.',
      );
    }

    final ext = p.extension(originalPath).toLowerCase();
    if (!_supportedExtensions.contains(ext)) {
      throw ConversionException(
        ConversionErrorType.unsupportedFormat,
        'Unsupported audio format "$ext".',
      );
    }

    final safeBase = baseTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final outName =
        '${safeBase.isEmpty ? p.basenameWithoutExtension(originalPath) : safeBase}_${type.suffix}.mp3';

    // A valid file with this name may already be sitting in Downloads even
    // if the Hive record above was missing (e.g. app storage was cleared) —
    // reuse it instead of re-running ffmpeg.
    final alreadyDownloaded = await PublicStorageService.instance.lookupExisting(outName);
    if (alreadyDownloaded?.path != null) {
      final record = ConversionRecord(
        originalPath: originalPath,
        convertedPath: alreadyDownloaded!.path!,
        type: type,
        fileName: outName,
        createdAt: DateTime.now(),
      );
      try {
        final box = await _getBox();
        await box.put(key, record.toMap());
      } catch (_) {}
      return record;
    }

    Directory workDir;
    try {
      workDir = await _tempWorkDir();
    } on FileSystemException catch (e) {
      throw ConversionException(
        ConversionErrorType.permissionFailure,
        'Permission denied while preparing a temporary workspace: ${e.message}',
      );
    }

    final outPath = p.join(workDir.path, outName);
    final outFile = File(outPath);
    if (await outFile.exists()) {
      try {
        await outFile.delete();
      } catch (_) {}
    }

    final durationMs = await _probeDurationMs(originalPath);
    final filterChain = _filterChainFor(type);

    String escape(String path) => path.replaceAll('"', '\\"');
    // -map 0:a:0 selects the source audio track; -map 0:v? optionally
    // carries over an embedded-artwork "video" stream (how ID3/FLAC cover
    // art is exposed) if the input has one, and -c:v copy keeps it as an
    // exact byte copy instead of re-encoding — preserving title/artist/album
    // (-map_metadata 0) and artwork on the converted file, same as original.
    final command = '-y -i "${escape(originalPath)}" -map_metadata 0 -map 0:a:0 -map 0:v? -c:v copy '
        '-id3v2_version 3 -af "$filterChain" -c:a libmp3lame -b:a 192k "${escape(outPath)}"';

    final completer = Completer<ConversionRecord>();

    Future<void> finish(FFmpegSession session) async {
      try {
        final returnCode = await session.getReturnCode();
        if (_activeSessionId == session.getSessionId()) {
          _activeSessionId = null;
        }

        if (ReturnCode.isSuccess(returnCode)) {
          if (!await outFile.exists() || await outFile.length() == 0) {
            completer.completeError(ConversionException(
              ConversionErrorType.conversionFailed,
              'Conversion produced no output — the source file may be corrupted.',
            ));
            return;
          }

          try {
            final published = await PublicStorageService.instance.publish(
              sourcePath: outPath,
              displayName: outName,
            );
            final finalPath = published.path;
            if (finalPath == null || finalPath.isEmpty) {
              throw ConversionException(
                ConversionErrorType.storageFailure,
                'Could not resolve the saved file location in Downloads.',
              );
            }
            final record = ConversionRecord(
              originalPath: originalPath,
              convertedPath: finalPath,
              type: type,
              fileName: outName,
              createdAt: DateTime.now(),
            );
            try {
              final box = await _getBox();
              await box.put(key, record.toMap());
            } catch (_) {}
            completer.complete(record);
          } on PublicStorageException catch (e) {
            completer.completeError(_mapStorageException(e));
          } catch (e) {
            if (!completer.isCompleted) {
              completer.completeError(e is ConversionException
                  ? e
                  : ConversionException(ConversionErrorType.conversionFailed, 'Failed to save to Downloads: $e'));
            }
          } finally {
            try {
              if (await outFile.exists()) await outFile.delete();
            } catch (_) {}
          }
        } else if (ReturnCode.isCancel(returnCode)) {
          try {
            if (await outFile.exists()) await outFile.delete();
          } catch (_) {}
          completer.completeError(
              ConversionException(ConversionErrorType.cancelled, 'Conversion cancelled.'));
        } else {
          try {
            if (await outFile.exists()) await outFile.delete();
          } catch (_) {}
          final trace = (await session.getFailStackTrace())?.toLowerCase() ?? '';
          final isStorage = trace.contains('no space') || trace.contains('enospc');
          final isPermission = trace.contains('permission denied') || trace.contains('eacces');
          completer.completeError(ConversionException(
            isStorage
                ? ConversionErrorType.storageFailure
                : isPermission
                    ? ConversionErrorType.permissionFailure
                    : ConversionErrorType.conversionFailed,
            isStorage
                ? 'Not enough storage space to save the converted file.'
                : isPermission
                    ? 'Permission denied while writing the converted file.'
                    : 'Audio conversion failed. The file may be corrupted or unsupported.',
          ));
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(
              ConversionException(ConversionErrorType.conversionFailed, 'Conversion failed: $e'));
        }
      }
    }

    final session = await FFmpegKit.executeAsync(
      command,
      (s) {
        unawaited(finish(s));
      },
      null,
      (stat) {
        if (onProgress == null || durationMs <= 0) return;
        final time = stat.getTime();
        if (time > 0) {
          onProgress((time / durationMs).clamp(0.0, 1.0));
        }
      },
    );
    _activeSessionId = session.getSessionId();

    return completer.future;
  }

  ConversionException _mapStorageException(PublicStorageException e) {
    switch (e.type) {
      case PublicStorageErrorType.permissionFailure:
        return ConversionException(ConversionErrorType.permissionFailure, e.message);
      case PublicStorageErrorType.storageFailure:
        return ConversionException(ConversionErrorType.storageFailure, e.message);
      case PublicStorageErrorType.invalidSource:
        return ConversionException(ConversionErrorType.invalidFile, e.message);
      case PublicStorageErrorType.unsupportedPlatform:
        return ConversionException(ConversionErrorType.conversionFailed, e.message);
      case PublicStorageErrorType.ioFailure:
        return ConversionException(ConversionErrorType.conversionFailed, e.message);
    }
  }

  /// Cancels whichever conversion is currently running (used by the
  /// progress dialog's Cancel button).
  Future<void> cancelActive() async {
    if (_activeSessionId != null) {
      await FFmpegKit.cancel(_activeSessionId);
    } else {
      await FFmpegKit.cancel();
    }
  }
}
