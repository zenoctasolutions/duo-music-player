// lib/lastfm_service.dart
//
// Last.fm scrobbling for the main player.
//  * Sign-in uses auth.getMobileSession (username + password over HTTPS, the
//    flow Last.fm documents for mobile apps). Only the session key is stored,
//    never the password.
//  * "Now playing" is sent when a song starts; a scrobble is recorded once
//    the song has played for half its length or 4 minutes (whichever comes
//    first), and only for songs longer than 30 s — Last.fm's rules.
//  * Scrobbles are queued on the device and sent in batches of up to 50, so
//    listening offline still counts once you're back online.

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lastfm_config.dart';

class ScrobbleTrack {
  final String artist;
  final String track;
  final String? album;
  final int durationSec;
  final int timestamp; // unix seconds when playback started
  const ScrobbleTrack({required this.artist, required this.track, this.album, required this.durationSec, required this.timestamp});

  Map<String, dynamic> toJson() => {'a': artist, 't': track, 'al': album, 'd': durationSec, 'ts': timestamp};
  static ScrobbleTrack fromJson(Map m) => ScrobbleTrack(
        artist: m['a'] as String,
        track: m['t'] as String,
        album: m['al'] as String?,
        durationSec: (m['d'] as num).toInt(),
        timestamp: (m['ts'] as num).toInt(),
      );
}

typedef TrackInfoResolver = Future<({String? artist, String? title, String? album})> Function(String path);

class LastFmService {
  LastFmService._();
  static final LastFmService instance = LastFmService._();

  static const _kSession = 'lastfm_session_key';
  static const _kUser = 'lastfm_username';
  static const _kEnabled = 'lastfm_enabled';
  static const _kQueue = 'lastfm_pending_v1';
  static const _api = 'https://ws.audioscrobbler.com/2.0/';

  String? _sessionKey;
  String? username;
  bool enabled = true;
  final List<ScrobbleTrack> _pending = [];
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  AudioPlayer? _player;
  TrackInfoResolver? _resolve;
  StreamSubscription<Duration>? _posSub;
  String? _currentPath;
  ScrobbleTrack? _current;
  Duration _listened = Duration.zero;
  Duration _lastPos = Duration.zero;
  bool _scrobbledCurrent = false;
  bool _flushing = false;

  static final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 15)));

  bool get isConfigured => LastFmConfig.isConfigured;
  bool get isSignedIn => _sessionKey != null;
  bool get isActive => isConfigured && isSignedIn && enabled;
  int get pendingCount => _pending.length;

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _sessionKey = prefs.getString(_kSession);
      username = prefs.getString(_kUser);
      enabled = prefs.getBool(_kEnabled) ?? true;
      final raw = prefs.getString(_kQueue);
      if (raw != null) {
        _pending
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((e) => ScrobbleTrack.fromJson(e as Map)));
      }
    } catch (e) {
      debugPrint('LastFm load failed: $e');
    }
  }

  Future<void> attach(AudioPlayer player, TrackInfoResolver resolve) async {
    await load();
    _player = player;
    _resolve = resolve;
    _posSub?.cancel();
    _posSub = player.positionStream.listen(_onPosition);
    unawaited(flush());
  }

  // ------------------------------------------------------------- signing

  /// Pure (unit-tested): Last.fm api_sig = md5 of sorted key+value pairs +
  /// shared secret ("format" and "callback" are excluded).
  @visibleForTesting
  static String signature(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format' && k != 'callback').toList()..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf
        ..write(k)
        ..write(params[k]);
    }
    buf.write(secret);
    return md5.convert(utf8.encode(buf.toString())).toString();
  }

  Future<Map<String, dynamic>> _call(Map<String, String> params, {bool post = true}) async {
    final all = {...params, 'api_key': LastFmConfig.apiKey};
    all['api_sig'] = signature(all, LastFmConfig.sharedSecret);
    all['format'] = 'json';
    final r = post
        ? await _dio.post(_api, data: all, options: Options(contentType: Headers.formUrlEncodedContentType, validateStatus: (_) => true))
        : await _dio.get(_api, queryParameters: all, options: Options(validateStatus: (_) => true));
    final data = r.data is String ? jsonDecode(r.data as String) : r.data;
    if (data is Map && data['error'] != null) {
      throw LastFmError((data['error'] as num).toInt(), data['message']?.toString() ?? 'Last.fm error');
    }
    return Map<String, dynamic>.from(data as Map);
  }

  // ---------------------------------------------------------------- auth

  /// Returns null on success, or a user-facing error.
  Future<String?> signIn(String user, String password) async {
    if (!isConfigured) return 'Last.fm isn\'t configured in this build.';
    try {
      final res = await _call({'method': 'auth.getMobileSession', 'username': user.trim(), 'password': password});
      final session = res['session'] as Map?;
      final key = session?['key'] as String?;
      if (key == null) return 'Unexpected response from Last.fm.';
      _sessionKey = key;
      username = session?['name'] as String? ?? user.trim();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSession, key);
      await prefs.setString(_kUser, username!);
      changes.value++;
      unawaited(flush());
      return null;
    } on LastFmError catch (e) {
      return e.code == 4 ? 'Wrong username or password.' : e.message;
    } catch (_) {
      return 'Couldn\'t reach Last.fm. Check your connection.';
    }
  }

  Future<void> signOut() async {
    _sessionKey = null;
    username = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSession);
    await prefs.remove(_kUser);
    changes.value++;
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, v);
    changes.value++;
  }

  // ------------------------------------------------------------ tracking

  /// Pure rule (unit-tested): enough of the song heard to scrobble?
  @visibleForTesting
  static bool shouldScrobble({required Duration duration, required Duration listened}) {
    if (duration <= const Duration(seconds: 30)) return false;
    final half = Duration(milliseconds: duration.inMilliseconds ~/ 2);
    final need = half < const Duration(minutes: 4) ? half : const Duration(minutes: 4);
    return listened >= need;
  }

  /// Called whenever the playing file changes (null for radio / nothing).
  Future<void> onTrackChanged(String? path) async {
    if (path == _currentPath) return;
    _currentPath = path;
    _current = null;
    _listened = Duration.zero;
    _lastPos = Duration.zero;
    _scrobbledCurrent = false;
    if (path == null || !isActive || _resolve == null) return;
    final info = await _resolve!(path);
    final artist = info.artist?.trim() ?? '';
    final title = info.title?.trim() ?? '';
    if (artist.isEmpty || title.isEmpty || artist.toLowerCase().contains('unknown')) return; // can't identify it
    // Duration may not be known yet; it's filled in when checked.
    _current = ScrobbleTrack(
      artist: artist,
      track: title,
      album: info.album,
      durationSec: _player?.duration?.inSeconds ?? 0,
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    unawaited(_nowPlaying(_current!));
  }

  void _onPosition(Duration pos) {
    final cur = _current;
    final player = _player;
    if (cur == null || player == null || _scrobbledCurrent) return;
    final delta = pos - _lastPos;
    _lastPos = pos;
    // Count real listening only (ignore seeks and pauses).
    if (player.playing && delta > Duration.zero && delta < const Duration(seconds: 2)) _listened += delta;
    final dur = player.duration;
    if (dur == null) return;
    if (shouldScrobble(duration: dur, listened: _listened)) {
      _scrobbledCurrent = true;
      _pending.add(ScrobbleTrack(
        artist: cur.artist,
        track: cur.track,
        album: cur.album,
        durationSec: dur.inSeconds,
        timestamp: cur.timestamp,
      ));
      unawaited(_persist());
      unawaited(flush());
    }
  }

  Future<void> _nowPlaying(ScrobbleTrack t) async {
    try {
      await _call({
        'method': 'track.updateNowPlaying',
        'artist': t.artist,
        'track': t.track,
        if (t.album != null && t.album!.isNotEmpty) 'album': t.album!,
        if (t.durationSec > 0) 'duration': '${t.durationSec}',
        'sk': _sessionKey!,
      });
    } catch (_) {}
  }

  /// Sends queued scrobbles (up to 50 per request).
  Future<void> flush() async {
    if (!isActive || _pending.isEmpty || _flushing) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final batch = _pending.take(50).toList();
        final params = <String, String>{'method': 'track.scrobble', 'sk': _sessionKey!};
        for (var i = 0; i < batch.length; i++) {
          final t = batch[i];
          params['artist[$i]'] = t.artist;
          params['track[$i]'] = t.track;
          params['timestamp[$i]'] = '${t.timestamp}';
          if (t.album != null && t.album!.isNotEmpty) params['album[$i]'] = t.album!;
          if (t.durationSec > 0) params['duration[$i]'] = '${t.durationSec}';
        }
        try {
          await _call(params);
          _pending.removeRange(0, batch.length);
          await _persist();
        } on LastFmError catch (e) {
          if (e.code == 9) {
            await signOut(); // session revoked
          } else if (e.code != 11 && e.code != 16 && e.code != 29) {
            _pending.removeRange(0, batch.length); // rejected data: drop it
            await _persist();
            continue;
          }
          break; // temporary (offline/rate limit): retry later
        }
      }
    } catch (_) {
      // network error — keep the queue for next time
    } finally {
      _flushing = false;
      changes.value++;
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // Keep at most 1000 unsent scrobbles.
      final list = _pending.length > 1000 ? _pending.sublist(_pending.length - 1000) : _pending;
      await prefs.setString(_kQueue, jsonEncode(list.map((t) => t.toJson()).toList()));
    } catch (_) {}
  }
}

class LastFmError implements Exception {
  final int code;
  final String message;
  LastFmError(this.code, this.message);
}
