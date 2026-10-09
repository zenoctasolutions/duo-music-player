// lib/radio_service.dart
//
// Internet Radio: models + client for the Radio-Browser API
// (https://www.radio-browser.info/), plus the shared playback/favorites
// state used by the UI in radio_page.dart and wired into the existing
// player pipeline in songs_page.dart.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:package_info_plus/package_info_plus.dart';

class RadioStation {
  final String stationUuid;
  final String name;
  final String country;
  final String countryCode;
  final String state;
  final String language;
  final String tags;
  final String streamUrl;
  final String favicon;
  final String homepage;
  final String codec;
  final int bitrate;
  final bool online;

  const RadioStation({
    required this.stationUuid,
    required this.name,
    required this.country,
    required this.countryCode,
    required this.state,
    required this.language,
    required this.tags,
    required this.streamUrl,
    required this.favicon,
    required this.homepage,
    required this.codec,
    required this.bitrate,
    required this.online,
  });

  factory RadioStation.fromJson(Map<String, dynamic> json) {
    final resolved = (json['url_resolved'] as String?)?.trim();
    final raw = (json['url'] as String?)?.trim();
    final lastCheckOk = json['lastcheckok'];
    return RadioStation(
      stationUuid: (json['stationuuid'] as String?) ?? '',
      name: ((json['name'] as String?) ?? '').trim().isEmpty
          ? 'Unnamed Station'
          : (json['name'] as String).trim(),
      country: (json['country'] as String?) ?? '',
      countryCode: ((json['countrycode'] as String?) ?? '').toUpperCase(),
      state: (json['state'] as String?) ?? '',
      language: (json['language'] as String?) ?? '',
      tags: (json['tags'] as String?) ?? '',
      streamUrl: (resolved != null && resolved.isNotEmpty) ? resolved : (raw ?? ''),
      favicon: (json['favicon'] as String?) ?? '',
      homepage: (json['homepage'] as String?) ?? '',
      codec: (json['codec'] as String?) ?? '',
      bitrate: (json['bitrate'] is int)
          ? json['bitrate'] as int
          : int.tryParse('${json['bitrate']}') ?? 0,
      online: lastCheckOk == 1 || lastCheckOk == '1' || lastCheckOk == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'stationuuid': stationUuid,
        'name': name,
        'country': country,
        'countrycode': countryCode,
        'state': state,
        'language': language,
        'tags': tags,
        'url_resolved': streamUrl,
        'favicon': favicon,
        'homepage': homepage,
        'codec': codec,
        'bitrate': bitrate,
        'lastcheckok': online ? 1 : 0,
      };

  String get primaryGenre {
    for (final t in tags.split(',')) {
      final trimmed = t.trim();
      if (trimmed.isNotEmpty) return trimmed;
    }
    return '';
  }

  String get displayLanguage {
    for (final l in language.split(',')) {
      final trimmed = l.trim();
      if (trimmed.isNotEmpty) return trimmed[0].toUpperCase() + trimmed.substring(1);
    }
    return '';
  }

  String get subtitle {
    final parts = <String>[
      if (country.isNotEmpty) country,
      if (primaryGenre.isNotEmpty) primaryGenre,
      if (displayLanguage.isNotEmpty) displayLanguage,
    ];
    return parts.join(' • ');
  }
}

class RadioCountry {
  final String name;
  final String countryCode;
  final int stationCount;

  const RadioCountry({required this.name, required this.countryCode, required this.stationCount});

  factory RadioCountry.fromJson(Map<String, dynamic> json) => RadioCountry(
        name: (json['name'] as String?) ?? '',
        countryCode: (json['iso_3166_1'] as String?) ?? '',
        stationCount: (json['stationcount'] is int)
            ? json['stationcount'] as int
            : int.tryParse('${json['stationcount']}') ?? 0,
      );

  /// Regional-indicator flag emoji derived from the ISO country code.
  String get flagEmoji {
    if (countryCode.length != 2) return '\u{1F310}';
    final code = countryCode.toUpperCase();
    final base = 0x1F1E6;
    try {
      final first = base + (code.codeUnitAt(0) - 'A'.codeUnitAt(0));
      final second = base + (code.codeUnitAt(1) - 'A'.codeUnitAt(0));
      return String.fromCharCode(first) + String.fromCharCode(second);
    } catch (_) {
      return '\u{1F310}';
    }
  }
}

class RadioServiceException implements Exception {
  final String message;
  final Object? cause;
  RadioServiceException(this.message, {this.cause});
  @override
  String toString() => message;
}

class RadioBrowserService {
  RadioBrowserService._internal();
  static final RadioBrowserService instance = RadioBrowserService._internal();

  static const List<String> _hosts = [
    'https://all.api.radio-browser.info',
    'https://de1.api.radio-browser.info',
    'https://de2.api.radio-browser.info',
    'https://nl1.api.radio-browser.info',
  ];

  static const String _cacheBoxName = 'radio_cache';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 12),
  ));

  String? _workingHost;
  String? _userAgent;
  Box? _cacheBox;
  final Map<String, Future<dynamic>> _inFlight = {};

  Future<Box> _box() async {
    if (_cacheBox != null && _cacheBox!.isOpen) return _cacheBox!;
    if (!Hive.isBoxOpen(_cacheBoxName)) {
      await Hive.initFlutter();
      _cacheBox = await Hive.openBox(_cacheBoxName);
    } else {
      _cacheBox = Hive.box(_cacheBoxName);
    }
    return _cacheBox!;
  }

  Future<String> _ua() async {
    if (_userAgent != null) return _userAgent!;
    try {
      final info = await PackageInfo.fromPlatform();
      final name = info.appName.replaceAll(RegExp(r'\s+'), '');
      _userAgent = '${name.isEmpty ? 'DuoMusicPlayer' : name}/${info.version}';
    } catch (_) {
      _userAgent = 'DuoMusicPlayer/1.0';
    }
    return _userAgent!;
  }

  Future<T> _cachedGet<T>(
    String path,
    Map<String, dynamic> query,
    T Function(dynamic data) parse, {
    required String cacheKey,
    Duration ttl = const Duration(hours: 6),
  }) {
    final existing = _inFlight[cacheKey];
    if (existing != null) return existing as Future<T>;
    final future = _fetch(path, query, parse, cacheKey, ttl);
    _inFlight[cacheKey] = future;
    future.whenComplete(() => _inFlight.remove(cacheKey));
    return future;
  }

  Future<T> _fetch<T>(
    String path,
    Map<String, dynamic> query,
    T Function(dynamic) parse,
    String cacheKey,
    Duration ttl,
  ) async {
    final ua = await _ua();
    final hosts = <String>[
      if (_workingHost != null) _workingHost!,
      ..._hosts.where((h) => h != _workingHost),
    ];

    Object? lastError;
    for (final host in hosts) {
      try {
        final resp = await _dio.get(
          '$host$path',
          queryParameters: query,
          options: Options(headers: {'User-Agent': ua}, responseType: ResponseType.json),
        );
        _workingHost = host;
        final parsed = parse(resp.data);
        unawaited(_saveCache(cacheKey, resp.data));
        return parsed;
      } catch (e) {
        lastError = e;
        continue;
      }
    }

    final cached = await _readCache(cacheKey, ttl, ignoreTtl: true);
    if (cached != null) return parse(cached);

    throw RadioServiceException(
      'Unable to reach Radio Browser — check your internet connection.',
      cause: lastError,
    );
  }

  Future<void> _saveCache(String key, dynamic data) async {
    try {
      final box = await _box();
      await box.put(key, {'data': jsonEncode(data), 'ts': DateTime.now().millisecondsSinceEpoch});
    } catch (_) {}
  }

  Future<dynamic> _readCache(String key, Duration ttl, {bool ignoreTtl = false}) async {
    try {
      final box = await _box();
      final raw = box.get(key);
      if (raw == null) return null;
      final map = Map<String, dynamic>.from(raw as Map);
      final ts = map['ts'] as int?;
      if (!ignoreTtl && ts != null &&
          DateTime.now().millisecondsSinceEpoch - ts > ttl.inMilliseconds) {
        return null;
      }
      return jsonDecode(map['data'] as String);
    } catch (_) {
      return null;
    }
  }

  List<RadioStation> _parseStations(dynamic data) => (data as List)
      .map((e) => RadioStation.fromJson(Map<String, dynamic>.from(e as Map)))
      .where((s) => s.streamUrl.isNotEmpty)
      .toList();

  Future<List<RadioCountry>> getCountries() => _cachedGet(
        '/json/countries',
        const {'order': 'name'},
        (data) => (data as List)
            .map((e) => RadioCountry.fromJson(Map<String, dynamic>.from(e as Map)))
            .where((c) => c.stationCount > 0 && c.countryCode.isNotEmpty)
            .toList(),
        cacheKey: 'countries',
        ttl: const Duration(days: 1),
      );

  Future<List<RadioStation>> getStationsByCountryCode(
    String code, {
    int limit = 30,
    int offset = 0,
  }) =>
      _cachedGet(
        '/json/stations/bycountrycodeexact/$code',
        {
          'limit': limit,
          'offset': offset,
          'order': 'clickcount',
          'reverse': true,
          'hidebroken': true,
        },
        _parseStations,
        cacheKey: 'country_${code}_${limit}_$offset',
      );

  Future<List<RadioStation>> searchStations({
    String? name,
    String? countryCode,
    String? tag,
    int limit = 30,
    int offset = 0,
  }) =>
      _cachedGet(
        '/json/stations/search',
        {
          if (name != null && name.isNotEmpty) 'name': name,
          if (countryCode != null && countryCode.isNotEmpty) 'countrycode': countryCode,
          if (tag != null && tag.isNotEmpty) 'tag': tag,
          'limit': limit,
          'offset': offset,
          'order': 'clickcount',
          'reverse': true,
          'hidebroken': true,
        },
        _parseStations,
        cacheKey: 'search_${name}_${countryCode}_${tag}_${limit}_$offset',
        ttl: const Duration(hours: 1),
      );

  Future<List<String>> getTagsForCountry(String code) => _cachedGet(
        '/json/stations/bycountrycodeexact/$code',
        const {'limit': 200, 'hidebroken': true},
        (data) {
          final set = <String>{};
          for (final e in (data as List)) {
            final tags = ((e as Map)['tags'] as String?) ?? '';
            for (final t in tags.split(',')) {
              final trimmed = t.trim();
              if (trimmed.isNotEmpty) set.add(trimmed);
            }
          }
          final list = set.toList()..sort();
          return list.take(30).toList();
        },
        cacheKey: 'tags_$code',
        ttl: const Duration(days: 1),
      );

  /// Registers a play with Radio-Browser (used once per station selection,
  /// never per UI render) — purely informational, failures are ignored.
  Future<void> registerClick(String stationUuid) async {
    if (stationUuid.isEmpty) return;
    try {
      final host = _workingHost ?? _hosts.first;
      final ua = await _ua();
      await _dio.get('$host/json/url/$stationUuid', options: Options(headers: {'User-Agent': ua}));
    } catch (_) {}
  }
}

/// Mirrors PlaylistContext (player_screen.dart) for radio: single source of
/// truth for "is a radio station currently the active source", read by the
/// Songs page to decide whether to show the normal file-based MiniPlayer or
/// the RadioMiniPlayer, and by the notification-building code to omit
/// next/previous controls that don't apply to a live stream.
class RadioPlaybackContext {
  static final ValueNotifier<RadioStation?> currentStationNotifier =
      ValueNotifier<RadioStation?>(null);

  static bool get isActive => currentStationNotifier.value != null;

  static void setCurrentStation(RadioStation? station) {
    currentStationNotifier.value = station;
  }

  static void clear() => currentStationNotifier.value = null;
}

/// Favorite radio stations — same shape as FavoritesNotifier (list_page.dart)
/// but kept in its own Hive box so it can never collide with song favorites.
class RadioFavoritesNotifier extends ChangeNotifier {
  RadioFavoritesNotifier._internal();
  static final RadioFavoritesNotifier instance = RadioFavoritesNotifier._internal();

  static const String _boxName = 'radio_favorites_box';
  static const String _keyStations = 'stations';

  Box<dynamic>? _box;
  final Map<String, RadioStation> _favorites = {};
  Future<void>? _initFuture;

  bool get initialized => _box != null;
  List<RadioStation> get favorites => List.unmodifiable(_favorites.values);

  Future<void> init() {
    _initFuture ??= _initInternal();
    return _initFuture!;
  }

  Future<void> _initInternal() async {
    if (_box != null) return;
    try {
      if (!Hive.isBoxOpen(_boxName)) {
        await Hive.initFlutter();
        _box = await Hive.openBox<dynamic>(_boxName);
      } else {
        _box = Hive.box<dynamic>(_boxName);
      }
      final stored = _box!.get(_keyStations);
      _favorites.clear();
      if (stored is List) {
        for (final raw in stored) {
          try {
            final station = RadioStation.fromJson(Map<String, dynamic>.from(raw as Map));
            _favorites[station.stationUuid] = station;
          } catch (_) {}
        }
      }
      notifyListeners();
    } catch (e) {
      debugPrint('RadioFavoritesNotifier.init error: $e');
    }
  }

  bool contains(String stationUuid) => _favorites.containsKey(stationUuid);

  Future<void> toggle(RadioStation station) async {
    await init();
    if (_favorites.containsKey(station.stationUuid)) {
      _favorites.remove(station.stationUuid);
    } else {
      _favorites[station.stationUuid] = station;
    }
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await init();
      await _box!.put(_keyStations, _favorites.values.map((s) => s.toJson()).toList());
    } catch (e) {
      debugPrint('RadioFavoritesNotifier._persist error: $e');
    }
  }
}
