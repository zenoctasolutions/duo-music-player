// lib/audio_effects_service.dart
//
// Sound effects and volume normalization for the main player:
//  * Bass boost, virtualizer (3D/spatial widening) and loudness boost —
//    Android audiofx effects attached to the player's audio session
//    (MainActivity.applySoundEffects over the equalizer channel). They are
//    re-applied automatically whenever the session id changes.
//  * Volume normalization (ReplayGain-style) — every song is brought to a
//    common loudness target. The gain comes from the file's ReplayGain /
//    R128 tag when present, otherwise from a one-off EBU R128 loudness
//    measurement with ffmpeg, cached per file. Loud songs are turned down
//    with the player volume; quiet songs are turned up with the loudness
//    enhancer (which has a built-in limiter, so no clipping).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'eq_profile_service.dart' show invokeChannelRetry;
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AudioEffectsService {
  AudioEffectsService._();
  static final AudioEffectsService instance = AudioEffectsService._();

  static const MethodChannel _channel = MethodChannel('music_app/equalizer');

  static const _kBass = 'fx_bass_strength';
  static const _kVirt = 'fx_virtualizer_strength';
  static const _kLoud = 'fx_loudness_mb';
  static const _kNormalize = 'fx_normalize';
  static const _kGains = 'fx_track_gains_v1';

  /// Loudness every song is normalized to (the common streaming target).
  static const double targetLufs = -14.0;

  /// ReplayGain 2 tags are relative to -18 LUFS; R128 tags to -23 LUFS.
  static const double _rgReferenceLufs = -18.0;
  static const double _r128ReferenceLufs = -23.0;

  static const double _maxBoostDb = 6.0;
  static const double _maxCutDb = -15.0;

  int bass = 0; // 0..1000
  int virtualizer = 0; // 0..1000
  int loudnessMb = 0; // 0..1000 (user loudness boost, millibels)
  bool normalize = false;

  bool bassSupported = true;
  bool virtualizerSupported = true;
  bool loudnessSupported = true;

  /// Bumped when settings, support flags or the current gain change.
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  AudioPlayer? _player;
  int? _sessionId;
  StreamSubscription<int?>? _sessionSub;
  String? _currentPath;
  double _currentGainDb = 0;
  bool _loaded = false;

  /// Crossfade fade-in multiplier (0..1) applied on top of normalization.
  double _fadeMultiplier = 1.0;

  /// Player volume normalization wants for the current song (0..1).
  double get normalizedVolume {
    final cutDb = normalize && _currentGainDb < 0 ? _currentGainDb : 0.0;
    return math.pow(10, cutDb / 20).toDouble().clamp(0.0, 1.0);
  }

  /// Used by crossfade to fade the incoming song in.
  Future<void> setFadeMultiplier(double m) async {
    _fadeMultiplier = m.clamp(0.0, 1.0);
    await _player?.setVolume(normalizedVolume * _fadeMultiplier);
  }

  final Map<String, double> _gains = {};
  final Set<String> _measuring = {};
  Timer? _saveDebounce;

  /// Gain (dB) applied to the current song by normalization (0 when off).
  double get currentGainDb => normalize ? _currentGainDb : 0;
  int get analyzedCount => _gains.length;

  Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      bass = prefs.getInt(_kBass) ?? 0;
      virtualizer = prefs.getInt(_kVirt) ?? 0;
      loudnessMb = prefs.getInt(_kLoud) ?? 0;
      normalize = prefs.getBool(_kNormalize) ?? false;
      final raw = prefs.getString(_kGains);
      if (raw != null) {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) => _gains[k] = (v as num).toDouble());
      }
    } catch (e) {
      debugPrint('AudioEffects load failed: $e');
    }
    _loaded = true;
  }

  /// Hooks the service to the app's main player. Call once.
  Future<void> attach(AudioPlayer player) async {
    await load();
    _player = player;
    _sessionSub?.cancel();
    _sessionSub = player.androidAudioSessionIdStream.listen((sid) {
      if (sid == null || sid == 0 || sid == _sessionId) return;
      _sessionId = sid;
      unawaited(_applyEffects());
    });
  }

  /// Called whenever the playing file changes (null for radio / nothing).
  Future<void> onTrackChanged(String? path) async {
    if (path == _currentPath) return;
    _currentPath = path;
    _currentGainDb = 0;
    if (!normalize || path == null || !File(path).existsSync()) {
      await _applyVolumeAndLoudness();
      return;
    }
    final cached = _gains[path];
    if (cached != null) {
      _currentGainDb = cached;
      await _applyVolumeAndLoudness();
      return;
    }
    // Unknown song: play at unity until the measurement lands (usually a
    // couple of seconds), then ease to the normalized level.
    await _applyVolumeAndLoudness();
    final gain = await gainFor(path);
    if (gain != null && _currentPath == path && normalize) {
      _currentGainDb = gain;
      await _applyVolumeAndLoudness(smooth: true);
    }
  }

  // ------------------------------------------------------------ settings

  Future<void> setBass(int v) => _setAndApply(() => bass = v.clamp(0, 1000), _kBass, () => bass);
  Future<void> setVirtualizer(int v) => _setAndApply(() => virtualizer = v.clamp(0, 1000), _kVirt, () => virtualizer);
  Future<void> setLoudness(int mb) => _setAndApply(() => loudnessMb = mb.clamp(0, 1000), _kLoud, () => loudnessMb);

  Future<void> _setAndApply(void Function() set, String key, int Function() get) async {
    set();
    changes.value++;
    await _applyEffects();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, get());
  }

  Future<void> setNormalize(bool v) async {
    normalize = v;
    changes.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNormalize, v);
    final path = _currentPath;
    _currentPath = null; // force re-evaluation
    await onTrackChanged(path);
  }

  // ------------------------------------------------------------ applying

  int get _totalLoudnessMb {
    final boostDb = normalize && _currentGainDb > 0 ? _currentGainDb : 0.0;
    return (loudnessMb + boostDb * 100).round().clamp(0, 1500);
  }

  Future<void> _applyEffects() async {
    final sid = _sessionId;
    if (sid == null || sid == 0) return;
    try {
      final res = await invokeChannelRetry<Map>(_channel, 'setSoundEffects', {
        'sessionId': sid,
        'bass': bass,
        'virtualizer': virtualizer,
        'loudnessMb': _totalLoudnessMb,
      });
      if (res != null) {
        bassSupported = res['bassSupported'] != false;
        virtualizerSupported = res['virtualizerSupported'] != false;
        loudnessSupported = res['loudnessSupported'] != false;
        changes.value++;
      }
    } catch (e) {
      debugPrint('setSoundEffects failed: $e');
    }
  }

  Future<void> _applyVolumeAndLoudness({bool smooth = false}) async {
    final p = _player;
    if (p != null) {
      final target = normalizedVolume * _fadeMultiplier;
      if (smooth) {
        // Ease over ~600 ms so the level change isn't a jump.
        final start = p.volume;
        for (var i = 1; i <= 6; i++) {
          await Future.delayed(const Duration(milliseconds: 100));
          await p.setVolume(start + (target - start) * i / 6);
        }
      } else {
        await p.setVolume(target);
      }
    }
    changes.value++;
    await _applyEffects();
  }

  // ----------------------------------------------------------- measuring

  /// Normalization gain (dB) for [path]: from tags when present, otherwise
  /// measured with ffmpeg once and cached. Null if it can't be determined.
  Future<double?> gainFor(String path) async {
    final cached = _gains[path];
    if (cached != null) return cached;
    if (_measuring.contains(path)) return null;
    _measuring.add(path);
    try {
      final loudness = await _loudnessFromTags(path) ?? await _measureLoudness(path);
      if (loudness == null) return null;
      final gain = (targetLufs - loudness).clamp(_maxCutDb, _maxBoostDb).toDouble();
      _gains[path] = double.parse(gain.toStringAsFixed(2));
      _scheduleSave();
      return _gains[path];
    } catch (e) {
      debugPrint('Normalization gain failed for $path: $e');
      return null;
    } finally {
      _measuring.remove(path);
    }
  }

  /// Integrated loudness (LUFS) implied by ReplayGain / R128 tags, if any.
  Future<double?> _loudnessFromTags(String path) async {
    final session = await FFprobeKit.getMediaInformation(path);
    final info = session.getMediaInformation();
    if (info == null) return null;
    final tags = <String, String>{};
    void addAll(Map? m) => m?.forEach((k, v) => tags[k.toString().toLowerCase()] = v.toString());
    addAll(info.getTags());
    for (final s in info.getStreams()) {
      addAll(s.getTags());
    }
    return loudnessFromTagMap(tags);
  }

  /// Pure helper (unit-tested): LUFS from a lowercase tag map.
  @visibleForTesting
  static double? loudnessFromTagMap(Map<String, String> tags) {
    final rg = tags['replaygain_track_gain'];
    if (rg != null) {
      final m = RegExp(r'(-?\+?\d+(?:\.\d+)?)').firstMatch(rg);
      if (m != null) {
        final gain = double.parse(m.group(1)!.replaceAll('+', ''));
        return _rgReferenceLufs - gain;
      }
    }
    final r128 = tags['r128_track_gain'];
    if (r128 != null) {
      final q78 = int.tryParse(r128.trim());
      if (q78 != null) return _r128ReferenceLufs - q78 / 256.0;
    }
    return null;
  }

  Future<double?> _measureLoudness(String path) async {
    final session = await FFmpegKit.executeWithArguments([
      '-hide_banner', '-nostats', '-i', path, '-vn', '-sn', '-dn',
      '-af', 'ebur128=framelog=quiet', '-f', 'null', '-',
    ]);
    final logs = await session.getAllLogsAsString() ?? '';
    return parseIntegratedLoudness(logs);
  }

  /// Pure helper (unit-tested): integrated loudness from ebur128 output.
  @visibleForTesting
  static double? parseIntegratedLoudness(String logs) {
    final matches = RegExp(r'I:\s+(-?\d+(?:\.\d+)?)\s+LUFS').allMatches(logs).toList();
    if (matches.isEmpty) return null;
    final v = double.parse(matches.last.group(1)!);
    // ebur128 reports -70 LUFS for silence; don't boost silence to target.
    return v <= -69 ? null : v;
  }

  /// Pre-measures [paths] in the background (used by "Analyze library").
  Future<int> analyzeAll(List<String> paths, {void Function(int done, int total)? onProgress}) async {
    var done = 0;
    for (final p in paths) {
      if (!_gains.containsKey(p)) await gainFor(p);
      done++;
      onProgress?.call(done, paths.length);
    }
    changes.value++;
    return done;
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 2), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kGains, jsonEncode(_gains));
      } catch (_) {}
    });
  }
}
