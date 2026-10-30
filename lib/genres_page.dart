// lib/genres_page.dart
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'package:music/player_screen.dart';
import 'audio_analysis_service.dart';
import 'list_page.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'banner_ad_widget3.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';
import 'library/title_cleaner.dart';
import 'library/library_motion.dart';
import 'motion/motion_kit.dart';
import 'library/queue_menu.dart';

/// GenresPage with grid layout and system-aware dark mode
class GenresPage extends StatefulWidget {
  final List<File> audioFiles;
  final Map<String, dynamic> metadataCache;

  /// Accepts either:
  ///  - an int (index into global list)
  ///  - a Map with keys: 'paths' -> List<String> and optional 'startIndex' -> int
  final void Function(dynamic indexOrPlaylist) onPlay;
  final int? currentPlayingIndex;

  const GenresPage({
    super.key,
    required this.audioFiles,
    required this.metadataCache,
    required this.onPlay,
    this.currentPlayingIndex,
  });

  @override
  State<GenresPage> createState() => _GenresPageState();
}

class _GenresPageState extends State<GenresPage> {
  final Map<String, Map<String, dynamic>> _mergedMeta = {};
  final Map<String, bool> _loadingMetaFor = {};
  final int _concurrentReads = 6;

  // path -> DSP-heuristic mood bucket, used only as a genre-grouping
  // fallback for songs with no genre/album/artist ID3 metadata at all (see
  // _loadAnalysisFallbacks / _runSmartTagging below).
  final Map<String, String> _analysisGenreFallback = {};
  bool _smartTagging = false;

  // Colors that remain constant regardless of theme
  final Color _accentColor = AppPalette.accent;

  @override
  void initState() {
    super.initState();

    // Copy incoming metadata into merged map
    for (final kv in widget.metadataCache.entries) {
      if (kv.value is Map<String, dynamic>) {
        _mergedMeta[kv.key] = Map<String, dynamic>.from(kv.value);
      } else {
        _mergedMeta[kv.key] = {'raw': kv.value};
      }
    }

    _enrichMissingMetadata(); // kick off metadata reads
    unawaited(_loadAnalysisFallbacks());
  }

  @override
  void didUpdateWidget(covariant GenresPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    // If parent provided new metadata keys, merge them
    for (final kv in widget.metadataCache.entries) {
      if (!_mergedMeta.containsKey(kv.key)) {
        if (kv.value is Map<String, dynamic>) {
          _mergedMeta[kv.key] = Map<String, dynamic>.from(kv.value);
        } else {
          _mergedMeta[kv.key] = {'raw': kv.value};
        }
      }
    }

    // If audio files changed, re-run metadata enrichment
    if (!listEquals(
      oldWidget.audioFiles.map((f) => f.path).toList(),
      widget.audioFiles.map((f) => f.path).toList(),
    )) {
      _enrichMissingMetadata();
      unawaited(_loadAnalysisFallbacks());
    }
  }

  Future<void> _markRecentlyPlayed(String path) async {
    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }
  }

  // ---------- Metadata handling ----------
  Future<void> _enrichMissingMetadata() async {
    final queue = <File>[];

    for (final file in widget.audioFiles) {
      final meta = _mergedMeta[file.path];
      final hasGenre = _hasNonEmptyMetaField(meta, 'genre');
      final hasCover = _hasCover(meta);
      if (!hasGenre || !hasCover) queue.add(file);
    }

    if (queue.isEmpty) return;

    final sem = _AsyncSemaphore(_concurrentReads);

    await Future.wait(queue.map((file) async {
      if (_loadingMetaFor[file.path] == true) return;
      _loadingMetaFor[file.path] = true;
      await sem.withPerm(() async {
        try {
          final am = await readMetadata(file, getImage: true);
          if (am == null) throw Exception('No metadata returned');

          final Map<String, dynamic> newMeta = {};
          if (am.title != null) newMeta['title'] = am.title;
          if (am.artist != null) newMeta['artist'] = am.artist;
          if (am.album != null) newMeta['album'] = am.album;
          if (am.genres != null) newMeta['genre'] = am.genres;
          if (am.language != null) newMeta['language'] = am.language;

          if (am.pictures != null && am.pictures!.isNotEmpty) {
            final pic = am.pictures!.first;
            dynamic coverBytes;
            try {
              // defensive extraction
              coverBytes = (pic as dynamic).bytes ?? (pic as dynamic).buffer ?? (pic as dynamic).image ?? (pic as dynamic).pictureData ?? (pic as dynamic).data;
            } catch (_) {
              coverBytes = null;
            }

            if (coverBytes is Uint8List) {
              newMeta['cover'] = coverBytes;
            } else if (coverBytes is List<int>) {
              newMeta['cover'] = Uint8List.fromList(coverBytes);
            }
          }

          final existing = _mergedMeta[file.path] ?? {};
          existing.addAll(newMeta);
          _mergedMeta[file.path] = existing;

          if (mounted) setState(() {});
        } catch (e) {
          debugPrint('Failed to read metadata for ${file.path}: $e');
        } finally {
          _loadingMetaFor.remove(file.path);
        }
      });
    }));
  }

  /// Files with no genre, album or artist tag at all — the only ones a
  /// mood-bucket "genre" is actually useful for, since everything else
  /// already groups by album/artist (see _buildGenreMap).
  List<File> _untaggedCandidates() {
    return widget.audioFiles.where((f) {
      final meta = _mergedMeta[f.path];
      return !_hasNonEmptyMetaField(meta, 'genre') &&
          !_hasNonEmptyMetaField(meta, 'album') &&
          !_hasNonEmptyMetaField(meta, 'artist');
    }).toList();
  }

  /// Cache-only lookup (never triggers an ffmpeg decode) — picks up mood
  /// buckets for any untagged file a previous Smart Tag run already
  /// analyzed, so re-opening this page doesn't lose the tagging.
  Future<void> _loadAnalysisFallbacks() async {
    var changed = false;
    for (final file in _untaggedCandidates()) {
      if (_analysisGenreFallback.containsKey(file.path)) continue;
      final cached = await AudioAnalysisService.instance.cached(file.path);
      if (cached != null) {
        _analysisGenreFallback[file.path] = cached.mood.label;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  /// Explicit, user-triggered DSP analysis for untagged songs — never runs
  /// automatically on scan/open, since it's real ffmpeg decode work per
  /// song (see AudioAnalysisService's own CPU/battery-cost note).
  Future<void> _runSmartTagging() async {
    final candidates = _untaggedCandidates()
        .where((f) => !_analysisGenreFallback.containsKey(f.path))
        .map((f) => f.path)
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nothing to tag — every song already has genre, album or artist info.'),
      ));
      return;
    }

    final progress = ValueNotifier<double>(0);
    setState(() => _smartTagging = true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => AlertDialog(
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (context, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Analyzing untagged songs…'),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: value > 0 ? value : null, color: _accentColor),
              const SizedBox(height: 8),
              Text('${(value * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    );

    try {
      await AudioAnalysisService.instance.analyzeAll(
        candidates,
        onProgress: (done, total) => progress.value = total > 0 ? done / total : 0,
      );
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    await _loadAnalysisFallbacks();
    if (mounted) {
      setState(() => _smartTagging = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Tagged ${candidates.length} song${candidates.length == 1 ? '' : 's'}'),
      ));
    }
  }

  bool _hasNonEmptyMetaField(Map<String, dynamic>? meta, String key) {
    if (meta == null) return false;
    final v = meta[key] ?? meta[key.toLowerCase()] ?? meta[key.toUpperCase()];
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is Iterable) return v.isNotEmpty;
    return true;
  }

  bool _hasCover(Map<String, dynamic>? meta) {
    if (meta == null) return false;
    final keys = ['cover', 'coverArt', 'albumArt', 'picture', 'image', 'artwork', 'thumbnail'];
    for (final k in keys) {
      final v = meta[k] ?? meta[k.toLowerCase()];
      if (v != null) {
        if (v is Uint8List && v.isNotEmpty) return true;
        if (v is List<int> && v.isNotEmpty) return true;
      }
    }
    return false;
  }

  dynamic _getMeta(String filePath, String property) {
    final meta = _mergedMeta[filePath] ?? widget.metadataCache[filePath];
    if (meta == null) return null;
    if (meta is Map) {
      final possible = [property, property.toLowerCase(), property.toUpperCase()];
      for (final k in possible) {
        if (meta.containsKey(k)) return meta[k];
      }
      if (property == 'genre') {
        if (meta.containsKey('genres')) return meta['genres'];
      }
      if (property == 'cover') {
        for (final k in ['cover', 'coverArt', 'albumArt', 'picture', 'image', 'artwork', 'thumbnail']) {
          if (meta.containsKey(k)) return meta[k];
        }
      }
      return null;
    } else {
      if (meta is Map && meta.containsKey('raw')) return meta['raw'];
      return null;
    }
  }

  // ---------- Normalization helpers ----------
  String _norm(String s) {
    final x = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    return x.isEmpty ? '' : x;
  }

  // Returns "Unknown" instead of "Other"
  String _normGenre(String? s) {
    final v = _norm(s ?? '');
    return (v.isEmpty || v.toLowerCase() == 'unknown') ? 'Unknown' : v;
  }

  // Defaults to "Unknown"
  List<String> _normalizeGenres(dynamic raw) {
    if (raw == null) return ['Unknown'];
    final List<String> parts = [];
    if (raw is Iterable) {
      for (final v in raw) {
        if (v != null) parts.add(v.toString());
      }
    } else {
      parts.add(raw.toString());
    }

    final Set<String> out = {};
    for (final pRaw in parts) {
      final tokens = pRaw.split(RegExp(r'[;,/|]+'));
      for (var t in tokens) {
        t = t.trim();
        if (t.isEmpty) continue;
        out.add(TitleCleaner.looksLikeSite(t) ? 'Unknown' : _normGenre(t));
      }
    }
    if (out.isEmpty) return ['Unknown'];
    return out.toList();
  }

  String _normalizePath(String path) {
    try {
      return p.normalize(path).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      return path.toLowerCase();
    }
  }

  // ---------- Grouping by Genre Only ----------
  Map<String, List<File>> _buildGenreMap() {
    final Map<String, List<File>> out = {};

    for (final file in widget.audioFiles) {
      final rawGenre = _getMeta(file.path, 'genre');

      String fallback = '';
      if (rawGenre == null) {
        final album = _getMeta(file.path, 'album');
        final artist = _getMeta(file.path, 'artist');
        if (album != null && album.toString().trim().isNotEmpty) {
          fallback = album.toString();
        } else if (artist != null && artist.toString().trim().isNotEmpty) {
          fallback = artist.toString();
        } else {
          // No genre/album/artist at all — use a Smart-Tag mood bucket
          // (from a previous explicit "Analyze untagged songs" run) instead
          // of dumping the file straight into "Unknown", if one exists.
          fallback = _analysisGenreFallback[file.path] ?? 'Unknown';
        }
      }

      final genres = (rawGenre != null) ? _normalizeGenres(rawGenre) : _normalizeGenres(fallback);

      for (final g in genres) {
        final key = g.trim().isEmpty ? 'Unknown' : g;
        out.putIfAbsent(key, () => []);
        final existingList = out[key]!;
        final npath = _normalizePath(file.path);
        final already = existingList.any((f) => _normalizePath(f.path) == npath);
        if (!already) existingList.add(file);
      }
    }

    // Sort alphabetically, but keep 'Unknown' at the end
    final sortedKeys = out.keys.toList()
      ..sort((a, b) {
        if (a == 'Unknown') return 1;
        if (b == 'Unknown') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final Map<String, List<File>> sortedOut = {};
    for (final key in sortedKeys) {
      final list = out[key]!;
      list.sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
      sortedOut[key] = list;
    }

    return sortedOut;
  }

  // ---------- UI Components ----------
  // Gradient + glyph per genre (deterministic by name).
  static const List<List<Color>> _tileGradients = [
    [Color(0xFF7C4DFF), Color(0xFFD946EF)],
    [Color(0xFFFF9A3C), Color(0xFFFF4E78)],
    [Color(0xFF22D3EE), Color(0xFF4F46E5)],
    [Color(0xFF34D399), Color(0xFF0EA5A4)],
    [Color(0xFFFFB020), Color(0xFFE5254B)],
    [Color(0xFF2DD4BF), Color(0xFF38BDF8)],
    [Color(0xFF6366F1), Color(0xFFDB2777)],
    [Color(0xFFF472B6), Color(0xFFF59E0B)],
  ];

  static List<Color> _gradientFor(String genre) {
    var h = 0;
    for (final u in genre.toLowerCase().codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    return _tileGradients[h % _tileGradients.length];
  }

  static String _glyphFor(String genre) {
    final g = genre.toLowerCase();
    bool has(List<String> k) => k.any(g.contains);
    if (has(['rock', 'metal', 'punk', 'grunge'])) return '🎸';
    if (has(['pop'])) return '🎤';
    if (has(['hip', 'rap', 'trap'])) return '🎧';
    if (has(['classical', 'orchestra', 'opera', 'piano'])) return '🎻';
    if (has(['jazz', 'blues', 'soul'])) return '🎷';
    if (has(['electro', 'edm', 'techno', 'house', 'dance', 'trance'])) return '🎛️';
    if (has(['country', 'folk', 'acoustic'])) return '🪕';
    if (has(['bollywood', 'hindi', 'indian', 'tamil', 'telugu', 'punjabi', 'filmi', 'soundtrack', 'ost'])) return '🎬';
    if (has(['latin', 'reggae', 'salsa'])) return '🥁';
    if (has(['chill', 'ambient', 'lofi', 'lo-fi', 'relax', 'calm'])) return '🌙';
    if (has(['upbeat', 'energetic', 'party'])) return '⚡';
    if (has(['podcast', 'speech', 'audiobook'])) return '🎙️';
    if (g == 'unknown') return '❓';
    return '🎵';
  }

  Widget _genreGridItem({
    required String title,
    required String subtitle,
    required List<File> songs,
    required bool isDark,
    required Color cardColor,
    required Color primaryText,
    required Color secondaryText,
    required bool isLandscape,
  }) {
    final colors = _gradientFor(title);
    final glyph = _glyphFor(title);
    final coverItem = songs.isNotEmpty ? songs.first : null;

    Future<void> playAll() async {
      if (songs.isEmpty) return;
      HapticFeedback.selectionClick();
      final genrePaths = songs.map((f) => f.path).toList();
      await _markRecentlyPlayed(songs.first.path);
      widget.onPlay({'paths': genrePaths, 'startIndex': 0});
    }

    final playButton = Semantics(
      button: true,
      label: 'Play $title',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: playAll,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.95),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 3))],
              ),
              child: Icon(Icons.play_arrow_rounded, color: colors.last, size: 26),
            ),
          ),
        ),
      ),
    );

    Widget thumb(double size) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.22),
            border: Border.all(color: Colors.white.withOpacity(0.55), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.25), blurRadius: 8, offset: const Offset(0, 3))],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(size * 0.2),
            child: coverItem == null
                ? Container(color: Colors.white24)
                : _coverFromFile(coverItem),
          ),
        );

    final textBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: title,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            semanticsLabel: title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Colors.white, height: 1.1),
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.white.withOpacity(0.85)),
        ),
      ],
    );

    final decoration = BoxDecoration(
      borderRadius: BorderRadius.circular(22),
      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      boxShadow: [BoxShadow(color: colors.last.withOpacity(isDark ? 0.25 : 0.32), blurRadius: 14, offset: const Offset(0, 6))],
    );

    final body = isLandscape
        ? Container(
            decoration: decoration,
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(children: [
              thumb(56),
              const SizedBox(width: 12),
              Expanded(child: textBlock),
              Text(glyph, style: const TextStyle(fontSize: 28)),
              playButton,
            ]),
          )
        : Container(
            decoration: decoration,
            clipBehavior: Clip.antiAlias,
            child: Stack(children: [
              Positioned(
                right: -8,
                top: -6,
                child: Opacity(opacity: 0.28, child: Text(glyph, style: const TextStyle(fontSize: 92))),
              ),
              Positioned(left: 14, top: 14, child: thumb(54)),
              Positioned(left: 14, right: 14, bottom: 12, child: Padding(padding: const EdgeInsets.only(right: 44), child: textBlock)),
              Positioned(right: 2, bottom: 2, child: playButton),
            ]),
          );

    return Semantics(
      button: true,
      label: '$title, $subtitle',
      child: PressScale(
        onTap: () => _openGenreDetail(title, songs),
        child: body,
      ),
    );
  }

  Widget _coverFromFile(File file) {
    final bytes = _getMeta(file.path, 'cover');
    final borderRadius = BorderRadius.circular(12);

    if (bytes != null && bytes is Uint8List && bytes.isNotEmpty) {
      return ClipRRect(
        borderRadius: borderRadius,
        child: Image.memory(
          bytes,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
        ),
      );
    }

    return ClipRRect(
      borderRadius: borderRadius,
      child: Container(
        color: _accentColor.withOpacity(0.1),
        child: Center(
          child: Icon(
            Icons.music_note,
            size: 40,
            color: _accentColor.withOpacity(0.6),
          ),
        ),
      ),
    );
  }

  void _openGenreDetail(String genre, List<File> songs) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _GenreDetailScreen(
          title: genre,
          songs: songs,
          allAudioFiles: widget.audioFiles,
          onPlayFromAllList: (dynamic payload) {
            widget.onPlay(payload);
          },
          currentPlayingIndex: widget.currentPlayingIndex,
          metadataCache: Map<String, dynamic>.from(_mergedMeta),
        ),
      ),
    );
  }

  Widget _buildEmptyState(bool isDark) {
    final textColor = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final subColor = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF8C8A9D);
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 120,
              height: 120,
              decoration: BoxDecoration(
                color: cardColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.12),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  )
                ],
              ),
              child: Icon(Icons.library_music_outlined, size: 48, color: subColor),
            ),
            const SizedBox(height: 24),
            Text(
              'No Genres Found',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: textColor),
            ),
            const SizedBox(height: 12),
            Text(
              'Your music library is empty or no genre metadata is available.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: subColor, height: 1.4),
            )
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final bgColor = isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
    // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
    final appBarColor = isDark ? AppPalette.darkBackground : Colors.white;
    final iconColor = isDark ? Colors.white : Colors.black;
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;
    final primaryText = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final secondaryText = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF8C8A9D);

    final genreMap = _buildGenreMap();
    final genres = genreMap.keys.toList();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        centerTitle: true,
        title: Text('Genres', style: TextStyle(color: iconColor)),
        backgroundColor: appBarColor,
        elevation: 0,
        iconTheme: IconThemeData(color: iconColor),
        actions: [
          if (_untaggedCandidates().isNotEmpty)
            IconButton(
              icon: _smartTagging
                  ? SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: iconColor),
                    )
                  : Icon(Icons.auto_awesome, color: iconColor),
              tooltip: 'Smart-tag untagged songs',
              onPressed: _smartTagging ? null : _runSmartTagging,
            ),
        ],
      ),
      // FIX: Wrapped GlobalMiniPlayer in a Column with MainAxisSize.min
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget3(),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: genres.isEmpty
            ? _buildEmptyState(isDark)
            : LayoutBuilder(
          builder: (context, constraints) {
            final isLandscape = constraints.maxWidth > constraints.maxHeight;

            return GridView.builder(
              padding: const EdgeInsets.all(16),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: isLandscape ? 2.5 : 1.0,
              ),
              itemCount: genres.length,
              itemBuilder: (context, index) {
                final genre = genres[index];
                final songs = genreMap[genre]!;
                return StaggerIn(
                  playKey: 'genres:$genre',
                  index: index,
                  child: _genreGridItem(
                    title: genre,
                    subtitle: '${songs.length} ${songs.length == 1 ? 'track' : 'tracks'}',
                    songs: songs,
                    isDark: isDark,
                    cardColor: cardColor,
                    primaryText: primaryText,
                    secondaryText: secondaryText,
                    isLandscape: isLandscape,
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

// ---------- Genre Detail Screen ----------
class _GenreDetailScreen extends StatefulWidget {
  final String title;
  final List<File> songs;
  final List<File> allAudioFiles;
  final void Function(dynamic) onPlayFromAllList;
  final int? currentPlayingIndex;
  final Map<String, dynamic> metadataCache;

  const _GenreDetailScreen({
    required this.title,
    required this.songs,
    required this.allAudioFiles,
    required this.onPlayFromAllList,
    required this.metadataCache,
    this.currentPlayingIndex,
  });

  @override
  State<_GenreDetailScreen> createState() => _GenreDetailScreenState();
}

class _GenreDetailScreenState extends State<_GenreDetailScreen> {
  late List<File> _sortedSongs;
  List<File> _filteredSongs = [];
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _sortedSongs = [...widget.songs]
      ..sort((a, b) => _displayTitle(a).toLowerCase().compareTo(_displayTitle(b).toLowerCase()));
    _filteredSongs = List<File>.from(_sortedSongs);

    _searchController.addListener(() {
      final q = _searchController.text.trim();
      if (q != _query) {
        setState(() {
          _query = q;
          _applyFilter();
        });
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _markRecentlyPlayed(String path) async {
    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }
  }

  void _applyFilter() {
    if (_query.isEmpty) {
      _filteredSongs = List<File>.from(_sortedSongs);
      return;
    }

    final q = _query.toLowerCase();
    _filteredSongs = _sortedSongs.where((file) {
      final title = _getMetadataProperty(file.path, 'title')?.toString().toLowerCase() ?? '';
      final artist = _getMetadataProperty(file.path, 'artist')?.toString().toLowerCase() ?? '';
      final album = _getMetadataProperty(file.path, 'album')?.toString().toLowerCase() ?? '';
      final fileName = p.basenameWithoutExtension(file.path).toLowerCase();

      return title.contains(q) || artist.contains(q) || album.contains(q) || fileName.contains(q);
    }).toList();
  }

  dynamic _getMetadataProperty(String filePath, String property) {
    final meta = widget.metadataCache[filePath];
    if (meta == null) return null;
    if (meta is Map) {
      if (meta.containsKey(property)) return meta[property];
      if (meta.containsKey(property.toLowerCase())) return meta[property.toLowerCase()];
      return null;
    } else {
      return meta;
    }
  }

  String _displayTitle(File file) {
    return TitleCleaner.title(_getMetadataProperty(file.path, 'title')?.toString(), path: file.path);
  }

  void _onPlayFromFilteredList(int index) async {
    final selectedFile = _filteredSongs[index];
    final realIndexInSorted = _sortedSongs.indexWhere((f) => _normalizePath(f.path) == _normalizePath(selectedFile.path));

    await _markRecentlyPlayed(selectedFile.path);

    final payload = {
      'paths': _sortedSongs.map((f) => f.path).toList(),
      'startIndex': realIndexInSorted >= 0 ? realIndexInSorted : 0,
    };
    widget.onPlayFromAllList(payload);
  }

  String _normalizePath(String path) {
    try {
      return p.normalize(path).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      return path.toLowerCase();
    }
  }

  Future<void> _playAll({required bool shuffle}) async {
    if (_sortedSongs.isEmpty) return;
    HapticFeedback.selectionClick();
    final paths = _sortedSongs.map((f) => f.path).toList();
    if (shuffle) paths.shuffle();
    await _markRecentlyPlayed(paths.first);
    if (!mounted) return;
    widget.onPlayFromAllList({'paths': paths, 'startIndex': 0});
  }

  Widget _hero(bool isDark) {
    final colors = _GenresPageState._gradientFor(widget.title);
    final glyph = _GenresPageState._glyphFor(widget.title);
    Widget btn(String label, IconData icon, bool filled, VoidCallback onTap) => Expanded(
          child: Semantics(
            button: true,
            label: label,
            child: PressScale(
              onTap: onTap,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: filled ? Colors.white : Colors.white.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(24),
                  border: filled ? null : Border.all(color: Colors.white.withOpacity(0.6)),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, size: 22, color: filled ? colors.last : Colors.white),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: filled ? colors.last : Colors.white)),
                ]),
              ),
            ),
          ),
        );
    return FadeSlideIn(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        padding: const EdgeInsets.all(16),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        ),
        child: Stack(children: [
          Positioned(right: -6, top: -10, child: Opacity(opacity: 0.25, child: Text(glyph, style: const TextStyle(fontSize: 84)))),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: Colors.white)),
            const SizedBox(height: 2),
            Text('${_sortedSongs.length} ${_sortedSongs.length == 1 ? 'track' : 'tracks'}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white.withOpacity(0.85))),
            const SizedBox(height: 14),
            Row(children: [
              btn('Play', Icons.play_arrow_rounded, true, () => _playAll(shuffle: false)),
              const SizedBox(width: 10),
              btn('Shuffle', Icons.shuffle_rounded, false, () => _playAll(shuffle: true)),
            ]),
          ]),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final bgColor = isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
    // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
    final appBarColor = isDark ? AppPalette.darkBackground : Colors.white;
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;
    final primaryText = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final secondaryText = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF8C8A9D);
    final iconColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(widget.title, style: TextStyle(color: iconColor)),
        backgroundColor: appBarColor,
        iconTheme: IconThemeData(color: iconColor),
        foregroundColor: iconColor,
      ),
      // FIX: Wrapped GlobalMiniPlayer in a Column with MainAxisSize.min
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          BannerAdWidget(),
        ],
      ),
      body: Column(
        children: [
          _hero(isDark),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: TextField(
              controller: _searchController,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search ${widget.title}...',
                hintStyle: TextStyle(color: secondaryText.withOpacity(0.7)),
                prefixIcon: Icon(Icons.search, color: secondaryText),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(tooltip: 'Clear search', 
                  icon: Icon(Icons.clear, color: secondaryText),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _query = '';
                      _applyFilter();
                    });
                  },
                )
                    : null,
                filled: true,
                fillColor: cardColor,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
              style: TextStyle(color: primaryText),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                Text(
                  '${_filteredSongs.length} ${_filteredSongs.length == 1 ? 'track' : 'tracks'}',
                  style: TextStyle(color: secondaryText),
                ),
                const Spacer(),
                if (_query.isNotEmpty)
                  Text(
                    'Showing results for "$_query"',
                    style: TextStyle(
                      color: secondaryText,
                      fontStyle: FontStyle.italic,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 16),
              itemCount: _filteredSongs.length,
              itemBuilder: (context, index) {
                final file = _filteredSongs[index];
                return StaggerIn(
                  playKey: 'genre:${widget.title}:${file.path}',
                  index: index,
                  child: _TrackTile(
                  file: file,
                  allFiles: _sortedSongs,
                  allAudioFiles: widget.allAudioFiles,
                  onPlayFromAllList: (dynamic _) {
                    _onPlayFromFilteredList(index);
                  },
                  currentPlayingIndex: widget.currentPlayingIndex,
                  metadataCache: widget.metadataCache,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Track tile (Theme Aware) ----------
class _TrackTile extends StatefulWidget {
  final File file;
  final List<File> allFiles;
  final List<File> allAudioFiles;
  final void Function(dynamic originalIndexOrPayload) onPlayFromAllList;
  final int? currentPlayingIndex;
  final Map<String, dynamic> metadataCache;

  const _TrackTile({
    required this.file,
    required this.allFiles,
    required this.allAudioFiles,
    required this.onPlayFromAllList,
    required this.currentPlayingIndex,
    required this.metadataCache,
  });

  @override
  State<_TrackTile> createState() => _TrackTileState();
}

class _TrackTileState extends State<_TrackTile> {
  int? _localPlayingIndex;
  VoidCallback? _playlistPathListener;

  @override
  void initState() {
    super.initState();
    _localPlayingIndex = widget.currentPlayingIndex;

    try {
      _playlistPathListener = () {
        if (!mounted) return;
        setState(() {});
      };
      PlaylistContext.currentPathNotifier.addListener(_playlistPathListener!);
    } catch (_) {}
  }

  @override
  void didUpdateWidget(covariant _TrackTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPlayingIndex != oldWidget.currentPlayingIndex) {
      setState(() {
        _localPlayingIndex = widget.currentPlayingIndex;
      });
    }
  }

  @override
  void dispose() {
    if (_playlistPathListener != null) {
      try {
        PlaylistContext.currentPathNotifier.removeListener(_playlistPathListener!);
      } catch (_) {}
    }
    super.dispose();
  }

  dynamic _getMetadataProperty(String filePath, String property) {
    final meta = widget.metadataCache[filePath];
    if (meta == null) return null;
    if (meta is Map) {
      if (meta.containsKey(property)) return meta[property];
      if (meta.containsKey(property.toLowerCase())) return meta[property.toLowerCase()];
      return null;
    } else {
      return meta;
    }
  }

  String _displayTitle(File file) {
    return TitleCleaner.title(_getMetadataProperty(file.path, 'title')?.toString(), path: file.path);
  }

  String _displaySubtitle(File file) {
    final artist = _getMetadataProperty(file.path, 'artist');
    final album = _getMetadataProperty(file.path, 'album');
    final artistStr = TitleCleaner.artistOrUnknown(artist?.toString());
    final albumStr = album != null && album.toString().trim().isNotEmpty ? album.toString() : 'Unknown Album';
    return '$artistStr • $albumStr';
  }

  Uint8List? _getCover(File file) {
    final c = _getMetadataProperty(file.path, 'cover');
    if (c == null) return null;
    if (c is Uint8List) return c;
    if (c is List<int>) return Uint8List.fromList(c);
    return null;
  }

  Widget _coverFromFile(File file, bool isDark, {BorderRadius? radius, double? size}) {
    final r = radius ?? BorderRadius.circular(12);
    final bytes = _getCover(file);
    final cardColor = isDark ? AppPalette.darkCard : Colors.white;

    final child = (bytes != null && bytes.isNotEmpty)
        ? ClipRRect(
      borderRadius: r,
      child: Image.memory(
        bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
      ),
    )
        : Center(
      child: Icon(
        Icons.music_note,
        size: size ?? 40,
        color: isDark ? Colors.white70 : Colors.black54,
      ),
    );
    return Container(
      decoration: BoxDecoration(borderRadius: r, color: cardColor),
      child: child,
    );
  }

  String _normalizePath(String path) {
    try {
      return p.normalize(path).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      return path.toLowerCase();
    }
  }

  void _onTapSong() async {
    final indexInGenre = widget.allFiles.indexWhere(
          (f) => _normalizePath(f.path) == _normalizePath(widget.file.path),
    );
    final genrePaths = widget.allFiles.map((f) => f.path).toList();

    try {
      await RecentlyPlayedNotifier.instance.init();
      await RecentlyPlayedNotifier.instance.markPlayed(widget.file.path);
    } catch (e) {
      debugPrint('Recently played update failed: $e');
    }

    widget.onPlayFromAllList({
      'paths': genrePaths,
      'startIndex': indexInGenre >= 0 ? indexInGenre : 0,
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final primaryText = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final secondaryText = isDark ? const Color(0xFFB0B0B0) : const Color(0xFF8C8A9D);
    final accentColor = AppPalette.accent;
    final selectedColor = accentColor.withOpacity(0.06);

    final originalIndex = widget.allAudioFiles.indexWhere(
          (f) => _normalizePath(f.path) == _normalizePath(widget.file.path),
    );

    final isCurrentByIndex = _localPlayingIndex != null && originalIndex == _localPlayingIndex;

    final currentPath = PlaylistContext.currentPathNotifier.value;
    final isCurrentByPath = currentPath != null && _normalizePath(currentPath) == _normalizePath(widget.file.path);

    final isCurrent = isCurrentByIndex || isCurrentByPath;
    final playing = isCurrent;

    return ListTile(
      tileColor: isCurrent ? selectedColor : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      leading: Stack(
        alignment: Alignment.center,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 56,
              height: 56,
              child: _coverFromFile(
                widget.file,
                isDark,
                radius: BorderRadius.circular(6),
                size: 40,
              ),
            ),
          ),
          if (isCurrent)
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: accentColor.withOpacity(0.7),
                  width: 2,
                ),
              ),
            ),
        ],
      ),
      title: Text(
        _displayTitle(widget.file),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: primaryText),
      ),
      subtitle: Text(
        _displaySubtitle(widget.file),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: secondaryText),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        (isCurrent && playing)
            ? EqualizerBars(color: AppPalette.accent, playing: true)
            : Icon(Icons.play_arrow, color: primaryText),
        QueueMenuButton(paths: [widget.file.path], color: secondaryText),
      ]),
      onTap: () {
        HapticFeedback.selectionClick();
        _onTapSong();
      },
    );
  }
}

class _AsyncSemaphore {
  final int _maxPermits;
  int _available;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  _AsyncSemaphore(this._maxPermits) : _available = _maxPermits;

  Future<T> withPerm<T>(Future<T> Function() fn) async {
    await _acquire();
    try {
      return await fn();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      final c = _waiters.removeFirst();
      c.complete();
    } else {
      _available++;
      if (_available > _maxPermits) _available = _maxPermits;
    }
  }
}