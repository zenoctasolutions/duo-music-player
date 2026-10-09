// lib/cast_service.dart
//
// Chromecast playback (native side: CastHelper.kt).
//
// While connected, the TV is the player: the phone's own player is paused,
// tapping any song in the app sends it to the TV, and when a song finishes
// on the TV the next one from the current queue is sent automatically.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'player_screen.dart' show PlaylistContext;

class CastDevice {
  final String id;
  final String name;
  final String description;
  const CastDevice(this.id, this.name, this.description);
}

class CastStatus {
  final String playerState; // playing | paused | buffering | idle
  final Duration position;
  final Duration duration;
  final double volume;
  const CastStatus({this.playerState = 'idle', this.position = Duration.zero, this.duration = Duration.zero, this.volume = 1});
  bool get playing => playerState == 'playing' || playerState == 'buffering';
}

typedef CastTrackInfo = Future<({String? title, String? artist, String? album, String? coverPath})> Function(String path);

class CastService {
  CastService._();
  static final CastService instance = CastService._();

  static const MethodChannel _channel = MethodChannel('music_app/cast');

  final ValueNotifier<List<CastDevice>> devices = ValueNotifier(const []);
  final ValueNotifier<String?> connectedDevice = ValueNotifier(null);
  final ValueNotifier<CastStatus> status = ValueNotifier(const CastStatus());
  final ValueNotifier<String?> error = ValueNotifier(null);

  /// Path of the song currently on the TV.
  final ValueNotifier<String?> castingPath = ValueNotifier(null);

  bool? _available;
  AudioPlayer? _player;
  CastTrackInfo? _info;
  Timer? _poll;
  bool _advancing = false;

  bool get isConnected => connectedDevice.value != null;

  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    if (!Platform.isAndroid) return _available = false;
    try {
      _available = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  void attach(AudioPlayer player, CastTrackInfo info) {
    _player = player;
    _info = info;
    _channel.setMethodCallHandler(_onNative);
    // While casting, a song started in the app goes to the TV instead.
    PlaylistContext.currentPathNotifier.addListener(_onAppTrackChanged);
    player.playingStream.listen((playing) {
      if (playing && isConnected) player.pause();
    });
  }

  Future<dynamic> _onNative(MethodCall call) async {
    switch (call.method) {
      case 'onRoutes':
        devices.value = [
          for (final m in (call.arguments as List).cast<Map>())
            CastDevice(m['id'] as String, m['name'] as String, (m['description'] as String?) ?? ''),
        ];
      case 'onConnected':
        connectedDevice.value = (call.arguments as Map)['device'] as String?;
        error.value = null;
        await _startCastingCurrent();
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(seconds: 1), (_) => _channel.invokeMethod('status'));
      case 'onDisconnected':
        _poll?.cancel();
        final wasPath = castingPath.value;
        final pos = status.value.position;
        connectedDevice.value = null;
        castingPath.value = null;
        // Hand playback back to the phone at the same spot (paused).
        if (wasPath != null && wasPath == PlaylistContext.currentPathNotifier.value && pos > Duration.zero) {
          await _player?.seek(pos);
        }
      case 'onError':
        error.value = (call.arguments as Map)['message'] as String?;
      case 'onStatus':
        final m = call.arguments as Map;
        status.value = CastStatus(
          playerState: m['playerState'] as String? ?? 'idle',
          position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
          duration: Duration(milliseconds: (m['durationMs'] as num?)?.toInt() ?? 0),
          volume: (m['volume'] as num?)?.toDouble() ?? 1,
        );
        if (m['finished'] == true) unawaited(_advance(1));
    }
    return null;
  }

  Future<void> startDiscovery() async {
    if (!await isAvailable()) return;
    await _channel.invokeMethod('startDiscovery');
  }

  Future<void> stopDiscovery() => _channel.invokeMethod('stopDiscovery');

  Future<void> connect(CastDevice d) async {
    error.value = null;
    try {
      await _channel.invokeMethod('connect', {'id': d.id});
    } on PlatformException catch (e) {
      error.value = e.message;
    }
  }

  Future<void> disconnect() => _channel.invokeMethod('disconnect');

  Future<void> _startCastingCurrent() async {
    final path = PlaylistContext.currentPathNotifier.value;
    if (path == null) return;
    final pos = _player?.position ?? Duration.zero;
    await _player?.pause();
    await castPath(path, position: pos);
  }

  void _onAppTrackChanged() {
    final path = PlaylistContext.currentPathNotifier.value;
    if (!isConnected || path == null || path == castingPath.value || _advancing) return;
    _player?.pause();
    unawaited(castPath(path));
  }

  Future<void> castPath(String path, {Duration position = Duration.zero}) async {
    if (!isConnected) return;
    final info = await _info?.call(path);
    castingPath.value = path;
    try {
      await _channel.invokeMethod('load', {
        'path': path,
        'title': info?.title,
        'artist': info?.artist,
        'album': info?.album,
        'coverPath': info?.coverPath,
        'positionMs': position.inMilliseconds,
        'autoplay': true,
      });
    } on PlatformException catch (e) {
      error.value = e.code == 'NO_WIFI' ? 'Connect your phone to the same Wi-Fi as the Cast device.' : e.message;
    }
  }

  /// Next (+1) / previous (-1) in the current queue, on the TV.
  Future<void> _advance(int step) async {
    if (_advancing) return;
    final queue = PlaylistContext.getCurrentPlaylist();
    final cur = castingPath.value;
    if (queue == null || queue.isEmpty || cur == null) return;
    final i = queue.indexOf(cur);
    final next = queue[((i < 0 ? 0 : i) + step) % queue.length];
    _advancing = true;
    try {
      PlaylistContext.setCurrentPath(next); // keeps the app's now-playing in sync
      await castPath(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> next() => _advance(1);
  Future<void> previous() => _advance(-1);
  Future<void> togglePlay() => _channel.invokeMethod(status.value.playing ? 'pause' : 'play');
  Future<void> seek(Duration d) => _channel.invokeMethod('seek', {'positionMs': d.inMilliseconds});
  Future<void> setVolume(double v) => _channel.invokeMethod('setVolume', {'volume': v});
}
