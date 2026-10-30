// lib/smart_mix_page.dart
//
// UI for Smart Mix — pick a mood, generate a ranked playlist from the local
// library via SmartMixService, then play it. Mirrors the app's existing
// bottom-sheet/page conventions (GenresPage, audio_conversion_sheet.dart).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'audio_analysis_service.dart';
import 'smart_mix_service.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';
import 'player_screen.dart' show PlaylistContext;
import 'songs_page.dart' show GlobalMiniPlayer;
import 'library/title_cleaner.dart';
import 'library/library_motion.dart';
import 'motion/motion_kit.dart';

Color get _kPrimary => AppPalette.accent;

class SmartMixPage extends StatefulWidget {
  final List<File> audioFiles;
  final void Function(dynamic playlistPayload) onPlay;

  /// For the now-playing highlight (play/pause state) and the row's
  /// pause/resume toggle.
  final AudioPlayer? audioPlayer;
  final VoidCallback? onTogglePlayPause;

  const SmartMixPage({super.key, required this.audioFiles, required this.onPlay, this.audioPlayer, this.onTogglePlayPause});

  @override
  State<SmartMixPage> createState() => _SmartMixPageState();
}

class _SmartMixPageState extends State<SmartMixPage> {
  MoodBucket _selectedMood = MoodBucket.upbeat;
  bool _generating = false;
  double _progress = 0;
  List<String>? _resultPaths;
  Map<String, AudioAnalysis> _resultAnalyses = {};

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _progress = 0;
      _resultPaths = null;
    });

    try {
      final result = await SmartMixService.instance.generate(
        libraryPaths: widget.audioFiles.map((f) => f.path).toList(),
        targetMood: _selectedMood,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? done / total : 0);
        },
      );

      if (!mounted) return;
      setState(() {
        _resultPaths = result.paths;
        _generating = false;
      });

      if (result.paths.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not build a mix — try again once you have more songs analyzed.'),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _generating = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Smart Mix failed: $e')));
    }
  }

  Future<void> _refreshAnalysesForDisplay() async {
    if (_resultPaths == null) return;
    final map = <String, AudioAnalysis>{};
    for (final path in _resultPaths!) {
      final cached = await AudioAnalysisService.instance.cached(path);
      if (cached != null) map[path] = cached;
    }
    if (mounted) setState(() => _resultAnalyses = map);
  }

  void _playAll() {
    final paths = _resultPaths;
    if (paths == null || paths.isEmpty) return;
    widget.onPlay({'paths': paths, 'startIndex': 0});
  }

  void _playFrom(int index) {
    final paths = _resultPaths;
    if (paths == null) return;
    widget.onPlay({'paths': paths, 'startIndex': index});
  }

  String _titleFor(String path) => TitleCleaner.title(null, path: path);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
    final appBarColor = isDark ? AppPalette.darkBackground : Colors.white;
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;
    final iconColor = isDark ? Colors.white : Colors.black;
    final primaryText = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final secondaryText = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF8C8A9D);

    if (_resultPaths != null && _resultAnalyses.isEmpty) {
      // Fire-and-forget: fills in BPM/mood subtitles once cached results
      // are available, without blocking the results list from showing.
      _refreshAnalysesForDisplay();
    }

    return Scaffold(
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      backgroundColor: bg,
      appBar: AppBar(
        centerTitle: true,
        title: Text('Smart Mix', style: TextStyle(color: iconColor)),
        backgroundColor: appBarColor,
        elevation: 0,
        iconTheme: IconThemeData(color: iconColor),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.mood_rounded, color: _kPrimary, size: 20),
                    const SizedBox(width: 8),
                    Text('Pick a mood', style: TextStyle(color: primaryText, fontWeight: FontWeight.w800, fontSize: 17)),
                  ]),
                  const SizedBox(height: 4),
                  Text('Songs are ranked by tempo and energy.', style: TextStyle(color: secondaryText, fontSize: 12.5)),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: MoodBucket.values.map((mood) {
                      final selected = mood == _selectedMood;
                      return ChoiceChip(
                        label: Text(mood.label),
                        selected: selected,
                        showCheckmark: false,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        onSelected: _generating ? null : (_) => setState(() => _selectedMood = mood),
                        selectedColor: _kPrimary,
                        backgroundColor: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFF1F2F8),
                        side: BorderSide.none,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                        labelStyle: TextStyle(color: selected ? Colors.white : primaryText, fontWeight: FontWeight.w600),
                      );
                    }).toList(),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                decoration: BoxDecoration(
                  gradient: _generating
                      ? null
                      : AppPalette.gradient,
                  color: _generating ? Colors.grey.withOpacity(0.4) : null,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                    ),
                    icon: _generating
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.auto_awesome, color: Colors.white),
                    label: Text(
                      _generating ? 'Analyzing… ${(_progress * 100).toStringAsFixed(0)}%' : 'Generate Mix',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                    onPressed: _generating ? null : _generate,
                  ),
                ),
              ),
            ),
            if (_resultPaths != null && _resultPaths!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text('${_resultPaths!.length} songs', style: TextStyle(color: secondaryText)),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _playAll,
                      icon: Icon(Icons.play_arrow, color: _kPrimary),
                      label: Text('Play All', style: TextStyle(color: _kPrimary)),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _resultPaths == null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 40),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 88,
                            height: 88,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: _kPrimary.withOpacity(0.12)),
                            child: Icon(Icons.auto_awesome_rounded, size: 40, color: _kPrimary),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Pick a mood and tap Generate Mix to build a playlist from your library.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: secondaryText, height: 1.35),
                          ),
                        ]),
                      ),
                    )
                  : ValueListenableBuilder<String?>(
                      // Highlight the song that's playing, like the other
                      // song lists — it used to look identical to the rest.
                      valueListenable: PlaylistContext.currentPathNotifier,
                      builder: (context, currentPath, _) => StreamBuilder<bool>(
                        stream: widget.audioPlayer?.playingStream,
                        initialData: widget.audioPlayer?.playing ?? false,
                        builder: (context, playingSnap) {
                          final playing = playingSnap.data ?? false;
                          return ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            itemCount: _resultPaths!.length,
                            itemBuilder: (context, index) {
                              final path = _resultPaths![index];
                              final analysis = _resultAnalyses[path];
                              final info = analysis != null && analysis.bpm > 0
                                  ? '${analysis.bpm.round()} BPM · ${analysis.mood.label}'
                                  : analysis?.mood.label ?? '';
                              final isCurrent = path == currentPath;
                              final subtitle = isCurrent
                                  ? [playing ? 'Now playing' : 'Paused', if (info.isNotEmpty) info].join(' · ')
                                  : info;
                              return FadeSlideIn(
                                index: index < 10 ? index : 0,
                                child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 2),
                                decoration: BoxDecoration(
                                  color: isCurrent ? _kPrimary.withOpacity(0.12) : Colors.transparent,
                                  borderRadius: BorderRadius.circular(18),
                                  border: isCurrent ? Border.all(color: _kPrimary.withOpacity(0.6)) : null,
                                ),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  leading: CircleAvatar(
                                    backgroundColor: isCurrent ? _kPrimary : _kPrimary.withOpacity(0.12),
                                    child: isCurrent && playing
                                        ? const EqualizerBars(color: Colors.white, playing: true, size: 18)
                                        : Icon(Icons.music_note, color: isCurrent ? Colors.white : _kPrimary),
                                  ),
                                  title: Text(
                                    _titleFor(path),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: isCurrent ? _kPrimary : primaryText,
                                      fontWeight: isCurrent ? FontWeight.w700 : FontWeight.normal,
                                    ),
                                  ),
                                  subtitle: subtitle.isNotEmpty
                                      ? Text(subtitle,
                                          style: TextStyle(color: isCurrent ? _kPrimary.withOpacity(0.85) : secondaryText, fontSize: 12))
                                      : null,
                                  trailing: Icon(
                                    isCurrent && playing ? Icons.pause_rounded : Icons.play_arrow,
                                    color: isCurrent ? _kPrimary : primaryText,
                                  ),
                                  // Tapping the playing song pauses/resumes it instead of restarting.
                                  onTap: () => isCurrent && widget.onTogglePlayPause != null
                                      ? widget.onTogglePlayPause!()
                                      : _playFrom(index),
                                ),
                              ));
                            },
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
