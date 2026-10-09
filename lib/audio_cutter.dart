// lib/audio_cutter.dart
//
// Audio Cutter screen: pick a start/end range from the song's duration and
// save that segment as a new file in Downloads. Preview uses a small
// screen-local AudioPlayer rather than the app's shared/notification-backed
// player: that player's title/artwork and the mini/full-screen player both
// read from the *songs page's* own state (current index, PlaylistContext),
// not from the player's live source — repointing the shared instance at the
// file being edited here would desync the mini player's displayed track
// from what it's actually showing a position/duration for. This local
// player is created and disposed with the page and is never registered
// with audio_service, so it doesn't add a second background player — the
// final cut file is played back through the normal shared player like any
// other library song (see songs_page.dart's _handleCutSong).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;

import 'audio_cutter_service.dart';
import 'audio_waveform_view.dart';
import 'waveform_service.dart';
import 'banner_ad_widget2.dart';
import 'app_palette.dart';

Color get _kPrimary => AppPalette.accent;

class AudioCutterPage extends StatefulWidget {
  final File song;
  final String title;
  final bool isDark;
  final Duration? knownDuration;
  final void Function(CutRecord record) onCutSaved;

  /// Best-effort: paused once on entry so the screen-local preview player
  /// below doesn't play on top of whatever the main library player was
  /// already doing. Never touched again after that.
  final AudioPlayer? mainPlayerToPause;

  const AudioCutterPage({
    super.key,
    required this.song,
    required this.title,
    required this.isDark,
    required this.onCutSaved,
    this.knownDuration,
    this.mainPlayerToPause,
  });

  @override
  State<AudioCutterPage> createState() => _AudioCutterPageState();
}

class _AudioCutterPageState extends State<AudioCutterPage> {
  final AudioPlayer _player = AudioPlayer();
  final ScrollController _scrollController = ScrollController();

  Duration _total = Duration.zero;
  Duration _start = Duration.zero;
  Duration _end = Duration.zero;
  Duration _previewPosition = Duration.zero;
  bool _loading = true;
  bool _playing = false;
  bool _isCutting = false;
  String? _loadError;

  List<double>? _waveform;
  bool _waveformLoading = false;
  String? _waveformNote;

  static const double _minZoom = 1.0;
  static const double _maxZoom = 5.0;
  double _zoomLevel = 1.0;

  // Pinch-to-zoom tracking: raw pointer positions (not a GestureDetector
  // scale recognizer) so a single finger dragging a Start/End handle is
  // never contended for by a zoom gesture recognizer — this only reacts
  // once a second pointer actually touches down. The viewport width is
  // cached from the waveform's own LayoutBuilder each build so the pinch
  // math (converting the two-finger distance into a zoom level and keeping
  // the pinch's focal point visually still) uses the exact same width the
  // waveform is laid out with.
  final Map<int, Offset> _pinchPointers = {};
  double? _pinchStartDistance;
  double? _pinchStartZoom;
  double? _pinchAnchorContentX;
  double? _pinchAnchorLocalX;
  double _viewportWidth = 0;

  final ValueNotifier<double> _progressNotifier = ValueNotifier<double>(0.0);

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PlayerState>? _stateSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  Future<void> _init() async {
    try {
      try {
        await widget.mainPlayerToPause?.pause();
      } catch (_) {}

      await _player.setAudioSource(AudioSource.uri(Uri.file(widget.song.path)));

      var total = _player.duration ?? widget.knownDuration ?? Duration.zero;
      if (total <= Duration.zero) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        total = _player.duration ?? Duration.zero;
      }
      if (total <= Duration.zero) total = widget.knownDuration ?? const Duration(seconds: 1);

      if (!mounted) return;
      setState(() {
        _total = total;
        _start = Duration.zero;
        _end = total;
        _loading = false;
      });

      _posSub = _player.positionStream.listen((pos) {
        if (mounted) setState(() => _previewPosition = pos);
        if (_playing && pos >= _end) {
          _player.pause();
          _player.seek(_start);
          if (mounted) setState(() => _playing = false);
        }
      });
      _stateSub = _player.playerStateStream.listen((ps) {
        if (mounted) setState(() => _playing = ps.playing);
      });

      unawaited(_loadWaveform());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'Failed to load audio: $e';
      });
    }
  }

  /// Waveform is best-effort: a decode/generation failure never blocks
  /// trimming — the page falls back to a flat placeholder envelope so the
  /// draggable Start/End markers still work using Duration values from the
  /// player, independent of whether a real waveform could be rendered.
  Future<void> _loadWaveform() async {
    if (!mounted) return;
    setState(() {
      _waveformLoading = true;
      _waveformNote = null;
    });
    try {
      final bars = await WaveformService.instance.generate(widget.song.path);
      if (!mounted) return;
      setState(() {
        _waveform = bars;
        _waveformLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _waveform = List<double>.filled(kWaveformBarCount, 0.12);
        _waveformLoading = false;
        _waveformNote = 'Waveform preview unavailable — trimming still works.';
      });
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _stateSub?.cancel();
    _player.stop();
    _player.dispose();
    _scrollController.dispose();
    _progressNotifier.dispose();
    unawaited(WaveformService.instance.cancelActive());
    super.dispose();
  }

  bool get _rangeValid =>
      _start >= Duration.zero && _end > _start && (_total == Duration.zero || _end <= _total);

  String _fmt(Duration d) {
    if (d.isNegative) d = Duration.zero;
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '${two(h)}:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  Future<void> _togglePreview() async {
    if (_isCutting) return;
    try {
      if (_playing) {
        await _player.pause();
        return;
      }
      final seekPos = (_player.position < _start || _player.position >= _end) ? _start : null;
      if (seekPos != null) await _player.seek(seekPos);
      await _player.play();
    } catch (e) {
      _showSnack('Playback error: $e', isError: true);
    }
  }

  void _nudge({required bool isStart, required int seconds}) {
    setState(() {
      if (isStart) {
        var next = _start + Duration(seconds: seconds);
        if (next < Duration.zero) next = Duration.zero;
        if (next >= _end) next = _end - const Duration(milliseconds: 100);
        _start = next < Duration.zero ? Duration.zero : next;
      } else {
        var next = _end + Duration(seconds: seconds);
        if (next > _total) next = _total;
        if (next <= _start) next = _start + const Duration(milliseconds: 100);
        _end = next;
      }
    });
  }

  void _onPinchPointerDown(PointerDownEvent event) {
    _pinchPointers[event.pointer] = event.localPosition;
    if (_pinchPointers.length == 2) _beginPinch();
  }

  void _onPinchPointerMove(PointerMoveEvent event) {
    if (!_pinchPointers.containsKey(event.pointer)) return;
    _pinchPointers[event.pointer] = event.localPosition;
    if (_pinchPointers.length == 2) _updatePinch();
  }

  void _onPinchPointerUp(PointerEvent event) {
    _pinchPointers.remove(event.pointer);
    if (_pinchPointers.length < 2) {
      _pinchStartDistance = null;
      _pinchStartZoom = null;
    }
  }

  void _beginPinch() {
    final pts = _pinchPointers.values.toList();
    final distance = (pts[0] - pts[1]).distance;
    if (distance <= 0) return;
    _pinchStartDistance = distance;
    _pinchStartZoom = _zoomLevel;
    final focalLocalX = (pts[0].dx + pts[1].dx) / 2;
    _pinchAnchorLocalX = focalLocalX;
    _pinchAnchorContentX = (_scrollController.hasClients ? _scrollController.offset : 0.0) + focalLocalX;
  }

  void _updatePinch() {
    final startDistance = _pinchStartDistance;
    final startZoom = _pinchStartZoom;
    final anchorContentX = _pinchAnchorContentX;
    final anchorLocalX = _pinchAnchorLocalX;
    if (startDistance == null || startZoom == null || anchorContentX == null || anchorLocalX == null) return;
    if (_viewportWidth <= 0) return;

    final pts = _pinchPointers.values.toList();
    final currentDistance = (pts[0] - pts[1]).distance;
    if (currentDistance <= 0) return;

    final scale = currentDistance / startDistance;
    final newZoom = (startZoom * scale).clamp(_minZoom, _maxZoom);
    if ((newZoom - _zoomLevel).abs() < 0.01) return;

    final fraction = anchorContentX / (_viewportWidth * _zoomLevel);
    setState(() => _zoomLevel = newZoom);

    final newContentX = fraction * _viewportWidth * newZoom;
    final targetOffset = newContentX - anchorLocalX;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final clamped = targetOffset.clamp(0.0, _scrollController.position.maxScrollExtent);
      _scrollController.jumpTo(clamped);
    });
  }

  void _showSnack(String message, {bool isError = false, Color? color}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color ?? (isError ? Colors.red : Colors.green),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _cut() async {
    if (_isCutting || !_rangeValid) return;

    setState(() => _isCutting = true);
    _progressNotifier.value = 0.0;
    try {
      await _player.pause();
    } catch (_) {}

    try {
      final record = await AudioCutterService.instance.cut(
        originalPath: widget.song.path,
        start: _start,
        end: _end,
        baseTitle: widget.title,
        onProgress: (v) => _progressNotifier.value = v,
      );
      if (!mounted) return;
      setState(() => _isCutting = false);
      _showSnack('Cut audio saved to Downloads');
      widget.onCutSaved(record);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isCutting = false);
      final isCancel = e is CutException && e.type == CutErrorType.cancelled;
      final message = e is CutException ? e.message : 'Cutting failed: $e';
      _showSnack(isCancel ? 'Cutting cancelled' : message, color: isCancel ? Colors.orange : Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final bg = isDark ? AppPalette.darkBackground : Colors.white;
    final cardBg = isDark ? AppPalette.darkCard : const Color(0xFFF5F5F5);
    final textColor = isDark ? Colors.white : Colors.black87;
    final subColor = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Audio Cutter'),
        backgroundColor: bg,
        foregroundColor: textColor,
        elevation: 0,
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: _kPrimary))
          : _loadError != null
          ? Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_loadError!, style: TextStyle(color: textColor), textAlign: TextAlign.center),
        ),
      )
          : SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                p.basenameWithoutExtension(widget.song.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: textColor, fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text('Total duration: ${_fmt(_total)}', style: TextStyle(color: subColor, fontSize: 13)),
              const SizedBox(height: 24),

              // Using Expanded here allows the waveform container to occupy all available
              // empty space instead of being constrained to a fixed height.
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(color: cardBg, borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          _timeStepper(
                            label: 'Start',
                            value: _start,
                            textColor: textColor,
                            subColor: subColor,
                            onMinus: () => _nudge(isStart: true, seconds: -1),
                            onPlus: () => _nudge(isStart: true, seconds: 1),
                          ),
                          _timeStepper(
                            label: 'End',
                            value: _end,
                            textColor: textColor,
                            subColor: subColor,
                            onMinus: () => _nudge(isStart: false, seconds: -1),
                            onPlus: () => _nudge(isStart: false, seconds: 1),
                          ),
                        ],
                      ),

                      // Zoom Controls
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Text('Zoom (pinch to adjust): ', style: TextStyle(color: subColor, fontSize: 12)),
                          InkWell(
                            onTap: _zoomLevel > _minZoom
                                ? () => setState(() => _zoomLevel = (_zoomLevel - 0.5).clamp(_minZoom, _maxZoom))
                                : null,
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                  Icons.zoom_out,
                                  color: _zoomLevel > _minZoom ? textColor : subColor.withOpacity(0.3),
                                  size: 22
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 48,
                            child: Text(
                              '${(_zoomLevel * 100).toInt()}%',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: textColor, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ),
                          InkWell(
                            onTap: _zoomLevel < _maxZoom
                                ? () => setState(() => _zoomLevel = (_zoomLevel + 0.5).clamp(_minZoom, _maxZoom))
                                : null,
                            borderRadius: BorderRadius.circular(20),
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: Icon(
                                  Icons.zoom_in,
                                  color: _zoomLevel < _maxZoom ? textColor : subColor.withOpacity(0.3),
                                  size: 22
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 8),
                      // Expand the waveform trimmer to fill the remaining vertical space inside the card
                      Expanded(
                        child: (_waveformLoading || _waveform == null)
                            ? Center(
                          child: CircularProgressIndicator(color: _kPrimary, strokeWidth: 2),
                        )
                            : LayoutBuilder(
                            builder: (context, constraints) {
                              final bool isZoomed = _zoomLevel > _minZoom;
                              // Determine the total width based on the zoom level
                              final double zoomedWidth = constraints.maxWidth * _zoomLevel;
                              // Cached for the pinch handlers below, which run
                              // outside this builder's scope (pointer events
                              // don't carry layout constraints).
                              _viewportWidth = constraints.maxWidth;

                              return Listener(
                                // A plain Listener only *observes* pointer
                                // events — it never enters the gesture arena,
                                // so it can't steal a single-finger drag away
                                // from a Start/End handle or the scroll view.
                                // Pinch math only ever runs once a second
                                // pointer is actually down.
                                onPointerDown: _onPinchPointerDown,
                                onPointerMove: _onPinchPointerMove,
                                onPointerUp: _onPinchPointerUp,
                                onPointerCancel: _onPinchPointerUp,
                                child: Scrollbar(
                                  controller: _scrollController,
                                  thumbVisibility: isZoomed,
                                  trackVisibility: isZoomed,
                                  interactive: true,
                                  child: SingleChildScrollView(
                                    controller: _scrollController,
                                    scrollDirection: Axis.horizontal,
                                    physics: const ClampingScrollPhysics(),
                                    child: SizedBox(
                                      width: zoomedWidth,
                                      // Pass the maximum available height so the trimmer can expand vertically
                                      height: constraints.maxHeight,
                                      child: Padding(
                                        // Add bottom padding so the scrollbar doesn't cover the waveform UI
                                        padding: const EdgeInsets.only(bottom: 16.0),
                                        child: AudioWaveformTrimmer(
                                          amplitudes: _waveform!,
                                          duration: _total,
                                          start: _start,
                                          end: _end,
                                          enabled: !_isCutting,
                                          playhead: _playing ? _previewPosition : null,
                                          activeColor: _kPrimary,
                                          inactiveColor: isDark ? Colors.white24 : Colors.grey.shade300,
                                          markerColor: _kPrimary,
                                          onStartChanged: (d) => setState(() => _start = d),
                                          onEndChanged: (d) => setState(() => _end = d),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }
                        ),
                      ),
                      if (_waveformNote != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(_waveformNote!, style: TextStyle(color: subColor, fontSize: 11)),
                        ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              Center(
                child: IconButton(
                  iconSize: 56,
                  color: _kPrimary,
                  icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill),
                  onPressed: _isCutting ? null : _togglePreview,
                  tooltip: 'Preview selection',
                ),
              ),
              if (!_rangeValid)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Center(
                    child: Text(
                      'End time must be greater than start time and within the song duration.',
                      style: TextStyle(color: Colors.red.shade400, fontSize: 12),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),

              // Spacer removed as the Waveform is now Expanded and pushing elements to the bottom naturally.
              const SizedBox(height: 16),

              Center(
                child: Text(
                  'Selected clip: ${_fmt(_end - _start)}',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (_isCutting)
                ValueListenableBuilder<double>(
                  valueListenable: _progressNotifier,
                  builder: (context, value, _) => Column(
                    children: [
                      LinearProgressIndicator(
                        value: value > 0 ? value : null,
                        color: _kPrimary,
                        backgroundColor: Colors.grey.withOpacity(0.3),
                      ),
                      const SizedBox(height: 8),
                      Text('Cutting… ${(value * 100).toStringAsFixed(0)}%',
                          style: TextStyle(color: textColor)),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: (_isCutting || !_rangeValid) ? null : _cut,
                  icon: _isCutting
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                      : const Icon(Icons.content_cut, color: Colors.white),
                  label: Text(_isCutting ? 'Cutting…' : 'Cut & Save to Downloads'),
                  style: ElevatedButton.styleFrom(backgroundColor: _kPrimary, foregroundColor: Colors.white),
                ),
              ),
              const BannerAdWidget2(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timeStepper({
    required String label,
    required Duration value,
    required Color textColor,
    required Color subColor,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
  }) {
    return Column(
      children: [
        Text(label, style: TextStyle(color: subColor, fontSize: 12)),
        const SizedBox(height: 4),
        Row(
          children: [
            InkWell(
              onTap: _isCutting ? null : onMinus,
              child: Icon(Icons.remove_circle_outline, color: subColor, size: 20),
            ),
            const SizedBox(width: 8),
            Text(_fmt(value), style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            InkWell(
              onTap: _isCutting ? null : onPlus,
              child: Icon(Icons.add_circle_outline, color: subColor, size: 20),
            ),
          ],
        ),
      ],
    );
  }
}