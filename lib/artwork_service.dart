// lib/artwork_service.dart
//
// Optional automatic album-art download for songs that have no embedded
// cover and no folder.jpg/cover.jpg next to them. Off by default (Settings →
// Appearance). Looks the album up on the iTunes Search API (free, no key),
// downloads a 600×600 cover once, and caches it on disk per artist+album,
// so every song of that album shares it and it works offline afterwards.
// Misses are remembered for 30 days so the network isn't hit repeatedly.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/widgets.dart' show ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import 'lyrics_service.dart' show LyricsService;

class ArtworkService {
  ArtworkService._();
  static final ArtworkService instance = ArtworkService._();

  static const _kEnabled = 'artwork_download_enabled';
  // v2: the v1 matcher missed most real-world tags, and those misses were
  // remembered for 30 days — start clean and retry misses weekly.
  static const _kMisses = 'artwork_misses_v2';
  static const _missRetry = Duration(days: 7);

  /// Path of a song whose cover was just downloaded, so open screens (the
  /// full player keeps its own metadata copy) can pick it up.
  final ValueNotifier<String?> downloaded = ValueNotifier<String?>(null);

  bool enabled = false;
  bool _loaded = false;
  final Map<String, int> _misses = {};
  final Set<String> _inFlight = {};
  Directory? _dir;

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
  ));

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(_kEnabled) ?? false;
      final raw = prefs.getString(_kMisses);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) => _misses[k] = (v as num).toInt());
      }
    } catch (_) {}
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, v);
  }

  /// Cache key shared by all songs of an album (or a single when no album).
  @visibleForTesting
  static String keyFor({String? artist, String? album, String? title}) {
    String norm(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
    final a = norm(artist), al = norm(album);
    return al.isNotEmpty ? '$a|$al' : '$a|~${norm(title)}';
  }

  Future<File> _fileFor(String key) async {
    _dir ??= Directory(p.join((await getApplicationSupportDirectory()).path, 'artwork'));
    if (!await _dir!.exists()) await _dir!.create(recursive: true);
    final safe = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return File(p.join(_dir!.path, '${safe.length > 120 ? safe.substring(0, 120) : safe}.jpg'));
  }

  /// Previously downloaded cover for this song's album, if any (no network).
  Future<Uint8List?> cached({String? artist, String? album, String? title}) async {
    if ((artist ?? '').trim().isEmpty && (album ?? '').trim().isEmpty) return null;
    final f = await _fileFor(keyFor(artist: artist, album: album, title: title));
    return await f.exists() ? await f.readAsBytes() : null;
  }

  /// Downloads the cover when enabled and not cached. Null when not found.
  Future<Uint8List?> fetch({String? artist, String? album, String? title}) async {
    await load();
    if (!enabled) return null;
    var art = (artist ?? '').trim();
    if (art.toLowerCase().contains('unknown')) art = '';
    final hasAlbum = cleanAlbum(album).isNotEmpty;
    final hasTitle = (title ?? '').trim().isNotEmpty;
    // Without an artist only a title + album pair is specific enough.
    if (art.isEmpty && !(hasAlbum && hasTitle)) return null;
    final key = keyFor(artist: artist, album: album, title: title);
    final hit = await cached(artist: artist, album: album, title: title);
    if (hit != null) return hit;
    final missAt = _misses[key];
    if (missAt != null && DateTime.now().millisecondsSinceEpoch - missAt < _missRetry.inMilliseconds) return null;
    if (!_inFlight.add(key)) return null;
    try {
      final url = await _lookup(artist: art, album: album, title: title);
      if (url == null) {
        await _recordMiss(key);
        return null;
      }
      final r = await _dio.get<List<int>>(url, options: Options(responseType: ResponseType.bytes));
      final bytes = r.data;
      if (bytes == null || bytes.length < 1000) {
        await _recordMiss(key);
        return null;
      }
      final f = await _fileFor(key);
      await f.writeAsBytes(bytes, flush: true);
      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('Artwork fetch failed for $key: $e');
      return null; // network error: don't record a miss, try again later
    } finally {
      _inFlight.remove(key);
    }
  }

  /// Tries a few searches, most specific first, in the device's store and
  /// then the US store (regional music — e.g. Bollywood — is often only
  /// indexed in the local store).
  Future<String?> _lookup({required String artist, String? album, String? title}) async {
    final albumQ = cleanAlbum(album);
    final titleQ = title == null ? '' : LyricsService.cleanTitle(title, artist: artist);
    final lead = splitArtists(artist).firstOrNull ?? '';
    final queries = <(String, String)>[
      if (lead.isNotEmpty && albumQ.isNotEmpty) ('$lead $albumQ', 'album'),
      if (lead.isNotEmpty && titleQ.isNotEmpty) ('$lead $titleQ', 'song'),
      if (titleQ.isNotEmpty && albumQ.isNotEmpty) ('$titleQ $albumQ', 'song'),
      if (lead.isNotEmpty && albumQ.isEmpty && titleQ.isEmpty) (lead, 'album'),
    ];
    final countries = <String>{_deviceCountry(), 'US'}.where((c) => c.isNotEmpty);
    for (final country in countries) {
      for (final (term, entity) in queries) {
        final r = await _dio.get('https://itunes.apple.com/search', queryParameters: {
          'term': term,
          'entity': entity,
          'limit': 15,
          'country': country,
        });
        final data = r.data is String ? jsonDecode(r.data as String) : r.data;
        final results = (data is Map ? data['results'] : null) as List?;
        if (results == null || results.isEmpty) continue;
        final best = pickBest(results.whereType<Map>().toList(), artist: artist, album: album, title: title);
        final small = best?['artworkUrl100'] as String?;
        if (small != null) return small.replaceAll(RegExp(r'/\d+x\d+bb\.'), '/600x600bb.');
      }
    }
    return null;
  }

  static String _deviceCountry() {
    try {
      final parts = Platform.localeName.split(RegExp(r'[_\-.]'));
      return parts.length > 1 && parts[1].length == 2 ? parts[1].toUpperCase() : '';
    } catch (_) {
      return '';
    }
  }

  /// "Mithoon, Ankit Tiwari & Jeet Gannguli" → [Mithoon, Ankit Tiwari, Jeet Gannguli].
  @visibleForTesting
  static List<String> splitArtists(String? artist) => (artist ?? '')
      .split(RegExp(r'\s*(?:,|&|/|;|\+|\bfeat\.?|\bft\.?|\bfeaturing\b|\bx\b|\band\b)\s*', caseSensitive: false))
      .map((a) => a.trim())
      .where((a) => a.isNotEmpty && !a.toLowerCase().contains('unknown'))
      .toList();

  /// Album tag without download-site names, years, bitrates or
  /// "(Original Motion Picture Soundtrack)"-style suffixes.
  @visibleForTesting
  static String cleanAlbum(String? album) {
    var a = (album ?? '').replaceAll('_', ' ');
    if (a.toLowerCase().contains('unknown')) return '';
    a = a.replaceAll(RegExp(r'\s*[\(\[\{][^\)\]\}]*[\)\]\}]'), ' ');
    a = a.replaceAll(LyricsService.siteNoise, ' ');
    a = a.replaceAll(RegExp(r'\b(19|20)\d{2}\b|\b\d{2,3}\s?kbps\b|\bmp3\b|\bsongs?\b', caseSensitive: false), ' ');
    return a.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'^[-–:|\s]+|[-–:|\s]+$'), '').trim();
  }

  /// Pure (unit-tested): the result whose artist matches one of the song's
  /// artists, plus its album or its title. Artist-only matches are
  /// rejected — they'd show some other record's cover.
  @visibleForTesting
  static Map? pickBest(List<Map> results, {required String artist, String? album, String? title}) {
    String n(String? s) => (s ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final wantArtists = splitArtists(artist).map(n).where((a) => a.length >= 2).toList();
    final wantAlbum = n(cleanAlbum(album));
    final wantTitle = n(title == null ? null : LyricsService.cleanTitle(title, artist: artist));
    bool artistOk(String got) {
      if (wantArtists.isEmpty) return true; // title + album must carry it
      final g = n(got);
      if (g.isEmpty) return false;
      return wantArtists.any((w) => g.contains(w) || w.contains(g));
    }

    bool same(String got, String want) =>
        want.isNotEmpty && got.isNotEmpty && (got == want || got.startsWith(want) || want.startsWith(got));

    Map? best;
    var bestScore = 0;
    for (final m in results) {
      if (!artistOk(m['artistName'] as String? ?? '')) continue;
      final albumHit = same(n(cleanAlbum(m['collectionName'] as String?)), wantAlbum);
      final titleHit = same(n(LyricsService.cleanTitle(m['trackName'] as String? ?? '')), wantTitle);
      if (!albumHit && !titleHit) continue;
      if (wantArtists.isEmpty && !(albumHit && titleHit)) continue;
      final score = (albumHit ? 3 : 0) + (titleHit ? 2 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = m;
      }
    }
    return best;
  }

  Future<void> _recordMiss(String key) async {
    _misses[key] = DateTime.now().millisecondsSinceEpoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMisses, jsonEncode(_misses));
    } catch (_) {}
  }
}
