// lib/backup_service.dart
//
// Local export/import backup for user data that only lives on-device today:
// custom playlists, pasted lyrics, song + radio-station favorites, and the
// 4D/8D conversion-record cache. Writes a single JSON file the user shares
// (share_plus) or saves, and can re-import after a reinstall or device
// switch — a first step before any full cloud sync, reusing only
// dependencies already in the app.
import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'audio_conversion_service.dart';
import 'list_page.dart' show FavoritesNotifier;
import 'local_lyrics.dart';
import 'public_storage_service.dart';
import 'radio_service.dart';

const int kBackupFormatVersion = 1;
const String _playlistsBoxName = 'custom_playlists';
const String _queueKey = 'current_queue';

/// Fixed display name [importFromDownloads] looks for in the public
/// Downloads folder — there's no file-picker dependency in this app, so
/// import works off a known filename instead of an open file chooser (the
/// share sheet from [exportAndShare] lets the user save/rename the shared
/// file to this name in Downloads on the receiving device).
const String kBackupDownloadsFileName = 'duo_music_backup.json';

class BackupImportSummary {
  final int playlistsImported;
  final int lyricsImported;
  final int conversionsImported;
  final int favoritesImported;
  final int radioStationsImported;

  const BackupImportSummary({
    required this.playlistsImported,
    required this.lyricsImported,
    required this.conversionsImported,
    required this.favoritesImported,
    required this.radioStationsImported,
  });

  int get totalImported =>
      playlistsImported + lyricsImported + conversionsImported + favoritesImported + radioStationsImported;
}

class BackupService {
  BackupService._internal();
  static final BackupService instance = BackupService._internal();

  Future<Box> _openBox(String name) async {
    if (!Hive.isBoxOpen(name)) {
      await Hive.initFlutter();
      return Hive.openBox(name);
    }
    return Hive.box(name);
  }

  Future<Map<String, dynamic>> _collect() async {
    final playlistsBox = await _openBox(_playlistsBoxName);
    final playlists = <String, List<String>>{};
    for (final key in playlistsBox.keys) {
      if (key == _queueKey) continue;
      final val = playlistsBox.get(key);
      if (val is List) {
        playlists[key.toString()] = List<String>.from(val.map((e) => e.toString()));
      }
    }

    final lyrics = await LocalLyricsManager.getAllLyrics();
    final conversions = (await AudioConversionService.instance.allRecords()).map((r) => r.toMap()).toList();

    await FavoritesNotifier.instance.init();
    final favorites = FavoritesNotifier.instance.favoritesSet.toList();

    await RadioFavoritesNotifier.instance.init();
    final radioStations = RadioFavoritesNotifier.instance.favorites.map((s) => s.toJson()).toList();

    return {
      'formatVersion': kBackupFormatVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'playlists': playlists,
      'lyrics': lyrics,
      'conversions': conversions,
      'favorites': favorites,
      'radioStations': radioStations,
    };
  }

  Future<File> exportToFile() async {
    final data = await _collect();
    final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/duo_music_backup_${DateTime.now().millisecondsSinceEpoch}.json');
    await file.writeAsString(jsonStr);
    return file;
  }

  Future<void> exportAndShare() async {
    final file = await exportToFile();
    await Share.shareXFiles([XFile(file.path)], text: 'Duo Music Player backup');
  }

  /// Looks for [kBackupDownloadsFileName] in the public Downloads folder and
  /// imports it if found. Returns null (not an error) if no backup file is
  /// there yet.
  Future<BackupImportSummary?> importFromDownloads() async {
    final found = await PublicStorageService.instance.lookupExisting(kBackupDownloadsFileName);
    final path = found?.path;
    if (path == null) return null;
    return importFromFile(File(path));
  }

  /// Merges [file]'s contents into the current library. Existing playlists
  /// with the same name are overwritten by the backup (an explicit restore
  /// action); existing lyrics for a path are kept as-is (an imported entry
  /// never clobbers a pasted edit made after the backup was taken).
  /// Conversion records are only restored for files that still exist on
  /// disk at their recorded path.
  Future<BackupImportSummary> importFromFile(File file) async {
    final raw = await file.readAsString();
    final data = jsonDecode(raw) as Map<String, dynamic>;

    var playlistsImported = 0;
    var lyricsImported = 0;
    var conversionsImported = 0;
    var favoritesImported = 0;
    var radioStationsImported = 0;

    final playlists = data['playlists'];
    if (playlists is Map) {
      final box = await _openBox(_playlistsBoxName);
      for (final entry in playlists.entries) {
        if (entry.value is List) {
          await box.put(
            entry.key.toString(),
            List<String>.from((entry.value as List).map((e) => e.toString())),
          );
          playlistsImported++;
        }
      }
    }

    final lyrics = data['lyrics'];
    if (lyrics is Map) {
      final existingKeys = (await LocalLyricsManager.getAllKeys()).toSet();
      for (final entry in lyrics.entries) {
        final path = entry.key.toString();
        if (existingKeys.contains(path)) continue;
        if (entry.value is String) {
          await LocalLyricsManager.saveLyrics(path, entry.value as String);
          lyricsImported++;
        }
      }
    }

    final conversions = data['conversions'];
    if (conversions is List) {
      final box = await _openBox('audio_conversions');
      for (final rawRecord in conversions) {
        if (rawRecord is! Map) continue;
        try {
          final record = ConversionRecord.fromMap(Map<String, dynamic>.from(rawRecord));
          if (await File(record.convertedPath).exists()) {
            await box.put('${record.originalPath}::${record.type.name}', record.toMap());
            conversionsImported++;
          }
        } catch (_) {}
      }
    }

    final favorites = data['favorites'];
    if (favorites is List) {
      await FavoritesNotifier.instance.init();
      for (final path in favorites) {
        if (path is String && await File(path).exists()) {
          await FavoritesNotifier.instance.add(path);
          favoritesImported++;
        }
      }
    }

    final radioStations = data['radioStations'];
    if (radioStations is List) {
      await RadioFavoritesNotifier.instance.init();
      for (final rawStation in radioStations) {
        if (rawStation is! Map) continue;
        try {
          final station = RadioStation.fromJson(Map<String, dynamic>.from(rawStation));
          if (!RadioFavoritesNotifier.instance.contains(station.stationUuid)) {
            await RadioFavoritesNotifier.instance.toggle(station);
          }
          radioStationsImported++;
        } catch (_) {}
      }
    }

    return BackupImportSummary(
      playlistsImported: playlistsImported,
      lyricsImported: lyricsImported,
      conversionsImported: conversionsImported,
      favoritesImported: favoritesImported,
      radioStationsImported: radioStationsImported,
    );
  }
}
