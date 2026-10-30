// lib/duo_page.dart
//
// Duo Mode tab: pick one song for the left ear and another for the right,
// then share a pair of earphones. See duo_service.dart for the engine side.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;

import 'app_palette.dart';
import 'duo_service.dart';
import 'motion/motion_kit.dart';
import 'ui/app_page_bar.dart';

const Color kDuoLeftColor = Color(0xFF4A90E2);
const Color kDuoRightColor = Color(0xFFE94E77);

class DuoPage extends StatefulWidget {
  final List<File> audioFiles;
  final bool isDark;
  final String Function(File file) resolveTitle;
  final String? Function(File file) resolveArtist;
  final Uint8List? Function(String path) resolveCover;

  const DuoPage({
    super.key,
    required this.audioFiles,
    required this.isDark,
    required this.resolveTitle,
    required this.resolveArtist,
    required this.resolveCover,
  });

  @override
  State<DuoPage> createState() => _DuoPageState();
}

class _DuoPageState extends State<DuoPage> {
  final DuoService _duo = DuoService.instance;
  DuoState _state = const DuoState();
  Timer? _poll;
  bool _loading = true;
  String? _prevHeadphones;
  bool _headphonesKnown = false;

  // Once the user picks "Play anyway", don't nag again until earphones are
  // connected and disconnected, or the tab is reopened.
  bool _speakerAccepted = false;

  // While the user drags a seek bar, don't let polling snap it back.
  final Map<DuoSide, double?> _dragSeek = {DuoSide.left: null, DuoSide.right: null};

  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _card => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _text => widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _sub => widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// False when Android 13+ notifications are blocked: Duo then plays with
  /// no notification, so there are no ear controls after leaving the app.
  bool _notificationsAllowed = true;
  AppLifecycleListener? _lifecycle;

  Future<void> _checkNotifications() async {
    final ok = await _duo.notificationsAllowed();
    if (mounted && ok != _notificationsAllowed) setState(() => _notificationsAllowed = ok);
  }

  Future<void> _init() async {
    // Back from system settings (notifications / Mono audio): re-check.
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_checkNotifications()));
    unawaited(_checkNotifications());
    await _duo.restoreSession(widget.audioFiles.map((f) => f.path).toSet());
    await _refresh();
    if (!mounted) return;
    setState(() => _loading = false);
    _poll = Timer.periodic(const Duration(milliseconds: 500), (_) => _refresh());
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _poll?.cancel();
    unawaited(_duo.saveSession());
    super.dispose();
  }

  Future<void> _refresh() async {
    final st = await _duo.getState();
    if (!mounted || st == null) {
      if (mounted && !_duo.supported) setState(() => _loading = false);
      return;
    }
    // Earphones unplugged mid-session: the engine already paused itself
    // (audio-becoming-noisy); tell the user why the music stopped.
    if (_headphonesKnown && _prevHeadphones != null && st.headphones == null && st.anyLoaded) {
      _snack('Earphones disconnected — Duo Mode paused.');
      _speakerAccepted = false;
    }
    _prevHeadphones = st.headphones;
    _headphonesKnown = true;
    setState(() => _state = st);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 3)),
    );
  }

  /// Returns true when it's OK to start playback. Warns (and lets the user
  /// back out) when no earphones are connected, since on the phone speaker
  /// the two songs just play over each other.
  Future<bool> _confirmHeadphones() async {
    final hp = await _duo.headphones();
    if (hp != null) return true;
    if (_speakerAccepted || !mounted) return _speakerAccepted;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        icon: const Icon(Icons.headset_off_rounded, size: 40, color: Colors.orange),
        title: Text('Connect earphones', style: TextStyle(color: _text)),
        content: Text(
          'Duo Mode plays a different song in each ear, so it needs wired earphones or Bluetooth earbuds.\n\n'
          'Plug in your earphones or connect your earbuds, then press play. On the phone speaker both songs will play over each other.',
          style: TextStyle(color: _sub, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Play anyway', style: TextStyle(color: _sub))),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK')),
        ],
      ),
    );
    _speakerAccepted = proceed == true;
    return _speakerAccepted;
  }

  // ---------------------------------------------------------------- actions

  Future<void> _playBoth() async {
    if (_state.anyPlaying) {
      await _duo.pause();
    } else {
      if (!_state.anyLoaded) {
        _snack('Choose a song for each ear first.');
        return;
      }
      if (!await _confirmHeadphones()) return;
      await _duo.play();
    }
    await _refresh();
  }

  Future<void> _toggleSide(DuoSide side) async {
    final s = _state.side(side);
    if (s.playing) {
      await _duo.pause(side);
    } else {
      if (!await _confirmHeadphones()) return;
      await _duo.play(side);
    }
    await _refresh();
  }

  Future<void> _chooseSong(DuoSide side) async {
    if (widget.audioFiles.isEmpty) {
      _snack('No songs found on this device yet.');
      return;
    }
    final index = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => _SongPickerSheet(
        files: widget.audioFiles,
        side: side,
        isDark: widget.isDark,
        resolveTitle: widget.resolveTitle,
        resolveArtist: widget.resolveArtist,
        currentPath: _state.side(side).path,
        otherPath: _state.side(side.other).path,
      ),
    );
    if (index == null) return;
    final play = await _confirmHeadphones();
    final paths = widget.audioFiles.map((f) => f.path).toList();
    final titles = widget.audioFiles.map(widget.resolveTitle).toList();
    await _duo.setQueue(side, paths, titles, index, play: play);
    await _refresh();
  }

  String _titleFor(String path) {
    final f = widget.audioFiles.firstWhere((f) => f.path == path, orElse: () => File(path));
    return widget.resolveTitle(f);
  }

  String? _artistFor(String path) {
    final f = widget.audioFiles.firstWhere((f) => f.path == path, orElse: () => File(path));
    return widget.resolveArtist(f);
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '${d.inHours}:$m:$s' : '$m:$s';
  }

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppPageBar(
        title: 'Duo Mode',
        backgroundColor: _bg,
        foregroundColor: _text,
        actions: [
          IconButton(
            tooltip: 'How it works',
            icon: Icon(Icons.help_outline_rounded, color: _sub),
            onPressed: _showHelp,
          ),
        ],
      ),
      body: !_duo.supported
          ? _buildUnsupported()
          : _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: [
                    FadeSlideIn(index: 0, child: _buildHeader()),
                    _banner(show: _state.monoAudio, child: _buildMonoWarning()),
                    _banner(show: !_notificationsAllowed, child: _buildNotificationHint()),
                    const SizedBox(height: 16),
                    FadeSlideIn(index: 1, child: _buildSideCard(DuoSide.left)),
                    const SizedBox(height: 12),
                    FadeSlideIn(index: 2, child: _buildMasterControls()),
                    const SizedBox(height: 12),
                    FadeSlideIn(index: 3, child: _buildSideCard(DuoSide.right)),
                    const SizedBox(height: 16),
                    FadeSlideIn(index: 4, child: _buildMixCard()),
                    if (_state.anyLoaded) ...[
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton.icon(
                          onPressed: () async {
                            await _duo.stop();
                            await _refresh();
                          },
                          icon: Icon(Icons.stop_circle_outlined, color: _sub),
                          label: Text('End Duo session', style: TextStyle(color: _sub)),
                        ),
                      ),
                    ],
                  ],
                ),
    );
  }

  /// Slides/fades a warning banner in and collapses it when it goes away
  /// (the banner conditions flip as permissions / accessibility change).
  Widget _banner({required bool show, required Widget child}) {
    return AnimatedSize(
      duration: Motion.of(context, Motion.medium),
      curve: Motion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: Motion.of(context, Motion.medium),
        switchInCurve: Motion.standard,
        switchOutCurve: Curves.easeIn,
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SlideTransition(position: Tween(begin: const Offset(0, -0.15), end: Offset.zero).animate(a), child: c),
        ),
        child: show ? KeyedSubtree(key: const ValueKey('on'), child: child) : const SizedBox(key: ValueKey('off'), width: double.infinity),
      ),
    );
  }

  Widget _buildUnsupported() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text('Duo Mode is available on Android devices.', textAlign: TextAlign.center, style: TextStyle(color: _sub)),
        ),
      );

  Widget _buildHeader() {
    final hp = _state.headphones;
    final connected = hp != null;
    return AnimatedGradientHero(
      colors: const [kDuoLeftColor, kDuoRightColor],
      glowColor: kDuoRightColor,
      radius: 24,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.headphones_rounded, color: Colors.white, size: 34),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
              Text('Two songs. Two ears.', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 2),
              Text('Share your earphones — each of you hears your own song.', style: TextStyle(color: Colors.white70, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        AnimatedSwitcher(
          duration: Motion.of(context, Motion.medium),
          child: Container(
            key: ValueKey(connected),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(30)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(connected ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                  color: connected ? Colors.greenAccent : Colors.yellowAccent, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  connected ? 'Connected: $hp' : 'No earphones — plug in or connect Bluetooth earbuds',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                  maxLines: 2,
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildNotificationHint() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(widget.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Row(children: [
        const Icon(Icons.notifications_off_outlined, color: Colors.orange),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            'Notifications are off, so Duo Mode has no controls in the notification bar once you leave this screen.',
            style: TextStyle(color: _text, fontSize: 13, height: 1.35),
          ),
        ),
        TextButton(onPressed: () => openAppSettings(), child: const Text('Allow')),
      ]),
    );
  }

  Widget _buildMonoWarning() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(widget.isDark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.orange.withOpacity(0.5)),
      ),
      child: Row(children: [
        const Icon(Icons.hearing_rounded, color: Colors.orange),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            '"Mono audio" is turned on in Accessibility settings, so both songs will play in both ears. Turn it off to split them.',
            style: TextStyle(color: _text, fontSize: 13, height: 1.35),
          ),
        ),
        TextButton(onPressed: _duo.openAccessibilitySettings, child: const Text('Fix')),
      ]),
    );
  }

  Widget _buildSideCard(DuoSide side) {
    final s = _state.side(side);
    final color = side == DuoSide.left ? kDuoLeftColor : kDuoRightColor;
    final label = side == DuoSide.left ? 'LEFT EAR' : 'RIGHT EAR';
    final cover = s.path != null ? widget.resolveCover(s.path!) : null;
    final total = s.duration.inMilliseconds.toDouble();
    final pos = (_dragSeek[side] ?? s.position.inMilliseconds.toDouble()).clamp(0.0, total <= 0 ? 0.0 : total);

    return AnimatedContainer(
      duration: Motion.of(context, Motion.medium),
      curve: Motion.standard,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withOpacity(s.playing ? 0.8 : 0.25), width: s.playing ? 2 : 1),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(widget.isDark ? 0.25 : 0.05), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(side == DuoSide.left ? 'L' : 'R', style: TextStyle(color: color, fontWeight: FontWeight.w900)),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1)),
            ]),
          ),
          const Spacer(),
          if (s.loaded && s.queueLength > 1)
            Text('${s.index + 1} / ${s.queueLength}', style: TextStyle(color: _sub, fontSize: 12)),
        ]),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _chooseSong(side),
          // Keyed by the loaded path so changing the song cross-fades.
          child: AnimatedSwitcher(
            duration: Motion.of(context, Motion.medium),
            switchInCurve: Motion.standard,
            transitionBuilder: (c, a) => FadeTransition(
              opacity: a,
              child: SlideTransition(position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(a), child: c),
            ),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, if (current != null) current],
            ),
            child: Row(key: ValueKey(s.path ?? ''), children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Container(
                width: 56,
                height: 56,
                color: color.withOpacity(0.15),
                child: cover != null
                    ? Image.memory(cover, fit: BoxFit.cover, gaplessPlayback: true)
                    : Icon(Icons.music_note_rounded, color: color),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  s.loaded ? _titleFor(s.path!) : 'No song selected',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _text, fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const SizedBox(height: 3),
                Text(
                  s.loaded ? (_artistFor(s.path!) ?? 'Unknown artist') : 'Tap to choose a song for this ear',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _sub, fontSize: 13),
                ),
              ]),
            ),
            const SizedBox(width: 8),
            Icon(Icons.queue_music_rounded, color: color),
          ]),
          ),
        ),
        if (s.loaded) ...[
          Semantics(
            label: 'Seek',
            child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: pos.toDouble(),
              max: total <= 0 ? 1 : total,
              activeColor: color,
              inactiveColor: color.withOpacity(0.2),
              onChanged: total <= 0 ? null : (v) => setState(() => _dragSeek[side] = v),
              onChangeEnd: (v) async {
                await _duo.seek(side, Duration(milliseconds: v.toInt()));
                await _refresh();
                _dragSeek[side] = null;
              },
            ),
          )),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              Text(_fmt(Duration(milliseconds: pos.toInt())), style: TextStyle(color: _sub, fontSize: 11)),
              const Spacer(),
              Text(_fmt(s.duration), style: TextStyle(color: _sub, fontSize: 11)),
            ]),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(
              tooltip: 'Shuffle',
              icon: Icon(Icons.shuffle_rounded, color: s.shuffle ? color : _sub),
              onPressed: () async {
                await _duo.setShuffle(side, !s.shuffle);
                await _refresh();
              },
            ),
            IconButton(
              tooltip: 'Previous',
              icon: Icon(Icons.skip_previous_rounded, color: _text, size: 30),
              onPressed: () async {
                await _duo.previous(side);
                await _refresh();
              },
            ),
            Semantics(
              button: true,
              excludeSemantics: true,
              label: s.playing ? 'Pause' : 'Play',
              onTap: () => _toggleSide(side),
              child: PressScale(
                onTap: () => _toggleSide(side),
                haptic: true,
                pressedScale: 0.9,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: _PlayPauseIcon(playing: s.playing, size: 30),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Next',
              icon: Icon(Icons.skip_next_rounded, color: _text, size: 30),
              onPressed: () async {
                await _duo.next(side);
                await _refresh();
              },
            ),
            IconButton(
              tooltip: 'Repeat',
              icon: Icon(s.repeat == 'one' ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                  color: s.repeat == 'off' ? _sub : color),
              onPressed: () async {
                final next = s.repeat == 'off' ? 'all' : (s.repeat == 'all' ? 'one' : 'off');
                await _duo.setRepeat(side, next);
                await _refresh();
              },
            ),
          ]),
          Row(children: [
            Icon(Icons.volume_down_rounded, color: _sub, size: 20),
            Expanded(
              child: Semantics(label: 'Volume', child: Slider(
                value: _duo.volumes[side] ?? 1.0,
                activeColor: color,
                inactiveColor: color.withOpacity(0.2),
                onChanged: (v) {
                  setState(() {});
                  _duo.setVolume(side, v);
                },
              )),
            ),
            Icon(Icons.volume_up_rounded, color: _sub, size: 20),
          ]),
        ],
      ]),
    );
  }

  Widget _buildMasterControls() {
    final playing = _state.anyPlaying;
    return Row(children: [
      Expanded(
        child: PressScale(
          onTap: _playBoth,
          haptic: true,
          child: Container(
            height: 52,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [kDuoLeftColor, kDuoRightColor]),
              borderRadius: BorderRadius.circular(26),
              boxShadow: [BoxShadow(color: kDuoLeftColor.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              _PlayPauseIcon(playing: playing, size: 28),
              const SizedBox(width: 6),
              AnimatedSwitcher(
                duration: Motion.of(context, Motion.fast),
                transitionBuilder: (c, a) => FadeTransition(opacity: a, child: c),
                child: Text(playing ? 'Pause both' : 'Play both',
                    key: ValueKey(playing),
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              ),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Material(
        color: _card,
        shape: const CircleBorder(),
        elevation: 2,
        child: IconButton(
          tooltip: 'Swap ears',
          iconSize: 26,
          padding: const EdgeInsets.all(12),
          icon: Icon(Icons.swap_vert_rounded, color: _text),
          onPressed: _state.anyLoaded
              ? () async {
                  await _duo.swapSides();
                  await _refresh();
                  _snack('Swapped — the songs changed ears.');
                }
              : null,
        ),
      ),
    ]);
  }

  Widget _buildMixCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(color: _card, borderRadius: BorderRadius.circular(22)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Balance', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
        Text('Make one ear quieter without touching the other.', style: TextStyle(color: _sub, fontSize: 12)),
        Row(children: [
          const Text('L', style: TextStyle(color: kDuoLeftColor, fontWeight: FontWeight.w900)),
          Expanded(
            child: Semantics(label: 'Balance', child: Slider(
              value: _duo.balance,
              min: -1,
              max: 1,
              divisions: 20,
              activeColor: _duo.balance <= 0 ? kDuoLeftColor : kDuoRightColor,
              onChanged: (v) {
                if (v != _duo.balance) HapticFeedback.selectionClick();
                setState(() {});
                _duo.setBalance(v);
              },
              onChangeEnd: (v) {
                // Snap back to centre when released close to it.
                if (v.abs() < 0.08) {
                  setState(() {});
                  _duo.setBalance(0);
                }
              },
            )),
          ),
          const Text('R', style: TextStyle(color: kDuoRightColor, fontWeight: FontWeight.w900)),
        ]),
        const Divider(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _state.bothEars,
          activeColor: kDuoRightColor,
          title: Text('Both songs in both ears', style: TextStyle(color: _text, fontWeight: FontWeight.w600)),
          subtitle: Text('Listening alone? Hear both songs mixed together.', style: TextStyle(color: _sub, fontSize: 12)),
          onChanged: (v) async {
            await _duo.setBothEars(v);
            await _refresh();
          },
        ),
      ]),
    );
  }

  void _showHelp() {
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('How Duo Mode works', style: TextStyle(color: _text, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 14),
          for (final line in const [
            '1. Plug in earphones or connect Bluetooth earbuds.',
            '2. Choose a song for the LEFT ear and another for the RIGHT ear.',
            '3. Give one earbud to your partner and press Play both.',
            'Each ear has its own queue, controls and volume. Use Swap to switch ears, Balance to even out loudness.',
            'Playback keeps going with the screen off. Control each ear from the notification.',
            'Hearing both songs in both ears? Turn off "Mono audio" in your phone\'s Accessibility settings.',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(line, style: TextStyle(color: _sub, height: 1.4)),
            ),
        ]),
      ),
    );
  }
}

/// Searchable library picker used by each ear's "choose song".
class _SongPickerSheet extends StatefulWidget {
  final List<File> files;
  final DuoSide side;
  final bool isDark;
  final String Function(File) resolveTitle;
  final String? Function(File) resolveArtist;
  final String? currentPath;
  final String? otherPath;

  const _SongPickerSheet({
    required this.files,
    required this.side,
    required this.isDark,
    required this.resolveTitle,
    required this.resolveArtist,
    required this.currentPath,
    required this.otherPath,
  });

  @override
  State<_SongPickerSheet> createState() => _SongPickerSheetState();
}

class _SongPickerSheetState extends State<_SongPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final color = widget.side == DuoSide.left ? kDuoLeftColor : kDuoRightColor;
    final text = widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
    final sub = widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);
    final q = _query.toLowerCase();
    final entries = <int>[];
    for (var i = 0; i < widget.files.length; i++) {
      if (q.isEmpty) {
        entries.add(i);
        continue;
      }
      final f = widget.files[i];
      final hay = '${widget.resolveTitle(f)} ${widget.resolveArtist(f) ?? ''} ${p.basename(f.path)}'.toLowerCase();
      if (hay.contains(q)) entries.add(i);
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(children: [
        const SizedBox(height: 10),
        Container(width: 40, height: 4, decoration: BoxDecoration(color: sub.withOpacity(0.4), borderRadius: BorderRadius.circular(2))),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
          child: Row(children: [
            Icon(Icons.headphones_rounded, color: color),
            const SizedBox(width: 8),
            Text(widget.side == DuoSide.left ? 'Song for the LEFT ear' : 'Song for the RIGHT ear',
                style: TextStyle(color: text, fontSize: 17, fontWeight: FontWeight.bold)),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            autofocus: false,
            style: TextStyle(color: text),
            decoration: InputDecoration(
              hintText: 'Search songs or artists',
              hintStyle: TextStyle(color: sub),
              prefixIcon: Icon(Icons.search, color: sub),
              filled: true,
              fillColor: color.withOpacity(0.08),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: entries.isEmpty
              ? Center(child: Text('No matching songs', style: TextStyle(color: sub)))
              : ListView.builder(
                  controller: controller,
                  itemCount: entries.length,
                  itemBuilder: (_, i) {
                    final idx = entries[i];
                    final f = widget.files[idx];
                    final isCurrent = f.path == widget.currentPath;
                    final inOtherEar = f.path == widget.otherPath;
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: color.withOpacity(isCurrent ? 1 : 0.12),
                        child: Icon(isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                            color: isCurrent ? Colors.white : color, size: 20),
                      ),
                      title: Text(widget.resolveTitle(f),
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: text, fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal)),
                      subtitle: Text(
                        inOtherEar ? 'Playing in the other ear' : (widget.resolveArtist(f) ?? 'Unknown artist'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: inOtherEar ? Colors.orange : sub, fontSize: 12),
                      ),
                      onTap: () => Navigator.pop(context, idx),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

/// Play <-> pause icon that morphs (scale + rotate) instead of swapping.
class _PlayPauseIcon extends StatelessWidget {
  final bool playing;
  final double size;
  const _PlayPauseIcon({required this.playing, required this.size});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.of(context, Motion.fast),
      switchInCurve: Motion.spring,
      transitionBuilder: (c, a) => ScaleTransition(
        scale: a,
        child: RotationTransition(turns: Tween(begin: 0.85, end: 1.0).animate(a), child: c),
      ),
      child: Icon(
        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
        key: ValueKey(playing),
        color: Colors.white,
        size: size,
      ),
    );
  }
}
