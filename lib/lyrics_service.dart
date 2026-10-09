// lib/lyrics_service.dart
//
// Lyrics sources and LRC parsing for the Now Playing lyrics page.
//
// Lookup order for a song (first hit wins):
//   1. Lyrics the user saved/pasted or previously downloaded (Hive,
//      LocalLyricsManager).
//   2. Lyrics embedded in the file's tags (ID3 USLT / Vorbis LYRICS / MP4
//      ©lyr), read with audio_metadata_reader.
//   3. A sidecar .lrc file next to the song ("Song.lrc" or "Song.mp3.lrc").
//   4. Only when the user taps "Find synced lyrics": an online lookup on
//      LRCLIB (lrclib.net — free, open, no API key). Results are saved via
//      LocalLyricsManager so they work offline afterwards.

import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'local_lyrics.dart';

class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class ParsedLyrics {
  /// Timestamped lines sorted by time (synced) or plain lines (time zero).
  final List<LyricLine> lines;

  /// True when at least one line carried an LRC timestamp.
  final bool synced;
  const ParsedLyrics(this.lines, this.synced);
}

class LrcParser {
  LrcParser._();

  static final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  static final _metaTag = RegExp(r'^\[([a-zA-Z#]+):(.*)\]\s*$');
  static final _wordTag = RegExp(r'<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>');

  // "00:12.34 Line" / "(0:12) Line" — timed lyrics copied from sites that
  // drop the LRC brackets. Only honoured when most lines look like this, so
  // an ordinary lyric that happens to start with "2:30" stays plain.
  static final _bareTime = RegExp(r'^\s*\(?(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\)?\s+(?=\S)');

  static String _bracketBareTimestamps(String text) {
    final lines = text.split('\n');
    final nonEmpty = lines.where((l) => l.trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) return text;
    final bare = nonEmpty.where((l) => _bareTime.hasMatch(l)).length;
    if (bare * 2 < nonEmpty.length) return text;
    return lines.map((l) {
      final m = _bareTime.firstMatch(l);
      if (m == null) return l;
      final frac = m.group(3);
      return '[${m.group(1)}:${m.group(2)}${frac == null ? '' : '.$frac'}]${l.substring(m.end)}';
    }).join('\n');
  }

  /// Formats [lines] as LRC ("[mm:ss.xx]text" per line).
  static String toLrc(List<LyricLine> lines) {
    String stamp(Duration d) {
      final cs = (d.inMilliseconds / 10).round();
      final m = cs ~/ 6000;
      final s = (cs % 6000) ~/ 100;
      final c = cs % 100;
      return '[${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${c.toString().padLeft(2, '0')}]';
    }

    return lines.map((l) => '${stamp(l.time)}${l.text}').join('\n');
  }

  /// Parses LRC (including multiple timestamps per line, [offset:±ms] and
  /// enhanced word-timing tags) or plain text.
  static ParsedLyrics parse(String raw) {
    final text = _bracketBareTimestamps(raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
    var offsetMs = 0;
    final timed = <LyricLine>[];
    final plain = <LyricLine>[];

    for (final line in text.split('\n')) {
      final times = _timeTag.allMatches(line).toList();
      if (times.isEmpty) {
        final meta = _metaTag.firstMatch(line.trim());
        if (meta != null) {
          if (meta.group(1)!.toLowerCase() == 'offset') {
            offsetMs = int.tryParse(meta.group(2)!.trim().replaceAll('+', '')) ?? 0;
          }
          continue; // [ar:], [ti:], [al:], [by:], [length:] …
        }
        plain.add(LyricLine(Duration.zero, line));
        continue;
      }
      // Lyric text is whatever follows the last timestamp.
      final lyric = line.substring(times.last.end).replaceAll(_wordTag, '').trim();
      for (final t in times) {
        final m = int.parse(t.group(1)!);
        final s = int.parse(t.group(2)!);
        final frac = t.group(3);
        final ms = frac == null ? 0 : int.parse(frac.padRight(3, '0').substring(0, 3));
        timed.add(LyricLine(Duration(minutes: m, seconds: s, milliseconds: ms), lyric));
      }
    }

    if (timed.isEmpty) {
      // Drop leading/trailing blank lines of plain lyrics.
      while (plain.isNotEmpty && plain.first.text.trim().isEmpty) {
        plain.removeAt(0);
      }
      while (plain.isNotEmpty && plain.last.text.trim().isEmpty) {
        plain.removeLast();
      }
      return ParsedLyrics(plain, false);
    }

    // A positive LRC offset means lyrics should appear earlier.
    final shifted = timed.map((l) {
      final t = l.time - Duration(milliseconds: offsetMs);
      return LyricLine(t.isNegative ? Duration.zero : t, l.text);
    }).toList()
      ..sort((a, b) => a.time.compareTo(b.time));
    return ParsedLyrics(shifted, true);
  }

  /// Index of the line being sung at [position] (-1 before the first line).
  static int indexAt(List<LyricLine> lines, Duration position) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

enum LyricsSource { saved, embedded, sidecar, online }

class LyricsResult {
  final String raw;
  final LyricsSource source;
  const LyricsResult(this.raw, this.source);
}

class LyricsService {
  LyricsService._();

  static final _bracketed = RegExp(r'\s*[\(\[\{][^\)\]\}]*[\)\]\}]');
  static final _noise = RegExp(
      r'\b(official|lyrics?|lyrical|video|audio|hd|hq|4k|full song|remaster(ed)?|\d{2,3}\s?kbps)\b',
      caseSensitive: false);

  /// Search-friendly title: drops "(Official Video)", "[320kbps]",
  /// "feat." parts, leading track numbers and "Artist - " prefixes that
  /// filenames and ripped tags carry — LRCLIB matches on the bare title.
  /// Download-site names ripped files carry ("Song - PagalWorld.com").
  static final siteNoise = RegExp(
      r'(www\.)?\b[\w-]+\.(com|net|in|org|co|me|info|pk|io)\b|\b(pagalworld|pagal ?world|mr-?jatt|djmaza|songspk|downloadming|wapking|djpunjab|webmusic|mp3mad|raagtune|masstamilan|naa ?songs|starmusiq)\b',
      caseSensitive: false);

  static String cleanTitle(String title, {String? artist}) {
    var t = title.replaceAll('_', ' ').replaceAll(siteNoise, ' ');
    t = t.replaceAll(_bracketed, ' ');
    t = t.replaceAll(RegExp(r'\s(feat\.?|ft\.?|featuring)\s.*$', caseSensitive: false), '');
    t = t.replaceAll(RegExp(r'^\s*\d{1,3}\s*[-.)]\s*'), '');
    final a = artist?.trim();
    if (a != null && a.isNotEmpty && t.toLowerCase().startsWith(a.toLowerCase())) {
      t = t.substring(a.length).replaceFirst(RegExp(r'^\s*[-–:|]\s*'), '');
    } else if ((a == null || a.isEmpty) && t.contains(' - ')) {
      // "Artist - Title" filename with no artist tag: keep the title part.
      t = t.substring(t.indexOf(' - ') + 3);
    }
    t = t.replaceAll(_noise, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    t = t.replaceAll(RegExp(r'^[-–:|\s]+|[-–:|\s]+$'), '');
    return t.isEmpty ? title.trim() : t;
  }

  /// Offline lookup (saved → embedded → sidecar). Null when none found.
  static Future<LyricsResult?> findLocal(String path) async {
    try {
      final saved = await LocalLyricsManager.getLyrics(path);
      if (saved != null && saved.trim().isNotEmpty) return LyricsResult(saved, LyricsSource.saved);
    } catch (_) {}

    try {
      final meta = await compute(_readEmbeddedLyrics, path);
      if (meta != null && meta.trim().isNotEmpty) return LyricsResult(meta, LyricsSource.embedded);
    } catch (e) {
      debugPrint('Embedded lyrics read failed: $e');
    }

    try {
      final dir = p.dirname(path);
      for (final candidate in [
        p.join(dir, '${p.basenameWithoutExtension(path)}.lrc'),
        p.join(dir, '${p.basename(path)}.lrc'),
      ]) {
        final f = File(candidate);
        if (await f.exists()) {
          final s = await f.readAsString();
          if (s.trim().isNotEmpty) return LyricsResult(s, LyricsSource.sidecar);
        }
      }
    } catch (e) {
      debugPrint('Sidecar .lrc read failed: $e');
    }
    return null;
  }

  static String? _readEmbeddedLyrics(String path) {
    try {
      return readMetadata(File(path), getImage: false).lyrics;
    } catch (_) {
      return null;
    }
  }

  static final Dio _dio = Dio(BaseOptions(
    baseUrl: 'https://lrclib.net/api',
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 10),
    headers: {'User-Agent': 'DuoMusicPlayer (https://play.google.com/store/apps/details?id=com.zenocta.duomusicplayer)'},
  ));

  /// LRCLIB occasionally answers 503 under load; retry briefly before giving up.
  static Future<Response> _getWithRetry(String path, Map<String, dynamic> params) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await _dio.get(path, queryParameters: params);
      } on DioException catch (e) {
        final code = e.response?.statusCode ?? 0;
        if (attempt >= 2 || code < 500) rethrow;
        await Future.delayed(Duration(milliseconds: 700 * (attempt + 1)));
      }
    }
  }

  /// Looks the song up on LRCLIB. Prefers synced lyrics; falls back to plain
  /// unless [syncedOnly] (the user already has plain lyrics — replacing them
  /// with another unsynced copy would gain nothing). Tries the title as
  /// given, then a cleaned-up version (see [cleanTitle]).
  /// On success the lyrics are saved for [path] so they work offline.
  static Future<LyricsResult?> fetchOnline({
    required String path,
    required String title,
    String? artist,
    String? album,
    Duration? duration,
    bool syncedOnly = false,
  }) async {
    final raw = title.trim();
    if (raw.isEmpty) return null;
    final titles = {raw, cleanTitle(raw, artist: artist)};
    for (final t in titles) {
      final r = await _fetchOnlineFor(path: path, title: t, artist: artist, album: album, duration: duration, syncedOnly: syncedOnly);
      if (r != null) return r;
    }
    return null;
  }

  static Future<LyricsResult?> _fetchOnlineFor({
    required String path,
    required String title,
    String? artist,
    String? album,
    Duration? duration,
    required bool syncedOnly,
  }) async {
    final cleanTitle = title.trim();
    if (cleanTitle.isEmpty) return null;
    String? pick(Map m) {
      final synced = m['syncedLyrics'];
      if (synced is String && synced.trim().isNotEmpty) return synced;
      if (syncedOnly) return null;
      final plain = m['plainLyrics'];
      if (plain is String && plain.trim().isNotEmpty) return plain;
      return null;
    }

    String? found;
    try {
      // Exact match first (needs artist; duration within ±2 s on LRCLIB's side).
      if (artist != null && artist.trim().isNotEmpty) {
        final r = await _dio.get('/get', queryParameters: {
          'track_name': cleanTitle,
          'artist_name': artist.trim(),
          if (album != null && album.trim().isNotEmpty) 'album_name': album.trim(),
          if (duration != null && duration.inSeconds > 0) 'duration': duration.inSeconds,
        }, options: Options(validateStatus: (s) => s != null && s < 500));
        if (r.statusCode == 200 && r.data is Map) found = pick(r.data as Map);
      }
      // Fuzzy search fallback; prefer entries with synced lyrics and a close duration.
      if (found == null) {
        var r = await _getWithRetry('/search', {
          'track_name': cleanTitle,
          if (artist != null && artist.trim().isNotEmpty) 'artist_name': artist.trim(),
        });
        // Wrong/missing artist tags are common in local libraries: retry by title only.
        if ((r.data is! List || (r.data as List).isEmpty) && artist != null && artist.trim().isNotEmpty) {
          r = await _getWithRetry('/search', {'track_name': cleanTitle});
        }
        if (r.data is List) {
          final list = (r.data as List).whereType<Map>().toList();
          int score(Map m) {
            var s = 0;
            if ((m['syncedLyrics'] as String?)?.isNotEmpty == true) s += 10;
            final d = (m['duration'] as num?)?.toDouble();
            if (d != null && duration != null && (d - duration.inSeconds).abs() <= 3) s += 5;
            return s;
          }

          list.sort((a, b) => score(b).compareTo(score(a)));
          for (final m in list) {
            found = pick(m);
            if (found != null) break;
          }
        }
      }
    } catch (e) {
      debugPrint('LRCLIB lookup failed: $e');
      rethrow;
    }
    if (found == null) return null;
    await LocalLyricsManager.saveLyrics(path, found);
    return LyricsResult(found, LyricsSource.online);
  }
}
