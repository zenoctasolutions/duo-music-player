// lib/library_service.dart
//
// Library-level settings and stats shared across screens:
//  * [LibraryInfo]    — per-file date-added / duration straight from
//                       MediaStore (no per-file metadata read needed).
//  * [LibraryFilter]  — excluded folders + minimum song length, so voice
//                       notes, call recordings and notification sounds
//                       don't clutter the library.
//  * [SongSort]       — the Songs list sort order.
//  * [PlayStats]      — per-song play counts for "Most Played".

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'media_store_service.dart';

// ------------------------------------------------------------------ info

class LibraryInfo {
  LibraryInfo._();

  /// Seconds since epoch the file was added to the device (MediaStore
  /// DATE_ADDED), falling back to the file's modified time.
  static final Map<String, int> dateAdded = {};

  /// Duration in milliseconds from MediaStore (0 / missing when unknown).
  static final Map<String, int> durationMs = {};

  static void ingest(List<MediaStoreAudio> entries) {
    for (final e in entries) {
      if (e.dateAdded > 0) dateAdded[e.path] = e.dateAdded;
      if (e.durationMs > 0) durationMs[e.path] = e.durationMs;
    }
  }

  static int dateAddedFor(String path) {
    final known = dateAdded[path];
    if (known != null) return known;
    try {
      final secs = File(path).statSync().modified.millisecondsSinceEpoch ~/ 1000;
      dateAdded[path] = secs;
      return secs;
    } catch (_) {
      return 0;
    }
  }
}

// ---------------------------------------------------------------- filter

class LibraryFilter {
  LibraryFilter._();

  static const _kExcluded = 'library_excluded_folders';
  static const _kMinDuration = 'library_min_duration_sec';

  /// Choices offered in the UI (0 = show everything).
  static const List<int> minDurationChoices = [0, 10, 30, 60];

  static Set<String> _excluded = {};
  static int _minDurationSec = 0;
  static bool _loaded = false;

  /// Bumped whenever the filter changes; the library rescans on it.
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static Set<String> get excludedFolders => Set.unmodifiable(_excluded);
  static int get minDurationSec => _minDurationSec;
  static bool get isActive => _excluded.isNotEmpty || _minDurationSec > 0;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _excluded = (prefs.getStringList(_kExcluded) ?? const []).toSet();
      _minDurationSec = prefs.getInt(_kMinDuration) ?? 0;
    } catch (e) {
      debugPrint('LibraryFilter load failed: $e');
    }
    _loaded = true;
  }

  static Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_kExcluded, _excluded.toList());
    await prefs.setInt(_kMinDuration, _minDurationSec);
    changes.value++;
  }

  static Future<void> setExcluded(Set<String> folders) async {
    _excluded = folders.map(_norm).toSet();
    await _save();
  }

  static Future<void> setMinDuration(int seconds) async {
    _minDurationSec = seconds;
    await _save();
  }

  static String _norm(String folder) => p.normalize(folder).replaceAll(RegExp(r'/+$'), '');

  static bool isExcludedPath(String path) {
    if (_excluded.isEmpty) return false;
    final dir = p.dirname(path);
    for (final f in _excluded) {
      if (dir == f || p.isWithin(f, dir)) return true;
    }
    return false;
  }

  /// Whether [path] should appear in the library. [knownDurationMs] is used
  /// when MediaStore didn't report a duration (e.g. filesystem fallback);
  /// songs of unknown length are never hidden by the duration filter.
  static bool allows(String path, {int? knownDurationMs}) {
    if (isExcludedPath(path)) return false;
    if (_minDurationSec > 0) {
      final ms = LibraryInfo.durationMs[path] ?? knownDurationMs ?? 0;
      if (ms > 0 && ms < _minDurationSec * 1000) return false;
    }
    return true;
  }

  /// Every folder that contains audio (unfiltered), with its song count and
  /// how many of those the duration filter would hide — for the picker UI.
  static Future<List<FolderStat>> scanFolders() async {
    final entries = await MediaStoreService.instance.queryAudioFiles() ?? const <MediaStoreAudio>[];
    LibraryInfo.ingest(entries);
    final map = <String, FolderStat>{};
    for (final e in entries) {
      final dir = p.dirname(e.path);
      final stat = map.putIfAbsent(dir, () => FolderStat(dir));
      stat.count++;
      if (e.durationMs > 0 && e.durationMs < 30000) stat.shortCount++;
    }
    final list = map.values.toList()..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
    return list;
  }
}

class FolderStat {
  final String path;
  int count = 0;

  /// Files under 30 seconds (likely voice notes / notification sounds).
  int shortCount = 0;
  FolderStat(this.path);

  String get name => p.basename(path);
}

// ------------------------------------------------------------------ sort

enum SongSortField { title, artist, album, dateAdded, duration, fileName }

class SongSort {
  SongSort._();

  static const _kField = 'songs_sort_field';
  static const _kAsc = 'songs_sort_ascending';

  static SongSortField field = SongSortField.title;
  static bool ascending = true;

  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static String label(SongSortField f) => switch (f) {
        SongSortField.title => 'Title',
        SongSortField.artist => 'Artist',
        SongSortField.album => 'Album',
        SongSortField.dateAdded => 'Date added',
        SongSortField.duration => 'Duration',
        SongSortField.fileName => 'File name',
      };

  /// Whether the Songs list shows A–Z section headers for this sort.
  static bool usesLetterHeaders(SongSortField f) =>
      f == SongSortField.title || f == SongSortField.artist || f == SongSortField.album || f == SongSortField.fileName;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_kField);
      field = SongSortField.values.firstWhere((f) => f.name == name, orElse: () => SongSortField.title);
      ascending = prefs.getBool(_kAsc) ?? true;
    } catch (_) {}
  }

  static Future<void> set(SongSortField f, bool asc) async {
    field = f;
    ascending = asc;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kField, f.name);
    await prefs.setBool(_kAsc, asc);
  }
}

// ----------------------------------------------------------------- stats

class PlayStats {
  PlayStats._();

  static const _kCounts = 'play_counts_v1';
  static Map<String, int> _counts = {};
  static bool _loaded = false;
  static Timer? _saveDebounce;

  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCounts);
      if (raw != null) {
        _counts = (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toInt()));
      }
    } catch (e) {
      debugPrint('PlayStats load failed: $e');
    }
    _loaded = true;
  }

  static int countFor(String path) => _counts[path] ?? 0;

  static String? _lastPath;
  static DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<void> recordPlay(String path) async {
    // One song start can be reported by more than one code path (the direct
    // play call and the gapless queue's index-change handler), so ignore a
    // repeat of the same song within a few seconds.
    final now = DateTime.now();
    if (path == _lastPath && now.difference(_lastAt) < const Duration(seconds: 10)) return;
    _lastPath = path;
    _lastAt = now;
    await load();
    _counts[path] = (_counts[path] ?? 0) + 1;
    changes.value++;
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kCounts, jsonEncode(_counts));
      } catch (_) {}
    });
  }

  /// Songs from [library] with at least one play, most played first.
  static List<File> mostPlayed(List<File> library, {int limit = 50}) {
    final played = library.where((f) => countFor(f.path) > 0).toList()
      ..sort((a, b) => countFor(b.path).compareTo(countFor(a.path)));
    return played.take(limit).toList();
  }

  /// Newest additions to [library] first.
  static List<File> recentlyAdded(List<File> library, {int limit = 50}) {
    final sorted = List<File>.from(library)
      ..sort((a, b) => LibraryInfo.dateAddedFor(b.path).compareTo(LibraryInfo.dateAddedFor(a.path)));
    return sorted.take(limit).toList();
  }
}
