// lib/public_storage_service.dart
//
// Publishes locally-rendered audio files (4D/8D conversions, Audio Cutter
// output) to the phone's public Downloads folder. On Android 10+, scoped
// storage blocks a plain dart:io File write to /storage/emulated/0/Download,
// so the actual copy happens natively via MediaStore — see
// MainActivity.kt's DOWNLOADS_CHANNEL handler. This service is just the
// Dart-side wrapper: permission handling, error mapping, and a lookup used
// to reuse an already-published file instead of re-rendering it.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum PublicStorageErrorType {
  invalidSource,
  permissionFailure,
  storageFailure,
  ioFailure,
  unsupportedPlatform,
}

class PublicStorageException implements Exception {
  final PublicStorageErrorType type;
  final String message;
  PublicStorageException(this.type, this.message);
  @override
  String toString() => message;
}

class PublishedFile {
  final String? path;
  final String uri;
  final int size;
  final bool reused;
  PublishedFile({required this.path, required this.uri, required this.size, required this.reused});
}

class PublicStorageService {
  PublicStorageService._internal();
  static final PublicStorageService instance = PublicStorageService._internal();

  static const MethodChannel _channel = MethodChannel('music_app/downloads');

  int? _cachedSdkInt;

  /// Device API level (cached); 29 if it cannot be determined.
  Future<int> sdkInt() => _sdkInt();

  Future<int> _sdkInt() async {
    final cached = _cachedSdkInt;
    if (cached != null) return cached;
    try {
      final sdkInt = await _channel.invokeMethod<int>('getSdkInt') ?? 0;
      _cachedSdkInt = sdkInt;
      return sdkInt;
    } catch (_) {
      // Unknown SDK — assume modern Android so we don't gate on a
      // permission that no longer does anything (see below).
      return 29;
    }
  }

  // MediaStore writes into Downloads need no runtime storage permission at
  // all on Android 10+ (API 29+): the app owns the MediaStore.Downloads
  // entry it inserts. Worse, on Android 11+ (and definitely once the app
  // targets API 30+, as this one does) the OS auto-denies a
  // READ/WRITE_EXTERNAL_STORAGE request without ever showing a dialog,
  // since those permissions are legacy and scoped storage has superseded
  // them. So gating the export on Permission.storage for those versions
  // doesn't protect anything — it just throws every time. Only pre-Q
  // (API <= 28) devices, where publishToDownloads() falls back to a plain
  // File write, actually need this permission.
  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    if (await _sdkInt() >= 29) return true;
    try {
      final status = await Permission.storage.status;
      if (status.isGranted || status.isLimited) return true;
      final requested = await Permission.storage.request();
      return requested.isGranted || requested.isLimited || requested.isRestricted;
    } catch (_) {
      return true;
    }
  }

  /// Looks up a file already published to Downloads as [displayName],
  /// without copying anything. Used to skip an entire conversion/cut job
  /// when valid output is already there.
  Future<PublishedFile?> lookupExisting(String displayName) async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod('lookupDownload', {'displayName': displayName});
      if (raw == null) return null;
      final map = Map<String, dynamic>.from(raw as Map);
      final size = (map['size'] as num?)?.toInt() ?? 0;
      if (size <= 0) return null;
      final path = map['path'] as String?;
      if (path != null && !(await File(path).exists())) return null;
      return PublishedFile(path: path, uri: map['uri'] as String? ?? '', size: size, reused: true);
    } catch (_) {
      return null;
    }
  }

  /// Copies [sourcePath] (a temp file produced by ffmpeg) into the public
  /// Downloads folder as [displayName]. Reuses an existing valid file with
  /// the same name instead of copying again.
  Future<PublishedFile> publish({
    required String sourcePath,
    required String displayName,
    String mimeType = 'audio/mpeg',
  }) async {
    if (!Platform.isAndroid) {
      throw PublicStorageException(
        PublicStorageErrorType.unsupportedPlatform,
        'Saving to Downloads is only supported on Android.',
      );
    }

    final source = File(sourcePath);
    if (!await source.exists() || await source.length() <= 0) {
      throw PublicStorageException(PublicStorageErrorType.invalidSource, 'Source file is missing or empty.');
    }

    if (!await _ensurePermission()) {
      throw PublicStorageException(
        PublicStorageErrorType.permissionFailure,
        'Storage permission is required to save to Downloads.',
      );
    }

    try {
      final raw = await _channel.invokeMethod('publishToDownloads', {
        'sourcePath': sourcePath,
        'displayName': displayName,
        'mimeType': mimeType,
      });
      final map = Map<String, dynamic>.from(raw as Map);
      return PublishedFile(
        path: map['path'] as String?,
        uri: map['uri'] as String? ?? '',
        size: (map['size'] as num?)?.toInt() ?? 0,
        reused: map['reused'] == true,
      );
    } on PlatformException catch (e) {
      switch (e.code) {
        case 'permission_error':
          throw PublicStorageException(PublicStorageErrorType.permissionFailure, e.message ?? 'Permission denied.');
        case 'storage_error':
          throw PublicStorageException(
              PublicStorageErrorType.storageFailure, e.message ?? 'Not enough storage space.');
        case 'invalid_source':
          throw PublicStorageException(PublicStorageErrorType.invalidSource, e.message ?? 'Invalid source file.');
        default:
          throw PublicStorageException(
              PublicStorageErrorType.ioFailure, e.message ?? 'Failed to save file to Downloads.');
      }
    }
  }
}
