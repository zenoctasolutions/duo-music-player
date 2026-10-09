// lib/audio_cutter_service.dart
//
// Cuts a segment out of a song with ffmpeg (never touches the original) and
// publishes the result to the public Downloads folder, mirroring
// audio_conversion_service.dart's architecture: render to a private temp
// file first, then hand it to PublicStorageService, tracking the result in
// its own Hive box so a repeat request for the exact same range reuses the
// existing output instead of cutting again.
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

enum CutErrorType {
  invalidFile,
  unsupportedFormat,
  invalidRange,
  conversionFailed,
  storageFailure,
  permissionFailure,
  cancelled,
}

class CutException implements Exception {
  final CutErrorType type;
  final String message;
  CutException(this.type, this.message);
  @override
  String toString() => message;
}

class CutRecord {
  final String originalPath;
  final String cutPath;
  final Duration start;
  final Duration end;
  final String fileName;
  final DateTime createdAt;

  CutRecord({
    required this.originalPath,
    required this.cutPath,
    required this.start,
    required this.end,
    required this.fileName,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'originalPath': originalPath,
        'cutPath': cutPath,
        'startMs': start.inMilliseconds,
        'endMs': end.inMilliseconds,
        'fileName': fileName,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  static CutRecord fromMap(Map map) => CutRecord(
        originalPath: map['originalPath'] as String,
        cutPath: map['cutPath'] as String,
        start: Duration(milliseconds: map['startMs'] as int),
        end: Duration(milliseconds: map['endMs'] as int),
        fileName: map['fileName'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      );
}

class AudioCutterService {
  AudioCutterService._internal();
  static final AudioCutterService instance = AudioCutterService._internal();

  static const String _boxName = 'audio_cuts';
  static const Set<String> _supportedExtensions = {
    '.mp3', '.m4a', '.wav', '.aac', '.ogg', '.flac', '.opus',
  };

  Box? _box;
  final Map<String, Future<CutRecord>> _inFlight = {};
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

  String _keyFor(String originalPath, Duration start, Duration end) =>
      '$originalPath::${start.inMilliseconds}::${end.inMilliseconds}';

  /// Returns a previously cut file for this exact [originalPath]/[start]/
  /// [end] if the record exists AND the file it points to is still on disk.
  Future<CutRecord?> findExisting(String originalPath, Duration start, Duration end) async {
    try {
      final box = await _getBox();
      final key = _keyFor(originalPath, start, end);
      final raw = box.get(key);
      if (raw == null) return null;
      final record = CutRecord.fromMap(Map<String, dynamic>.from(raw as Map));
      if (await File(record.cutPath).exists()) return record;
      await box.delete(key);
      return null;
    } catch (_) {
      return null;
    }
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

  Future<Directory> _tempWorkDir() async {
    final tmp = await getTemporaryDirectory();
    final target = Directory(p.join(tmp.path, 'zen_cuts'));
    if (!await target.exists()) {
      await target.create(recursive: true);
    }
    return target;
  }

  /// Cuts [originalPath] between [start] and [end] (both offsets from the
  /// start of the song), reusing an in-flight cut of the same song+range
  /// instead of starting a second one if called twice in a row.
  Future<CutRecord> cut({
    required String originalPath,
    required Duration start,
    required Duration end,
    required String baseTitle,
    void Function(double progress)? onProgress,
  }) {
    if (start < Duration.zero || end <= start) {
      return Future.error(
          CutException(CutErrorType.invalidRange, 'End time must be greater than start time.'));
    }

    final key = _keyFor(originalPath, start, end);
    final existingInFlight = _inFlight[key];
    if (existingInFlight != null) return existingInFlight;

    final future = _runCut(
      originalPath: originalPath,
      start: start,
      end: end,
      baseTitle: baseTitle,
      key: key,
      onProgress: onProgress,
    );
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key));
    return future;
  }

  Future<CutRecord> _runCut({
    required String originalPath,
    required Duration start,
    required Duration end,
    required String baseTitle,
    required String key,
    void Function(double progress)? onProgress,
  }) async {
    final inputFile = File(originalPath);
    if (!await inputFile.exists()) {
      throw CutException(CutErrorType.invalidFile, 'Original file not found.');
    }

    final existing = await findExisting(originalPath, start, end);
    if (existing != null) return existing;

    final ext = p.extension(originalPath).toLowerCase();
    if (!_supportedExtensions.contains(ext)) {
      throw CutException(CutErrorType.unsupportedFormat, 'Unsupported audio format "$ext".');
    }

    final durationMs = await _probeDurationMs(originalPath);
    if (durationMs > 0 && start.inMilliseconds >= durationMs) {
      throw CutException(CutErrorType.invalidRange, 'Start time is at or past the end of the song.');
    }
    if (durationMs > 0 && end.inMilliseconds > durationMs + 500) {
      throw CutException(CutErrorType.invalidRange, 'End time exceeds the song duration.');
    }

    final safeBase = baseTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    final baseName = safeBase.isEmpty ? p.basenameWithoutExtension(originalPath) : safeBase;

    // A different range on the same song must not silently overwrite (or be
    // blocked by) a previous cut already sitting in Downloads under the
    // default name — disambiguate with a numeric suffix instead.
    var outName = '${baseName}_Cut.mp3';
    var attempt = 1;
    while (attempt <= 50) {
      final existingDownload = await PublicStorageService.instance.lookupExisting(outName);
      if (existingDownload == null) break;
      attempt++;
      outName = '${baseName}_Cut($attempt).mp3';
    }

    Directory workDir;
    try {
      workDir = await _tempWorkDir();
    } on FileSystemException catch (e) {
      throw CutException(
          CutErrorType.permissionFailure, 'Could not prepare a temporary workspace: ${e.message}');
    }

    final tempOutPath = p.join(workDir.path, outName);
    final tempOutFile = File(tempOutPath);
    if (await tempOutFile.exists()) {
      try {
        await tempOutFile.delete();
      } catch (_) {}
    }

    final startSec = start.inMilliseconds / 1000.0;
    final endSec = end.inMilliseconds / 1000.0;
    final isMp3Source = ext == '.mp3';

    String escape(String path) => path.replaceAll('"', '\\"');
    // MP3 has no real keyframes — every frame decodes independently — so a
    // fast, lossless stream copy cut is both correct and quick for an mp3
    // source. Any other container/codec can't be copied straight into an
    // .mp3 file, so it's re-encoded with libmp3lame instead; seeking after
    // -i there trades a bit of speed for frame-accurate output.
    final command = isMp3Source
        ? '-y -ss $startSec -to $endSec -i "${escape(originalPath)}" -map_metadata 0 -map 0:a:0 -map 0:v? '
            '-c copy "${escape(tempOutPath)}"'
        : '-y -i "${escape(originalPath)}" -ss $startSec -to $endSec -map_metadata 0 -map 0:a:0 -map 0:v? '
            '-c:v copy -id3v2_version 3 -c:a libmp3lame -b:a 192k "${escape(tempOutPath)}"';

    final completer = Completer<CutRecord>();
    final clipDurationMs = ((endSec - startSec) * 1000).round();

    Future<void> finish(FFmpegSession session) async {
      try {
        final returnCode = await session.getReturnCode();
        if (_activeSessionId == session.getSessionId()) {
          _activeSessionId = null;
        }

        if (ReturnCode.isSuccess(returnCode)) {
          if (!await tempOutFile.exists() || await tempOutFile.length() == 0) {
            completer.completeError(CutException(
              CutErrorType.conversionFailed,
              'Cutting produced no output — the source file may be corrupted.',
            ));
            return;
          }

          try {
            final published = await PublicStorageService.instance.publish(
              sourcePath: tempOutPath,
              displayName: outName,
            );
            final finalPath = published.path;
            if (finalPath == null || finalPath.isEmpty) {
              throw CutException(
                  CutErrorType.storageFailure, 'Could not resolve the saved file location in Downloads.');
            }
            final record = CutRecord(
              originalPath: originalPath,
              cutPath: finalPath,
              start: start,
              end: end,
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
              completer.completeError(e is CutException
                  ? e
                  : CutException(CutErrorType.conversionFailed, 'Failed to save to Downloads: $e'));
            }
          } finally {
            try {
              if (await tempOutFile.exists()) await tempOutFile.delete();
            } catch (_) {}
          }
        } else if (ReturnCode.isCancel(returnCode)) {
          try {
            if (await tempOutFile.exists()) await tempOutFile.delete();
          } catch (_) {}
          completer.completeError(CutException(CutErrorType.cancelled, 'Cutting cancelled.'));
        } else {
          try {
            if (await tempOutFile.exists()) await tempOutFile.delete();
          } catch (_) {}
          final trace = (await session.getFailStackTrace())?.toLowerCase() ?? '';
          final logs = (await session.getAllLogsAsString())?.trim();
          final combined = '$trace ${logs ?? ''}'.toLowerCase();
          final isStorage = combined.contains('no space') || combined.contains('enospc');
          final isPermission = combined.contains('permission denied') || combined.contains('eacces');
          final detail = (logs != null && logs.isNotEmpty)
              ? logs
              : (await session.getFailStackTrace()) ?? 'Unknown ffmpeg error.';
          completer.completeError(CutException(
            isStorage
                ? CutErrorType.storageFailure
                : isPermission
                    ? CutErrorType.permissionFailure
                    : CutErrorType.conversionFailed,
            isStorage
                ? 'Not enough storage space to save the cut file.'
                : isPermission
                    ? 'Permission denied while writing the cut file.'
                    : 'Audio cutting failed: $detail',
          ));
        }
      } catch (e) {
        if (!completer.isCompleted) {
          completer.completeError(CutException(CutErrorType.conversionFailed, 'Cutting failed: $e'));
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
        if (onProgress == null || clipDurationMs <= 0) return;
        final time = stat.getTime();
        if (time > 0) {
          onProgress((time / clipDurationMs).clamp(0.0, 1.0));
        }
      },
    );
    _activeSessionId = session.getSessionId();

    return completer.future;
  }

  CutException _mapStorageException(PublicStorageException e) {
    switch (e.type) {
      case PublicStorageErrorType.permissionFailure:
        return CutException(CutErrorType.permissionFailure, e.message);
      case PublicStorageErrorType.storageFailure:
        return CutException(CutErrorType.storageFailure, e.message);
      case PublicStorageErrorType.invalidSource:
        return CutException(CutErrorType.invalidFile, e.message);
      case PublicStorageErrorType.unsupportedPlatform:
        return CutException(CutErrorType.conversionFailed, e.message);
      case PublicStorageErrorType.ioFailure:
        return CutException(CutErrorType.conversionFailed, e.message);
    }
  }

  /// Cancels whichever cut is currently running (used by the progress
  /// dialog's Cancel button).
  Future<void> cancelActive() async {
    if (_activeSessionId != null) {
      await FFmpegKit.cancel(_activeSessionId);
    } else {
      await FFmpegKit.cancel();
    }
  }
}
