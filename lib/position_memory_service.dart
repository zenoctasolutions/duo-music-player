// lib/position_memory_service.dart
//
// Audiobook / long-file mode: remembers where you stopped in long files
// (audiobooks, podcasts, DJ mixes, lectures) and resumes there the next
// time that file is played. Applies to files at least [minMinutes] long,
// and — optionally — to anything inside a folder whose name contains
// "audiobook", "podcast" or "book" regardless of length. Finishing a file
// (reaching its last 30 s) forgets the saved position so it starts fresh.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class PositionMemoryService {
  PositionMemoryService._();
  static final PositionMemoryService instance = PositionMemoryService._();

  static const _kEnabled = 'posmem_enabled';
  static const _kMinMinutes = 'posmem_min_minutes';
  static const _kFolders = 'posmem_audiobook_folders';
  static const _kPositions = 'posmem_positions_v1';
  static const List<int> minMinuteChoices = [10, 20, 30, 60];
  static const int _maxEntries = 300;

  bool enabled = true;
  int minMinutes = 20;
  bool audiobookFolders = true;

  /// Emits a message when playback was resumed ("Resumed at 12:34").
  final ValueNotifier<String?> resumed = ValueNotifier<String?>(null);

  final Map<String, int> _positions = {};
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  String? _currentPath;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _persist;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_kEnabled) ?? true;
      minMinutes = prefs.getInt(_kMinMinutes) ?? 20;
      audiobookFolders = prefs.getBool(_kFolders) ?? true;
      final raw = prefs.getString(_kPositions);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) => _positions[k] = (v as num).toInt());
      }
    } catch (e) {
      debugPrint('PositionMemory load failed: $e');
    }
  }

  Future<void> setOptions({bool? enabled, int? minMinutes, bool? audiobookFolders}) async {
    if (enabled != null) this.enabled = enabled;
    if (minMinutes != null) this.minMinutes = minMinutes;
    if (audiobookFolders != null) this.audiobookFolders = audiobookFolders;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, this.enabled);
    await prefs.setInt(_kMinMinutes, this.minMinutes);
    await prefs.setBool(_kFolders, this.audiobookFolders);
  }

  Future<void> attach(AudioPlayer player) async {
    await load();
    _player = player;
    _posSub?.cancel();
    _posSub = player.positionStream.listen(_onPosition);
  }

  /// Pure rule (unit-tested): does [path] of [duration] qualify?
  @visibleForTesting
  static bool qualifies({
    required String path,
    required Duration? duration,
    required int minMinutes,
    required bool audiobookFolders,
  }) {
    if (audiobookFolders) {
      final dir = p.dirname(path).toLowerCase();
      if (dir.contains('audiobook') || dir.contains('podcast') || RegExp(r'(^|/)books?(/|$)').hasMatch(dir)) {
        return true;
      }
    }
    return duration != null && duration >= Duration(minutes: minMinutes);
  }

  bool _qualifies(String path, Duration? d) =>
      enabled && qualifies(path: path, duration: d, minMinutes: minMinutes, audiobookFolders: audiobookFolders);

  void _onPosition(Duration pos) {
    final path = _currentPath;
    final player = _player;
    if (path == null || player == null) return;
    final dur = player.duration;
    if (!_qualifies(path, dur)) return;
    if (dur != null && dur - pos < const Duration(seconds: 30)) {
      // Finished (or nearly): next time start from the beginning.
      if (_positions.remove(path) != null) _schedulePersist();
      return;
    }
    if (pos < const Duration(seconds: 10)) return;
    if (DateTime.now().difference(_lastSave) < const Duration(seconds: 5)) return;
    _lastSave = DateTime.now();
    _positions.remove(path); // re-insert = most recent last
    _positions[path] = pos.inMilliseconds;
    while (_positions.length > _maxEntries) {
      _positions.remove(_positions.keys.first);
    }
    _schedulePersist();
  }

  /// Called whenever the playing file changes.
  Future<void> onTrackChanged(String? path) async {
    // Save the outgoing file's final position immediately.
    final old = _currentPath;
    final player = _player;
    if (old != null && player != null && _positions.containsKey(old)) _persistNow();
    _currentPath = path;
    if (path == null || player == null || !enabled) return;
    final saved = _positions[path];
    if (saved == null) return;

    // Wait for the new source's duration (it's what decides eligibility).
    Duration? dur = player.duration;
    for (var i = 0; i < 30 && (dur == null || _currentPath != path); i++) {
      await Future.delayed(const Duration(milliseconds: 100));
      dur = player.duration;
    }
    if (_currentPath != path || !_qualifies(path, dur)) return;
    final target = Duration(milliseconds: saved);
    if (dur != null && target >= dur - const Duration(seconds: 30)) return;
    // Only jump forward from the very start — never override a manual seek.
    if (player.position > const Duration(seconds: 5)) return;
    await player.seek(target);
    resumed.value = null;
    resumed.value = 'Resumed at ${_fmt(target)}';
  }

  Future<void> forget(String path) async {
    if (_positions.remove(path) != null) _schedulePersist();
  }

  int get rememberedCount => _positions.length;

  static String _fmt(Duration d) {
    final h = d.inHours, m = d.inMinutes.remainder(60), s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  void _schedulePersist() {
    _persist?.cancel();
    _persist = Timer(const Duration(seconds: 3), _persistNow);
  }

  Future<void> _persistNow() async {
    _persist?.cancel();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPositions, jsonEncode(_positions));
    } catch (_) {}
  }
}
