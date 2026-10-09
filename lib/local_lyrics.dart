// lib/local_lyrics_manager.dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:hive/hive.dart';

/// LocalLyricsManager
///
/// Responsible for storing, retrieving and streaming lyrics reliably using Hive.
/// It intentionally preserves leading/trailing whitespace (so pasted lyrics remain exact),
/// but normalizes newline sequences to '\n'. The manager also provides helpers to
/// return lyrics prepared for display (with optional top/bottom blank-line padding)
/// which helps prevent UI clipping of the first/last lines. Additionally there are
/// helpers specifically intended for pre-filling Add/Edit lyrics dialogs which add
/// configurable leading blank lines (default 2) so the edit box shows space at the top.
class LocalLyricsManager {
  static const String _boxName = 'local_lyrics';
  static Box<String>? _box;

  /// Call early in app startup: await LocalLyricsManager.init();
  static Future<void> init() async {
    if (_box == null || !_box!.isOpen) {
      _box = await Hive.openBox<String>(_boxName);
    }
  }

  /// Ensure box is ready and return it.
  static Future<Box<String>> _ensureBox() async {
    if (_box == null || !_box!.isOpen) {
      _box = await Hive.openBox<String>(_boxName);
    }
    return _box!;
  }

  /// Normalize newlines: CRLF -> LF and CR -> LF.
  /// Do NOT trim whitespace — preserve exact pasted content.
  static String _normalizeNewlines(String s) {
    return s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  /// Return lyrics as stored (normalized newlines), or null if not present.
  static Future<String?> getLyrics(String filePath) async {
    try {
      final box = await _ensureBox();
      final v = box.get(filePath);
      if (v is String) return _normalizeNewlines(v);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Save lyrics for the filePath (normalizes newlines only).
  static Future<void> saveLyrics(String filePath, String lyrics) async {
    final box = await _ensureBox();
    final normalized = _normalizeNewlines(lyrics);
    await box.put(filePath, normalized);
  }

  /// Delete lyrics entry.
  static Future<void> deleteLyrics(String filePath) async {
    final box = await _ensureBox();
    await box.delete(filePath);
  }

  /// Clear all stored lyrics.
  static Future<void> clearAll() async {
    final box = await _ensureBox();
    await box.clear();
  }

  /// Return list of all keys (file paths).
  static Future<List<String>> getAllKeys() async {
    final box = await _ensureBox();
    return box.keys.map((k) => k.toString()).toList();
  }

  /// Return map filePath -> lyrics for all entries.
  static Future<Map<String, String>> getAllLyrics() async {
    final box = await _ensureBox();
    final out = <String, String>{};
    for (final key in box.keys) {
      final v = box.get(key);
      if (v is String) out[key.toString()] = _normalizeNewlines(v);
    }
    return out;
  }

  /// Export all lyrics as JSON bytes (backup).
  static Future<Uint8List> exportAllAsJsonBytes() async {
    final map = await getAllLyrics();
    final jsonStr = jsonEncode(map);
    return Uint8List.fromList(utf8.encode(jsonStr));
  }

  /// Internal helper to add top/bottom blank-line padding.
  /// topPadding / bottomPadding = number of extra '\n' lines to add.
  /// This is useful for display: UI can request extra blank lines at the end
  /// to avoid the last lyric being hidden by bottom nav / safe area.
  static String _applyDisplayPadding(String s, {int topPadding = 0, int bottomPadding = 0}) {
    if (topPadding <= 0 && bottomPadding <= 0) return s;
    final sb = StringBuffer();
    for (var i = 0; i < topPadding; i++) sb.writeln();
    sb.write(s);
    for (var i = 0; i < bottomPadding; i++) sb.writeln();
    return sb.toString();
  }

  /// Get lyrics prepared for display. This returns the normalized lyrics with
  /// optional top/bottom blank-line padding to prevent UI clipping.
  ///
  /// Default padding: top = 1, bottom = 6 (bottom padding larger to ensure final lines are reachable).
  static Future<String?> getLyricsForDisplay(
      String filePath, {
        int topPadding = 1,
        int bottomPadding = 6,
      }) async {
    final raw = await getLyrics(filePath);
    if (raw == null) return null;
    return _applyDisplayPadding(raw, topPadding: topPadding, bottomPadding: bottomPadding);
  }

  /// New: Get lyrics prepared specifically for the Add / Edit dialog.
  /// By default it adds 2 leading blank lines so the edit box shows space at the top.
  /// The saved lyrics themselves are not modified.
  static Future<String?> getLyricsForEdit(
      String filePath, {
        int leadingLines = 2,
      }) async {
    final raw = await getLyrics(filePath);
    if (raw == null) return null;
    // For edit box we add leading blank lines but avoid adding bottom padding.
    return _applyDisplayPadding(raw, topPadding: leadingLines, bottomPadding: 0);
  }

  /// Provide a stream of the normalized lyrics (no padding).
  /// Emits current value immediately and then on subsequent changes.
  /// Caller must cancel subscription when done (if using listen()).
  static Stream<String?> lyricsStream(String filePath) async* {
    final box = await _ensureBox();
    // Emit current
    final cur = box.get(filePath);
    yield cur is String ? _normalizeNewlines(cur) : null;
    // Then watch future changes
    yield* box.watch(key: filePath).map<String?>((event) {
      final val = event.value;
      if (val is String) return _normalizeNewlines(val);
      return null;
    });
  }

  /// Provide a stream of lyrics prepared for display (with padding).
  /// Useful to bind directly to the UI so the view always has the padding applied.
  static Stream<String?> lyricsStreamForDisplay(
      String filePath, {
        int topPadding = 1,
        int bottomPadding = 6,
      }) async* {
    await for (final s in lyricsStream(filePath)) {
      if (s == null) {
        yield null;
      } else {
        yield _applyDisplayPadding(s, topPadding: topPadding, bottomPadding: bottomPadding);
      }
    }
  }

  /// New: Provide a stream of lyrics prepared for Edit (with leading blank lines).
  /// Useful to bind an edit TextField so it always has the requested top spacing.
  static Stream<String?> lyricsStreamForEdit(
      String filePath, {
        int leadingLines = 2,
      }) async* {
    await for (final s in lyricsStream(filePath)) {
      if (s == null) {
        yield null;
      } else {
        yield _applyDisplayPadding(s, topPadding: leadingLines, bottomPadding: 0);
      }
    }
  }

  /// Return lyrics as list of lines (preserves empty lines).
  /// Useful when your UI wants to render per-line widgets (e.g. LRC-like behavior).
  static Future<List<String>> getLyricsLines(String filePath) async {
    final raw = await getLyrics(filePath);
    if (raw == null || raw.isEmpty) return <String>[];
    return raw.split('\n');
  }
}
