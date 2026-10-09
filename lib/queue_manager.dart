// lib/queue_manager.dart
//
// Multiple queues (Musicolet-style), with zero extra effort for the user:
//  * Whenever the play queue is REPLACED by a different list (playing an
//    album, a playlist, Smart Mix …), the queue you were in is kept as a
//    "recent queue" together with the song and position you were at.
//  * Tapping a saved queue switches to it and resumes exactly there; the
//    queue you leave is saved the same way, so you can hop back and forth.
//  * Queues can be pinned (and renamed) so they're never evicted; unpinned
//    recent queues are capped at [maxRecent].
// Small queue edits (add/remove one song, reorder) are not replacements.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'player_screen.dart' show PlaylistContext;

class SavedQueue {
  final String id;
  String name;
  List<String> paths;
  String? currentPath;
  int positionMs;
  bool pinned;
  int updatedAt;

  SavedQueue({
    required this.id,
    required this.name,
    required this.paths,
    this.currentPath,
    this.positionMs = 0,
    this.pinned = false,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'paths': paths,
        'currentPath': currentPath,
        'positionMs': positionMs,
        'pinned': pinned,
        'updatedAt': updatedAt,
      };

  static SavedQueue fromJson(Map<String, dynamic> m) => SavedQueue(
        id: m['id'] as String,
        name: m['name'] as String? ?? 'Queue',
        paths: List<String>.from(m['paths'] ?? const []),
        currentPath: m['currentPath'] as String?,
        positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
        pinned: m['pinned'] == true,
        updatedAt: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );
}

class QueueManager {
  QueueManager._();
  static final QueueManager instance = QueueManager._();

  static const _kQueues = 'saved_queues_v1';
  static const int maxRecent = 8;

  final List<SavedQueue> queues = [];
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Set by the host screen: start [queue] at its saved song/position.
  Future<void> Function(SavedQueue queue)? onLoad;

  List<String>? _lastPlaylist;
  String? _lastPageId;
  String? _lastPath;
  int _lastPosMs = 0;
  bool _switching = false;
  AudioPlayer? _player;
  StreamSubscription<Duration>? _posSub;
  bool _loaded = false;

  Future<void> attach(AudioPlayer player) async {
    await load();
    _player = player;
    _lastPlaylist = PlaylistContext.getCurrentPlaylist();
    _lastPageId = PlaylistContext.getCurrentPageId();
    PlaylistContext.currentPlaylistNotifier.removeListener(_onPlaylistChanged);
    PlaylistContext.currentPlaylistNotifier.addListener(_onPlaylistChanged);
    _posSub?.cancel();
    // Remember where we are in the current queue (sampled once a second).
    _posSub = player.positionStream.listen((pos) {
      final path = PlaylistContext.currentPathNotifier.value;
      if (path == null) return;
      final list = _lastPlaylist;
      if (list != null && list.contains(path)) {
        _lastPath = path;
        _lastPosMs = pos.inMilliseconds;
      }
    });
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kQueues);
      if (raw != null) {
        queues
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((e) => SavedQueue.fromJson(Map<String, dynamic>.from(e))));
      }
    } catch (e) {
      debugPrint('QueueManager load failed: $e');
    }
  }

  Future<void> _save() async {
    changes.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kQueues, jsonEncode(queues.map((q) => q.toJson()).toList()));
    } catch (_) {}
  }

  /// Pure rule (unit-tested): is [next] a different queue rather than an
  /// edit (single add/remove, or reorder) of [prev]?
  @visibleForTesting
  static bool isReplacement(List<String>? prev, List<String> next, {String? prevPage, String? nextPage}) {
    if (prev == null || prev.isEmpty) return false;
    if (listEquals(prev, next)) return false;
    // Playing from a different list (Songs → an album, Most Played …).
    if (prevPage != null && nextPage != null && prevPage != nextPage) return true;
    if (setEquals(prev.toSet(), next.toSet())) return false; // reorder
    if ((prev.length - next.length).abs() == 1) {
      final (small, big) = prev.length < next.length ? (prev, next) : (next, prev);
      if (_isSubsequence(small, big)) return false; // single add/remove, order kept
    }
    return true;
  }

  static bool _isSubsequence(List<String> small, List<String> big) {
    var i = 0;
    for (final x in big) {
      if (i < small.length && small[i] == x) i++;
    }
    return i == small.length;
  }

  void _onPlaylistChanged() {
    final next = PlaylistContext.currentPlaylistNotifier.value;
    if (next == null) return;
    final prev = _lastPlaylist;
    final prevPage = _lastPageId;
    final nextPage = PlaylistContext.getCurrentPageId();
    _lastPlaylist = List.of(next);
    _lastPageId = nextPage;
    if (_switching) return;
    if (prev == null || prev.length < 2 || !isReplacement(prev, next, prevPage: prevPage, nextPage: nextPage)) return;
    final path = (_lastPath != null && prev.contains(_lastPath)) ? _lastPath : prev.first;
    _remember(prev, path, path == _lastPath ? _lastPosMs : 0);
  }

  static String _autoName(List<String> paths) {
    final dirs = paths.map(p.dirname).toSet();
    if (dirs.length == 1) return p.basename(dirs.first);
    return '${paths.length} songs';
  }

  void _remember(List<String> paths, String? currentPath, int posMs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Same list already saved? Just update where we were.
    for (final q in queues) {
      if (listEquals(q.paths, paths)) {
        q.currentPath = currentPath;
        q.positionMs = posMs;
        q.updatedAt = now;
        _sortAndTrim();
        unawaited(_save());
        return;
      }
    }
    queues.add(SavedQueue(
      id: now.toString(),
      name: _autoName(paths),
      paths: List.of(paths),
      currentPath: currentPath,
      positionMs: posMs,
      updatedAt: now,
    ));
    _sortAndTrim();
    unawaited(_save());
  }

  void _sortAndTrim() {
    queues.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    var unpinned = 0;
    queues.removeWhere((q) => !q.pinned && ++unpinned > maxRecent);
  }

  /// Saves the queue that's playing now as a pinned, named queue.
  Future<void> pinCurrent(String name) async {
    final list = PlaylistContext.getCurrentPlaylist();
    if (list == null || list.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = queues.where((q) => listEquals(q.paths, list)).toList();
    if (existing.isNotEmpty) {
      existing.first
        ..pinned = true
        ..name = name
        ..updatedAt = now;
    } else {
      queues.add(SavedQueue(
        id: now.toString(),
        name: name,
        paths: List.of(list),
        currentPath: PlaylistContext.currentPathNotifier.value,
        positionMs: _player?.position.inMilliseconds ?? 0,
        pinned: true,
        updatedAt: now,
      ));
    }
    _sortAndTrim();
    await _save();
  }

  Future<void> togglePin(SavedQueue q) async {
    q.pinned = !q.pinned;
    _sortAndTrim();
    await _save();
  }

  Future<void> rename(SavedQueue q, String name) async {
    if (name.trim().isEmpty) return;
    q.name = name.trim();
    await _save();
  }

  Future<void> delete(SavedQueue q) async {
    queues.remove(q);
    await _save();
  }

  /// Switches playback to [q], first saving the queue being left.
  Future<void> switchTo(SavedQueue q) async {
    final current = PlaylistContext.getCurrentPlaylist();
    if (current != null && current.length >= 2 && !listEquals(current, q.paths)) {
      final path = PlaylistContext.currentPathNotifier.value;
      _remember(current, path, _player?.position.inMilliseconds ?? 0);
    }
    _switching = true;
    try {
      q.updatedAt = DateTime.now().millisecondsSinceEpoch;
      _sortAndTrim();
      await _save();
      await onLoad?.call(q);
      _lastPlaylist = PlaylistContext.getCurrentPlaylist();
      _lastPageId = PlaylistContext.getCurrentPageId();
    } finally {
      _switching = false;
    }
  }
}
