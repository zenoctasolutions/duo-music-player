// lib/media_store_service.dart
//
// Fast audio-library lookup via Android's MediaStore, used instead of a
// recursive dart:io directory walk across a dozen+ storage roots on every
// app open. MediaStore.Audio.Media is already kept up to date by the OS
// media scanner, so this is an indexed database query (fast, and always
// reflects newly-added files) rather than a filesystem crawl — see
// MainActivity's MEDIA_CHANNEL handler for the native side.
import 'dart:io';

import 'package:flutter/services.dart';

/// One row of the MediaStore audio table.
class MediaStoreAudio {
  final String path;
  final int durationMs;

  /// Seconds since epoch (MediaStore DATE_ADDED).
  final int dateAdded;

  /// File size in bytes (0 when unknown).
  final int sizeBytes;
  const MediaStoreAudio(this.path, this.durationMs, this.dateAdded, [this.sizeBytes = 0]);
}

/// Technical details of one audio file (format, bitrate, sample rate…).
class AudioFileInfo {
  final String? mime;
  final int? bitrate; // bits per second
  final int? sampleRate; // Hz
  final int? channels;
  final int? bitsPerSample;
  final int? durationMs;
  final int? sizeBytes;
  const AudioFileInfo({this.mime, this.bitrate, this.sampleRate, this.channels, this.bitsPerSample, this.durationMs, this.sizeBytes});
}

class MediaStoreService {
  MediaStoreService._internal();
  static final MediaStoreService instance = MediaStoreService._internal();

  static const MethodChannel _channel = MethodChannel('music_app/mediastore');

  /// Every audio file MediaStore currently knows about, with duration and
  /// date added, or null if the query isn't available (non-Android, or a
  /// platform failure).
  Future<List<MediaStoreAudio>?> queryAudioFiles() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('queryAudioFiles');
      if (raw == null) return null;
      final out = <MediaStoreAudio>[];
      for (final entry in raw) {
        if (entry is Map) {
          final path = entry['path'];
          if (path is String && path.isNotEmpty) {
            out.add(MediaStoreAudio(
              path,
              (entry['duration'] as num?)?.toInt() ?? 0,
              (entry['dateAdded'] as num?)?.toInt() ?? 0,
              (entry['size'] as num?)?.toInt() ?? 0,
            ));
          }
        }
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Returns every audio file path MediaStore currently knows about, or
  /// null if the query isn't available — callers should fall back to a
  /// manual scan in that case. [onEntries] receives the full rows (used to
  /// feed LibraryInfo without a second query).
  Future<List<String>?> queryAudioFilePaths({void Function(List<MediaStoreAudio>)? onEntries}) async {
    final entries = await queryAudioFiles();
    if (entries == null) return null;
    onEntries?.call(entries);
    return entries.map((e) => e.path).toList();
  }

  final Map<String, AudioFileInfo> _infoCache = {};

  /// Format/bitrate/sample-rate for [path] (cached), or null if unavailable.
  /// Already-fetched info for [path], without a platform call (null if
  /// not fetched yet).
  AudioFileInfo? cachedAudioInfo(String path) => _infoCache[path];

  Future<AudioFileInfo?> getAudioInfo(String path) async {
    final cached = _infoCache[path];
    if (cached != null) return cached;
    if (!Platform.isAndroid) return null;
    try {
      final m = await _channel.invokeMethod<Map>('getAudioInfo', {'path': path});
      if (m == null) return null;
      int? i(String k) {
        final v = (m[k] as num?)?.toInt();
        return (v == null || v <= 0) ? null : v;
      }

      final info = AudioFileInfo(
        mime: m['mime'] as String?,
        bitrate: i('bitrate'),
        sampleRate: i('sampleRate'),
        channels: i('channels'),
        bitsPerSample: i('bitsPerSample'),
        durationMs: i('durationMs'),
        sizeBytes: i('size'),
      );
      _infoCache[path] = info;
      return info;
    } catch (_) {
      return null;
    }
  }
}
