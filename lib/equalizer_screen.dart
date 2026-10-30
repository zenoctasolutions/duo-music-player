// lib/equalizer_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:music/list_page.dart';
import 'app_palette.dart';
import 'sound_effects_page.dart';
import 'eq_profile_service.dart';
import 'ad_widgets.dart';

class EqualizerScreen extends StatefulWidget {
  final int? audioSessionId;
  final bool isDark;

  const EqualizerScreen({
    Key? key,
    this.audioSessionId,
    required this.isDark,
  }) : super(key: key);

  @override
  State<EqualizerScreen> createState() => _EqualizerScreenState();
}

class _EqualizerScreenState extends State<EqualizerScreen> {
  static const MethodChannel _eqChannel = MethodChannel('music_app/equalizer');

  bool _initialized = false;
  bool _enabled = false;
  List<int> _bandRange = [-1500, 1500];
  List<int> _centerFreqs = [60, 230, 910, 3600, 14000];
  List<String> _nativePresets = [];
  Map<String, Map<int, int>> _customPresets = {};

  List<String> get _allPresets => [..._nativePresets, ..._customPresets.keys];

  int? _selectedPresetIndex;
  Map<int, int> _bandLevels = {};
  bool _loading = true;
  bool _isManual = false;
  Timer? _liveUpdateTimer;

  static Color get kAccent => AppPalette.accent;

  late bool _isDarkSystem;
  late Color _accentColor;
  late Color _bgColor;
  late Color _cardColor;
  late Color _primaryText;
  late Color _secondaryText;
  late Color _sliderActive;
  late Color _sliderInactive;
  late Color _sliderThumb;
  late Color _disabledThumb;
  late Color _disabledActiveTrack;
  late Color _disabledInactiveTrack;

  SharedPreferences? _prefs;
  int? _lastSessionId;
  String? _statusMessage;

  bool get _hasValidSession => (widget.audioSessionId ?? 0) > 0;
  bool get _isCurrentlyPlaying => PlaybackState.current.value != null;

  @override
  void initState() {
    super.initState();
    EqProfileService.instance.changes.addListener(_onProfileChanged);
    _initPrefsAndEqualizer();
  }

  /// Output switched (e.g. earbuds connected) or per-output mode toggled:
  /// reload the sliders for the now-active profile.
  void _onProfileChanged() {
    if (!mounted) return;
    setState(() => _loading = true);
    _initPrefsAndEqualizer();
  }

  @override
  void didUpdateWidget(covariant EqualizerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.audioSessionId != widget.audioSessionId) {
      _initPrefsAndEqualizer();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateThemeColors();
  }

  @override
  void dispose() {
    EqProfileService.instance.changes.removeListener(_onProfileChanged);
    _liveUpdateTimer?.cancel();
    super.dispose();
  }

  void _updateThemeColors() {
    final brightness = Theme.of(context).brightness;
    _isDarkSystem = brightness == Brightness.dark;

    _accentColor = kAccent;
    _bgColor = _isDarkSystem ? AppPalette.darkBackground : Colors.white;
    _cardColor = _isDarkSystem ? AppPalette.darkCard : Colors.white;
    _primaryText = _isDarkSystem ? Colors.white : Colors.black;
    _secondaryText = _isDarkSystem ? Colors.white70 : const Color(0xFF666666);

    _sliderActive = _accentColor;
    _sliderThumb = _accentColor;

    if (!_isDarkSystem) {
      _sliderInactive = Colors.grey.shade300;
      _disabledActiveTrack = Colors.grey.shade300;
      _disabledInactiveTrack = Colors.grey.shade200;
      _disabledThumb = Colors.grey.shade600;
    } else {
      _sliderInactive = Colors.white24;
      _disabledActiveTrack = Colors.white54;
      _disabledInactiveTrack = Colors.white24;
      _disabledThumb = Colors.white70;
    }
  }

  // --------------------------------------------------------------------------
  // STORAGE
  // --------------------------------------------------------------------------

  Future<void> _initPrefsAndEqualizer() async {
    _prefs = await SharedPreferences.getInstance();
    await _loadCustomPresetsFromPrefs();

    if (!mounted) return;

    if (!_hasValidSession && !_isCurrentlyPlaying) {
      setState(() {
        _loading = false;
        _initialized = false;
        _enabled = false;
        _selectedPresetIndex = null;
        _bandLevels = {};
        _statusMessage = 'Play a song first to use Equalizer.';
      });
      return;
    }

    await _initEqualizer();
  }

  String _presetDisplayName(int index, String originalName) {
    const customNames = [
      'Normal',
      'Classical',
      'Dance',
      'Flat',
      'Folk',
      'Heavy Metal',
      'Hip Hop',
      'Jazz',
      'Pop',
      'Rock',
    ];

    if (index >= 0 && index < customNames.length) {
      return customNames[index];
    }
    return originalName;
  }

  // Durable per-output-profile keys (EqProfileService) — the old keys were
  // per audio-session id, which changes every launch. [sid] is unused.
  String _prefKeyForSession(int sid) => EqProfileService.instance.enabledKey();
  String _prefPresetKey(int sid) => EqProfileService.instance.presetKey();
  String _prefBandKey(int sid, int band) => EqProfileService.instance.bandKey(band);
  String _prefCustomPresetsKey() => 'eq_custom_presets';

  Future<void> _loadCustomPresetsFromPrefs() async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      final jsonStr = _prefs!.getString(_prefCustomPresetsKey());
      if (jsonStr == null || jsonStr.trim().isEmpty) return;

      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map) return;

      final Map<String, Map<int, int>> loaded = {};
      decoded.forEach((key, value) {
        if (value is Map) {
          final Map<int, int> bandMap = {};
          value.forEach((k, v) {
            final band = int.tryParse(k.toString()) ?? 0;
            final level = (v is num) ? v.toInt() : int.tryParse(v.toString()) ?? 0;
            bandMap[band] = level;
          });
          loaded[key.toString()] = bandMap;
        }
      });

      if (mounted) {
        setState(() {
          _customPresets = loaded;
        });
      } else {
        _customPresets = loaded;
      }
    } catch (e) {
      debugPrint('Failed to load custom presets: $e');
    }
  }

  Future<void> _saveCustomPresetsToPrefs() async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> toEncode = {};
      _customPresets.forEach((key, value) {
        toEncode[key] = value.map((k, v) => MapEntry(k.toString(), v));
      });
      await _prefs!.setString(_prefCustomPresetsKey(), jsonEncode(toEncode));
    } catch (e) {
      debugPrint('Save custom presets error: $e');
    }
  }

  Future<void> _saveEnabledPref(int sid, bool enabled) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      await _prefs!.setBool(_prefKeyForSession(sid), enabled);
    } catch (_) {}
  }

  Future<bool?> _loadEnabledPref(int sid) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      if (_prefs!.containsKey(_prefKeyForSession(sid))) {
        return _prefs!.getBool(_prefKeyForSession(sid));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveSelectedPreset(int sid, int? index) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      if (index == null) {
        await _prefs!.remove(_prefPresetKey(sid));
      } else {
        await _prefs!.setInt(_prefPresetKey(sid), index);
      }
    } catch (_) {}
  }

  Future<int?> _loadSelectedPreset(int sid) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      if (_prefs!.containsKey(_prefPresetKey(sid))) {
        return _prefs!.getInt(_prefPresetKey(sid));
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveBandLevelPref(int sid, int band, int level) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      await _prefs!.setInt(_prefBandKey(sid, band), level);
    } catch (_) {}
  }

  Future<int?> _loadBandLevelPref(int sid, int band) async {
    try {
      if (_prefs == null) _prefs = await SharedPreferences.getInstance();
      if (_prefs!.containsKey(_prefBandKey(sid, band))) {
        return _prefs!.getInt(_prefBandKey(sid, band));
      }
    } catch (_) {}
    return null;
  }

  Future<Map<int, int>> _loadSavedBandLevels(int sid, List<int> bands) async {
    final Map<int, int> res = {};
    for (final bIndex in bands.asMap().keys) {
      final val = await _loadBandLevelPref(sid, bIndex);
      if (val != null) res[bIndex] = val;
    }
    return res;
  }

  // --------------------------------------------------------------------------
  // METHOD CHANNEL
  // --------------------------------------------------------------------------

  Future<T?> _safeInvoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final dynamic res = await invokeChannelRetry<dynamic>(
        _eqChannel,
        method,
        args ?? {'sessionId': widget.audioSessionId ?? 0},
      );
      return res as T?;
    } on PlatformException catch (e) {
      debugPrint('Method channel error on $method: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Method channel error on $method: $e');
      return null;
    }
  }

  Future<void> _initEqualizer() async {
    final sid = widget.audioSessionId ?? 0;
    _lastSessionId = sid;

    try {
      final bool? okRaw = await _safeInvoke<bool>('initEqualizer', {'sessionId': sid});
      final bool ok = okRaw == true;

      if (!ok) {
        if (mounted) {
          setState(() {
            _loading = false;
            _initialized = false;
            _statusMessage = _isCurrentlyPlaying
                ? 'Equalizer could not attach to the current song.'
                : 'Play a song first to use Equalizer.';
          });
        }
        return;
      }

      final bool? stored = await _loadEnabledPref(sid);
      final bool initialEnabled = stored ?? false;

      try {
        await _eqChannel.invokeMethod('setEnabled', {
          'sessionId': sid,
          'enabled': initialEnabled,
        });
      } catch (_) {}

      final bandRange = await _safeInvoke<List<dynamic>>('getBandLevelRange', {'sessionId': sid});
      final centerFreqs = await _safeInvoke<List<dynamic>>('getCenterBandFreqs', {'sessionId': sid});
      final presets = await _safeInvoke<List<dynamic>>('getPresetNames', {'sessionId': sid});

      int min = -1500, max = 1500;
      if (bandRange != null && bandRange.length >= 2) {
        min = (bandRange[0] is int) ? bandRange[0] as int : (bandRange[0] as num).toInt();
        max = (bandRange[1] is int) ? bandRange[1] as int : (bandRange[1] as num).toInt();
      }

      List<int> freqs = _centerFreqs;
      if (centerFreqs != null && centerFreqs.isNotEmpty) {
        freqs = centerFreqs.map<int>((e) => (e is int) ? e : (e as num).toInt()).toList();
      }

      List<String> presetNames = [];
      if (presets != null && presets.isNotEmpty) {
        presetNames = presets.map((e) => e?.toString() ?? '').toList().cast<String>();
      }

      final savedBands = await _loadSavedBandLevels(sid, freqs);
      final savedPreset = await _loadSelectedPreset(sid);

      final Map<int, int> bandMap = {};
      int? effectiveSelectedPreset;
      bool manual = false;

      if (savedPreset != null && savedPreset >= 0 && savedPreset < _allPresets.length) {
        effectiveSelectedPreset = savedPreset;

        if (savedPreset < presetNames.length) {
          try {
            await _eqChannel.invokeMethod('usePreset', {
              'sessionId': sid,
              'index': savedPreset,
            });
            for (int i = 0; i < freqs.length; i++) {
              final lvl = await _safeInvoke<dynamic>('getBandLevel', {
                'sessionId': sid,
                'band': i,
              });
              bandMap[i] = (lvl is int) ? lvl : (lvl is num ? lvl.toInt() : 0);
            }
          } catch (_) {
            effectiveSelectedPreset = null;
          }
        } else {
          final customName = _allPresets[savedPreset];
          final customLevels = _customPresets[customName];
          if (customLevels != null) {
            for (final e in customLevels.entries) {
              try {
                await _eqChannel.invokeMethod('setBandLevel', {
                  'sessionId': sid,
                  'band': e.key,
                  'level': e.value,
                });
                bandMap[e.key] = e.value;
              } catch (_) {}
            }
          }
        }
      } else if (savedBands.isNotEmpty) {
        for (final e in savedBands.entries) {
          try {
            await _eqChannel.invokeMethod('setBandLevel', {
              'sessionId': sid,
              'band': e.key,
              'level': e.value,
            });
            bandMap[e.key] = e.value;
          } catch (_) {}
        }
        effectiveSelectedPreset = null;
        manual = true;
        await _saveSelectedPreset(sid, null);
      } else {
        for (int i = 0; i < freqs.length; i++) {
          try {
            final lvl = await _safeInvoke<dynamic>('getBandLevel', {
              'sessionId': sid,
              'band': i,
            });
            bandMap[i] = (lvl is int) ? lvl : (lvl is num ? lvl.toInt() : 0);
          } catch (_) {
            bandMap[i] = 0;
          }
        }
        effectiveSelectedPreset = null;
      }

      if (mounted) {
        setState(() {
          _initialized = true;
          _enabled = initialEnabled;
          _bandRange = [min, max];
          _centerFreqs = freqs;
          _nativePresets = presetNames;
          _bandLevels = bandMap;
          _loading = false;
          _selectedPresetIndex = effectiveSelectedPreset;
          _isManual = manual;
          _statusMessage = null;
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _initialized = false;
          _statusMessage = _isCurrentlyPlaying
              ? 'Equalizer could not attach to the current song.'
              : 'Play a song first to use Equalizer.';
        });
      }
      _showError('Equalizer init failed: ${e.message}');
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _initialized = false;
          _statusMessage = _isCurrentlyPlaying
              ? 'Equalizer could not attach to the current song.'
              : 'Play a song first to use Equalizer.';
        });
      }
      _showError('Equalizer init error: $e');
    }
  }

  Future<void> _setEnabled(bool v) async {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) {
      _showError(_isCurrentlyPlaying
          ? 'Equalizer could not attach to the current song.'
          : 'Play a song first to use Equalizer.');
      return;
    }

    try {
      await _eqChannel.invokeMethod('setEnabled', {
        'sessionId': sid,
        'enabled': v,
      });
      await _saveEnabledPref(sid, v);

      if (!v) {
        for (int i = 0; i < _centerFreqs.length; i++) {
          _bandLevels[i] = 0;
          await _saveBandLevelPref(sid, i, 0);
        }
        await _saveSelectedPreset(sid, null);
        if (mounted) {
          setState(() {
            _selectedPresetIndex = null;
            _isManual = false;
            _bandLevels = {
              for (int i = 0; i < _centerFreqs.length; i++) i: 0
            };
          });
        }
      } else {
        if (mounted) setState(() => _enabled = v);
      }

      if (mounted) setState(() => _enabled = v);
    } catch (e) {
      _showError('Failed to ${v ? 'enable' : 'disable'} equalizer: $e');
    }
  }

  Future<void> _usePreset(int index) async {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) {
      _showError(_isCurrentlyPlaying
          ? 'Equalizer could not attach to the current song.'
          : 'Play a song first to use Equalizer.');
      return;
    }

    try {
      if (index < _nativePresets.length) {
        await _eqChannel.invokeMethod('usePreset', {
          'sessionId': sid,
          'index': index,
        });
        await _refreshAllBandLevels();
      } else {
        final customName = _allPresets[index];
        final customLevels = _customPresets[customName];
        if (customLevels != null) {
          for (final e in customLevels.entries) {
            await _eqChannel.invokeMethod('setBandLevel', {
              'sessionId': sid,
              'band': e.key,
              'level': e.value,
            });
            if (mounted) {
              setState(() {
                _bandLevels[e.key] = e.value;
              });
            }
          }
        }
      }

      await _saveSelectedPreset(sid, index);
      for (final e in _bandLevels.entries) {
        await _saveBandLevelPref(sid, e.key, e.value);
      }

      if (mounted) {
        setState(() {
          _selectedPresetIndex = index;
          _isManual = false;
        });
      }
    } catch (e) {
      _showError('Failed to apply preset: $e');
    }
  }

  void _onBandChangedLive(int band, int level) {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) {
      _showError(_isCurrentlyPlaying
          ? 'Equalizer could not attach to the current song.'
          : 'Play a song first to use Equalizer.');
      return;
    }

    if (!_enabled) {
      _setEnabled(true);
    }

    setState(() {
      _bandLevels[band] = level;
      _isManual = true;
      _selectedPresetIndex = null;
    });

    if (_liveUpdateTimer?.isActive ?? false) {
      _liveUpdateTimer!.cancel();
    }

    _liveUpdateTimer = Timer(const Duration(milliseconds: 40), () {
      _eqChannel.invokeMethod('setBandLevel', {
        'sessionId': sid,
        'band': band,
        'level': level,
      }).catchError((_) {});
    });
  }

  Future<void> _onBandChangeEnd(int band, int level) async {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) return;

    try {
      await _eqChannel.invokeMethod('setBandLevel', {
        'sessionId': sid,
        'band': band,
        'level': level,
      });
      await _saveBandLevelPref(sid, band, level);
      await _saveSelectedPreset(sid, null);
    } catch (e) {
      _showError('Failed to apply band level: $e');
    }
  }

  Future<void> _refreshAllBandLevels() async {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) return;

    final Map<int, int> temp = {};
    for (int i = 0; i < _centerFreqs.length; i++) {
      try {
        final lvl = await _safeInvoke<dynamic>('getBandLevel', {
          'sessionId': sid,
          'band': i,
        });
        temp[i] = (lvl is int) ? lvl : (lvl is num ? lvl.toInt() : 0);
      } catch (_) {
        temp[i] = 0;
      }
    }

    if (mounted) {
      setState(() {
        _bandLevels = temp;
      });
    }
  }

  Future<void> _saveAsCustomPreset() async {
    final sid = widget.audioSessionId ?? 0;
    if (sid <= 0) {
      _showError(_isCurrentlyPlaying
          ? 'Equalizer could not attach to the current song.'
          : 'Play a song first to use Equalizer.');
      return;
    }

    final controller = TextEditingController();

    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: _cardColor,
          title: Text('Save Custom Preset', style: TextStyle(color: _primaryText)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(color: _primaryText),
            decoration: InputDecoration(
              hintText: 'Preset Name',
              hintStyle: TextStyle(color: _secondaryText),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: _secondaryText),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: _accentColor),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Cancel', style: TextStyle(color: _secondaryText)),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(context, name);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: _accentColor),
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );

    if (result != null && result.isNotEmpty) {
      setState(() {
        _customPresets[result] = Map<int, int>.from(_bandLevels);
        _selectedPresetIndex =
            _nativePresets.length + _customPresets.keys.toList().indexOf(result);
        _isManual = false;
      });
      await _saveCustomPresetsToPrefs();
      await _saveSelectedPreset(sid, _selectedPresetIndex);
    }
  }

  Future<void> _deleteCustomPreset(String name) async {
    final sid = widget.audioSessionId ?? 0;

    setState(() {
      _customPresets.remove(name);
      _selectedPresetIndex = null;
      _isManual = true;
    });

    await _saveCustomPresetsToPrefs();
    await _saveSelectedPreset(sid, null);
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // UI
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: const Text('Equalizer'),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: _isDarkSystem ? AppPalette.darkBackground : Colors.white,
        foregroundColor: _primaryText,
        elevation: 2,
        shadowColor: _isDarkSystem ? Colors.grey.withOpacity(0.3) : Colors.black54,
        actions: [
          IconButton(
            tooltip: 'Sound effects',
            icon: const Icon(Icons.surround_sound_rounded),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => SoundEffectsPage(isDark: _isDarkSystem)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
              children: [
                Text(
                  _enabled ? 'ON' : 'OFF',
                  style: TextStyle(
                    color: _enabled ? _accentColor : _secondaryText,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Transform.scale(
                  scale: 0.8,
                  child: Switch(
                    value: _enabled,
                    activeColor: _accentColor,
                    activeTrackColor: _accentColor.withOpacity(0.5),
                    inactiveThumbColor: _secondaryText,
                    inactiveTrackColor: _sliderInactive,
                    onChanged: _initialized
                        ? (v) async {
                      if (!v) {
                        final sid = widget.audioSessionId ?? 0;
                        for (int i = 0; i < _centerFreqs.length; i++) {
                          try {
                            await _eqChannel.invokeMethod('setBandLevel', {
                              'sessionId': sid,
                              'band': i,
                              'level': 0,
                            });
                          } catch (_) {}
                        }

                        if (mounted) {
                          setState(() {
                            _bandLevels = {
                              for (int i = 0; i < _centerFreqs.length; i++) i: 0
                            };
                            _selectedPresetIndex = null;
                            _isManual = false;
                          });
                        }
                      }

                      await _setEnabled(v);
                    }
                        : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: _loading
          ? _buildLoadingState()
          : (!_initialized)
          ? _buildErrorState()
          : _buildEqualizerUI(),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: _accentColor),
          const SizedBox(height: 16),
          Text(
            'Loading Equalizer...',
            style: TextStyle(
              color: _primaryText,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    final message = _statusMessage ??
        (_isCurrentlyPlaying
            ? 'Equalizer could not attach to the current song.'
            : 'Play a song first to use Equalizer.');

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.equalizer_rounded,
              size: 64,
              color: _secondaryText,
            ),
            const SizedBox(height: 16),
            Text(
              'Equalizer Not Available',
              style: TextStyle(
                color: _primaryText,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                color: _secondaryText,
                fontSize: 14,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _initPrefsAndEqualizer,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accentColor,
                foregroundColor: Colors.white,
              ),
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEqualizerUI() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLandscape = constraints.maxWidth > constraints.maxHeight;

        // Common components
        final presetSection = _allPresets.isNotEmpty ? _buildPresetsSection() : const SizedBox.shrink();

        final saveButton = (_isManual && _enabled)
            ? SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _saveAsCustomPreset,
            icon: Icon(Icons.save, color: _accentColor, size: 20),
            label: Text(
              'Save as Custom Preset',
              style: TextStyle(color: _accentColor),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: _accentColor),
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        )
            : const SizedBox.shrink();

        final resetButton = _buildResetButton();

        final visualizerAndSliders = Container(
          decoration: BoxDecoration(
            color: _cardColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: _isDarkSystem ? Colors.grey.withOpacity(0.2) : Colors.black54,
                blurRadius: 15,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: EdgeInsets.all(isLandscape ? 12 : 20), // Less padding in landscape
          child: Column(
            children: [
              _buildVisualizer(isLandscape),
              SizedBox(height: isLandscape ? 16 : 32),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: _centerFreqs.asMap().entries.map((entry) {
                    final bandId = entry.key;
                    final freq = entry.value;
                    final min = _bandRange[0].toDouble();
                    final max = _bandRange[1].toDouble();
                    final cur = (_bandLevels[bandId] ?? 0).toDouble();

                    final slider = _BandSlider(
                      compact: _centerFreqs.length > 6,
                      bandId: bandId,
                      freqHz: freq,
                      min: min,
                      max: max,
                      value: cur,
                      enabled: _enabled,
                      onChanged: (v) => _onBandChangedLive(bandId, v.toInt()),
                      onChangeEnd: (v) => _onBandChangeEnd(bandId, v.toInt()),
                      accentColor: _accentColor,
                      cardColor: _cardColor,
                      primaryText: _primaryText,
                      secondaryText: _secondaryText,
                      sliderActive: _sliderActive,
                      sliderInactive: _sliderInactive,
                      sliderThumb: _sliderThumb,
                      disabledThumb: _disabledThumb,
                      disabledActiveTrack: _disabledActiveTrack,
                      disabledInactiveTrack: _disabledInactiveTrack,
                    );
                    // 10-band EQ: share the width evenly so all bands fit.
                    return _centerFreqs.length > 6 ? Expanded(child: slider) : slider;
                  }).toList(),
                ),
              ),
            ],
          ),
        );

        if (isLandscape) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Left panel: controls
                Expanded(
                  flex: 1,
                  child: Column(
                    children: [
                      _buildProfileBar(),
                      const SizedBox(height: 12),
                      presetSection,
                      const Spacer(),
                      if (_isManual && _enabled) ...[
                        saveButton,
                        const SizedBox(height: 12),
                      ],
                      resetButton,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Right panel: visualizer and sliders
                Expanded(
                  flex: 2,
                  child: visualizerAndSliders,
                ),
              ],
            ),
          );
        } else {
          // Portrait
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _buildProfileBar(),
                const SizedBox(height: 12),
                if (_allPresets.isNotEmpty) presetSection,
                if (_allPresets.isNotEmpty) const SizedBox(height: 16),
                Expanded(child: visualizerAndSliders),
                const SizedBox(height: 16),
                if (_isManual && _enabled) ...[
                  saveButton,
                  const SizedBox(height: 12),
                ],
                resetButton,
              ],
            ),
          );
        }
      },
    );
  }

  Widget _buildProfileBar() {
    final svc = EqProfileService.instance;
    final icon = switch (svc.route.type) {
      'bluetooth' => Icons.bluetooth_audio_rounded,
      'wired' => Icons.headphones_rounded,
      _ => Icons.phone_android_rounded,
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(color: _cardColor, borderRadius: BorderRadius.circular(14)),
      child: Row(children: [
        Icon(svc.perOutput ? icon : Icons.devices_rounded, color: _accentColor, size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('Profile: ${svc.profileLabel}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _primaryText, fontWeight: FontWeight.w600)),
            Text(svc.perOutput ? 'Separate EQ for each output' : 'Same EQ for every output',
                style: TextStyle(color: _secondaryText, fontSize: 11)),
          ]),
        ),
        Switch(
          value: svc.perOutput,
          activeColor: _accentColor,
          onChanged: (v) => svc.setPerOutput(v),
        ),
      ]),
    );
  }

  Widget _buildPresetsSection() {
    final dropdownColor = _isDarkSystem ? AppPalette.darkCard : Colors.white;
    final dropdownTextColor = _isDarkSystem ? Colors.white : Colors.black;

    return Container(
      decoration: BoxDecoration(
        color: _cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: _isDarkSystem ? Colors.grey.withOpacity(0.2) : Colors.black54,
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.tune_rounded, color: _accentColor, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  isExpanded: true,
                  value: _selectedPresetIndex,
                  hint: Text(
                    _isManual ? 'Custom (Unsaved)' : 'Select Preset',
                    style: TextStyle(
                      color: _isManual ? _accentColor : _secondaryText,
                      fontWeight: _isManual ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  icon: Icon(Icons.arrow_drop_down_rounded, color: _accentColor),
                  dropdownColor: dropdownColor,
                  style: TextStyle(color: dropdownTextColor),
                  items: _allPresets.asMap().entries.map((e) {
                    final isCustom = e.key >= _nativePresets.length;
                    final displayName = isCustom
                        ? e.value
                        : _presetDisplayName(e.key, e.value);

                    return DropdownMenuItem(
                      value: e.key,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              displayName,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: dropdownTextColor,
                                fontWeight: isCustom
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                              ),
                            ),
                          ),
                          if (isCustom)
                            IconButton(tooltip: 'Delete preset', 
                              icon: const Icon(
                                Icons.delete,
                                color: Colors.redAccent,
                                size: 20,
                              ),
                              onPressed: () {
                                Navigator.pop(context);
                                _deleteCustomPreset(e.value);
                              },
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: _enabled
                      ? (idx) {
                    if (idx != null) _usePreset(idx);
                  }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVisualizer(bool isLandscape) {
    return Container(
      height: isLandscape ? 50 : 80,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: _isDarkSystem
              ? [const Color(0xFF1A1A1A), const Color(0xFF2D2D2D)]
              : [const Color(0xFFF0F0F0), const Color(0xFFE0E0E0)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _VisualizerPainter(
          bandLevels: _bandLevels,
          centerFreqs: _centerFreqs,
          enabled: _enabled,
          accentColor: _accentColor,
          backgroundColor: _isDarkSystem ? const Color(0xFF2D2D2D) : const Color(0xFFE0E0E0),
          isDark: _isDarkSystem,
        ),
      ),
    );
  }

  Widget _buildResetButton() {
    return SafeArea(
      top: false, // We only need to protect the bottom edge from the nav bar
      left: false,
      right: false,
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _enabled
              ? () async {
            final sid = widget.audioSessionId ?? 0;
            if (sid <= 0) return;

            for (int i = 0; i < _centerFreqs.length; i++) {
              try {
                await _eqChannel.invokeMethod('setBandLevel', {
                  'sessionId': sid,
                  'band': i,
                  'level': 0,
                });
                if (mounted) {
                  setState(() {
                    _bandLevels[i] = 0;
                  });
                }
                await _saveBandLevelPref(sid, i, 0);
              } catch (_) {}
            }

            await _saveSelectedPreset(sid, null);
            if (mounted) {
              setState(() {
                _selectedPresetIndex = null;
                _isManual = false;
              });
            }
          }
              : null,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          label: const Text('Reset to Flat'),
          style: ElevatedButton.styleFrom(
            backgroundColor: _accentColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 2,
          ),
        ),
      ),
    );
  }
}

class _BandSlider extends StatefulWidget {
  /// Narrow layout for 10-band mode.
  final bool compact;
  final int bandId;
  final int freqHz;
  final double min;
  final double max;
  final double value;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final Color accentColor;
  final Color cardColor;
  final Color primaryText;
  final Color secondaryText;
  final Color sliderActive;
  final Color sliderInactive;
  final Color sliderThumb;
  final Color disabledThumb;
  final Color disabledActiveTrack;
  final Color disabledInactiveTrack;

  const _BandSlider({
    Key? key,
    this.compact = false,
    required this.bandId,
    required this.freqHz,
    required this.min,
    required this.max,
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.onChangeEnd,
    required this.accentColor,
    required this.cardColor,
    required this.primaryText,
    required this.secondaryText,
    required this.sliderActive,
    required this.sliderInactive,
    required this.sliderThumb,
    required this.disabledThumb,
    required this.disabledActiveTrack,
    required this.disabledInactiveTrack,
  }) : super(key: key);

  @override
  State<_BandSlider> createState() => _BandSliderState();
}

class _BandSliderState extends State<_BandSlider> with SingleTickerProviderStateMixin {
  late double _val;

  // True while the user drags this band; external value changes (a preset
  // being applied) glide to the new level instead of jumping.
  bool _dragging = false;
  late final AnimationController _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  Animation<double>? _glideAnim;

  @override
  void initState() {
    super.initState();
    _val = widget.value;
    _glide.addListener(() {
      final a = _glideAnim;
      if (a != null && mounted) setState(() => _val = a.value);
    });
  }

  @override
  void dispose() {
    _glide.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _BandSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value || widget.value == _val) return;
    if (_dragging || (MediaQuery.maybeOf(context)?.disableAnimations ?? false)) {
      _glide.stop();
      _val = widget.value;
      return;
    }
    _glideAnim = Tween<double>(begin: _val, end: widget.value)
        .animate(CurvedAnimation(parent: _glide, curve: Curves.easeOutCubic));
    _glide.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.freqHz >= 1000
        ? '${(widget.freqHz / 1000).toStringAsFixed(1)}k'
        : '${widget.freqHz}';
    final isZero = _val == 0;
    final enabled = widget.enabled;

    final dbValue = _val / 100.0;
    final dbString =
    dbValue > 0 ? '+${dbValue.toStringAsFixed(1)}' : dbValue.toStringAsFixed(1);

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Container(
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 2 : 8, vertical: 4),
          decoration: BoxDecoration(
            color: widget.cardColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 2,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Text(
            widget.compact ? dbString : '$dbString dB',
            maxLines: 1,
            style: TextStyle(
              color: isZero ? widget.secondaryText : widget.accentColor,
              fontSize: widget.compact ? 9 : 10,
              fontWeight: isZero ? FontWeight.normal : FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: RotatedBox(
              quarterTurns: 3,
              child: SliderTheme(
                data: SliderThemeData(
                  trackHeight: 6,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 8,
                    disabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: widget.sliderActive,
                  inactiveTrackColor: widget.sliderInactive,
                  thumbColor: widget.sliderThumb,
                  overlayColor: widget.sliderThumb.withOpacity(0.2),
                  disabledActiveTrackColor: widget.disabledActiveTrack,
                  disabledInactiveTrackColor: widget.disabledInactiveTrack,
                  disabledThumbColor: widget.disabledThumb,
                ),
                child: Slider(
                  value: _val.clamp(widget.min, widget.max),
                  min: widget.min,
                  max: widget.max,
                  onChanged: enabled
                      ? (v) {
                    _dragging = true;
                    _glide.stop();
                    setState(() => _val = v);
                    widget.onChanged(v);
                  }
                      : null,
                  onChangeEnd: enabled
                      ? (v) {
                    _dragging = false;
                    widget.onChangeEnd(v);
                  }
                      : null,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: widget.compact ? null : 50,
          padding: EdgeInsets.symmetric(vertical: 6, horizontal: widget.compact ? 1 : 0),
          decoration: BoxDecoration(
            color: enabled ? widget.accentColor.withOpacity(0.08) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: enabled ? widget.accentColor : widget.secondaryText,
              fontSize: widget.compact ? 9.5 : 12,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

class _VisualizerPainter extends CustomPainter {
  final Map<int, int> bandLevels;
  final List<int> centerFreqs;
  final bool enabled;
  final Color accentColor;
  final Color backgroundColor;
  final bool isDark;

  _VisualizerPainter({
    required this.bandLevels,
    required this.centerFreqs,
    required this.enabled,
    required this.accentColor,
    required this.backgroundColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = isDark
          ? Colors.white.withOpacity(0.06)
          : Colors.black.withOpacity(0.06)
      ..strokeWidth = 1;

    for (double i = 0; i <= size.height; i += size.height / 4) {
      canvas.drawLine(Offset(0, i), Offset(size.width, i), linePaint);
    }

    if (bandLevels.isEmpty || centerFreqs.isEmpty) return;

    final barWidth = size.width / centerFreqs.length;
    final maxLevel = _bandLevelsAbsMax().toDouble().clamp(1.0, 1500.0);

    for (int i = 0; i < centerFreqs.length; i++) {
      final level = bandLevels[i] ?? 0;
      final normalizedHeight =
          ((level.abs()) / maxLevel).clamp(0.0, 1.0) * size.height * 0.85;
      final barHeight = enabled ? normalizedHeight : normalizedHeight * 0.45;

      final xCenter = i * barWidth + barWidth / 2;
      final halfWidth = barWidth * 0.5 * 0.6;
      final left = xCenter - halfWidth;
      final right = xCenter + halfWidth;
      final top = size.height - barHeight;
      final rect = Rect.fromLTRB(left, top, right, size.height);

      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          enabled ? accentColor.withOpacity(0.95) : accentColor.withOpacity(0.35),
          enabled ? accentColor.withOpacity(0.65) : accentColor.withOpacity(0.22),
        ],
      ).createShader(rect);

      paint.shader = gradient;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(4)),
        paint,
      );
    }
  }

  int _bandLevelsAbsMax() {
    if (bandLevels.isEmpty) return 1500;
    final absMax = bandLevels.values.map((v) => v.abs()).fold<int>(0, (p, e) => e > p ? e : p);
    return (absMax <= 0) ? 1500 : (absMax < 100 ? 1500 : absMax);
  }

  @override
  bool shouldRepaint(covariant _VisualizerPainter oldDelegate) {
    return bandLevels != oldDelegate.bandLevels ||
        enabled != oldDelegate.enabled ||
        accentColor != oldDelegate.accentColor ||
        isDark != oldDelegate.isDark;
  }
}