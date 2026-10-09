// lib/eq_profile_service.dart
//
// Durable, per-output equalizer settings.
//
// The EQ used to save its state under the audio *session id*, which changes
// every app launch, so the EQ was effectively forgotten on restart and was
// only re-applied if the user opened the Equalizer screen. Settings are now
// stored per *profile* and applied automatically whenever the player's
// session changes or the audio output changes:
//   * per-output mode (default): one profile each for the phone speaker,
//     wired/USB headphones and every Bluetooth device by name
//     ("bt:Galaxy Buds", "bt:Car Audio" …) — like Pulsar's per-device EQ;
//   * single mode: one profile ("default") for everything.
// The Equalizer screen reads/writes the same keys (see keysFor*).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OutputRoute {
  final String type; // speaker | wired | bluetooth
  final String name;
  const OutputRoute(this.type, this.name);

  static const speaker = OutputRoute('speaker', 'Phone speaker');

  /// Profile key; Bluetooth devices get one each.
  String get key => type == 'bluetooth' ? 'bt:${name.trim()}' : type;

  String get label => switch (type) {
        'bluetooth' => name,
        'wired' => 'Headphones',
        _ => 'Phone speaker',
      };
}

class EqProfileService {
  EqProfileService._();
  static final EqProfileService instance = EqProfileService._();

  static const MethodChannel _channel = MethodChannel('music_app/equalizer');
  static const _kPerOutput = 'eq_per_output';
  static const _kCustomPresets = 'eq_custom_presets';

  bool perOutput = true;
  OutputRoute route = OutputRoute.speaker;

  /// Bumped when the active profile changes (output switched, mode toggled).
  final ValueNotifier<int> changes = ValueNotifier<int>(0);

  int? _sessionId;
  StreamSubscription<int?>? _sessionSub;
  bool _handlerSet = false;

  String get profileKey => perOutput ? route.key : 'default';
  String get profileLabel => perOutput ? route.label : 'All outputs';
  int? get sessionId => _sessionId;

  // Keys shared with the Equalizer screen.
  String enabledKey() => 'eqp_enabled_$profileKey';
  String presetKey() => 'eqp_preset_$profileKey';
  String bandKey(int band) => 'eqp_band_${profileKey}_$band';

  Future<void> attach(AudioPlayer player) async {
    final prefs = await SharedPreferences.getInstance();
    perOutput = prefs.getBool(_kPerOutput) ?? true;
    await _refreshRoute(notify: false);
    if (!_handlerSet) {
      _handlerSet = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'onOutputChanged' && call.arguments is Map) {
          final m = call.arguments as Map;
          await _setRoute(OutputRoute((m['type'] as String?) ?? 'speaker', (m['name'] as String?) ?? ''));
        }
      });
    }
    _sessionSub?.cancel();
    _sessionSub = player.androidAudioSessionIdStream.listen((sid) {
      if (sid == null || sid == 0 || sid == _sessionId) return;
      _sessionId = sid;
      unawaited(applyCurrent());
    });
  }

  Future<void> setPerOutput(bool v) async {
    perOutput = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kPerOutput, v);
    changes.value++;
    await applyCurrent();
  }

  Future<void> _refreshRoute({bool notify = true}) async {
    try {
      final m = await _channel.invokeMethod<Map>('getOutputRoute');
      if (m != null) {
        final r = OutputRoute((m['type'] as String?) ?? 'speaker', (m['name'] as String?) ?? '');
        if (notify) {
          await _setRoute(r);
        } else {
          route = r;
        }
      }
    } catch (_) {}
  }

  Future<void> _setRoute(OutputRoute r) async {
    final before = profileKey;
    route = r;
    if (profileKey != before) {
      changes.value++;
      await applyCurrent();
    }
  }

  /// Applies the active profile to the player's audio session.
  Future<void> applyCurrent() async {
    final sid = _sessionId;
    if (sid == null || sid == 0) return;
    try {
      final ok = await _channel.invokeMethod<bool>('initEqualizer', {'sessionId': sid}) ?? false;
      if (!ok) return;
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(enabledKey()) ?? false;
      final preset = prefs.getInt(presetKey());
      final nativePresets = ((await _channel.invokeMethod<List>('getPresetNames', {'sessionId': sid})) ?? const []).length;
      final bandCount = ((await _channel.invokeMethod<List>('getCenterBandFreqs', {'sessionId': sid})) ?? const []).length;

      if (preset != null && preset < nativePresets) {
        await _channel.invokeMethod('usePreset', {'sessionId': sid, 'index': preset});
      } else {
        Map<int, int> levels = {for (var b = 0; b < bandCount; b++) b: prefs.getInt(bandKey(b)) ?? 0};
        if (preset != null) {
          // A custom preset (stored after the native ones).
          final custom = _customPreset(prefs, preset - nativePresets);
          if (custom != null) levels = {...levels, ...custom};
        }
        for (final e in levels.entries) {
          await _channel.invokeMethod('setBandLevel', {'sessionId': sid, 'band': e.key, 'level': e.value});
        }
      }
      // setBandLevel forces the effect on, so set the real state last.
      await _channel.invokeMethod('setEnabled', {'sessionId': sid, 'enabled': enabled});
    } catch (e) {
      debugPrint('EQ profile apply failed: $e');
    }
  }

  Map<int, int>? _customPreset(SharedPreferences prefs, int customIndex) {
    try {
      final raw = prefs.getString(_kCustomPresets);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final names = decoded.keys.toList();
      if (customIndex < 0 || customIndex >= names.length) return null;
      final m = decoded[names[customIndex]] as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(int.parse(k), (v as num).toInt()));
    } catch (_) {
      return null;
    }
  }
}
