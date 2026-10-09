// lib/genres_page.dart
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:music/player_screen.dart';
import 'audio_analysis_service.dart';
import 'list_page.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'banner_ad_widget3.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';

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
        out.add(_normGenre(t));
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
    final coverItem = songs.isNotEmpty ? songs.first : null;

    if (isLandscape) {
      return InkWell(
        onTap: () => _openGenreDetail(title, songs),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              SizedBox(
                width: 60,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: coverItem != null
                      ? _coverFromFile(coverItem)
                      : Container(
                    color: _accentColor.withOpacity(0.1),
                    child: Icon(Icons.library_music, color: secondaryText, size: 24),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: primaryText),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: secondaryText),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () async {
                  if (songs.isNotEmpty) {
                    final genrePaths = songs.map((f) => f.path).toList();
                    await _markRecentlyPlayed(songs.first.path);
                    widget.onPlay({'paths': genrePaths, 'startIndex': 0});
                  }
                },
                child: CircleAvatar(
                  radius: 18,
                  backgroundColor: _accentColor,
                  child: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return InkWell(
      onTap: () => _openGenreDetail(title, songs),
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: cardColor,
                  ),
                  child: coverItem != null
                      ? _coverFromFile(coverItem)
                      : Center(
                    child: Icon(
                      Icons.library_music,
                      size: 48,
                      color: secondaryText,
                    ),
                  ),
                ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: GestureDetector(
                    onTap: () async {
                      if (songs.isNotEmpty) {
                        final genrePaths = songs.map((f) => f.path).toList();
                        await _markRecentlyPlayed(songs.first.path);
                        widget.onPlay({'paths': genrePaths, 'startIndex': 0});
                      }
                    },
                    child: CircleAvatar(
                      radius: 18,
                      backgroundColor: _accentColor,
                      child: const Icon(Icons.play_arrow, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: primaryText,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              color: secondaryText,
            ),
          ),
        ],
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

    final bgColor = isDark ? const Color(0xFF0B0B0B) : const Color(0xFFF8F9FD);
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
                childAspectRatio: isLandscape ? 2.5 : 0.78,
              ),
              itemCount: genres.length,
              itemBuilder: (context, index) {
                final genre = genres[index];
                final songs = genreMap[genre]!;
                return _genreGridItem(
                  title: genre,
                  subtitle: '${songs.length} ${songs.length == 1 ? 'track' : 'tracks'}',
                  songs: songs,
                  isDark: isDark,
                  cardColor: cardColor,
                  primaryText: primaryText,
                  secondaryText: secondaryText,
                  isLandscape: isLandscape,
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
    final t = _getMetadataProperty(file.path, 'title');
    if (t != null && t.toString().trim().isNotEmpty) return t.toString();
    return p.basenameWithoutExtension(file.path);
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

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final bgColor = isDark ? const Color(0xFF0B0B0B) : const Color(0xFFF8F9FD);
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
                    ? IconButton(
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
                  borderRadius: BorderRadius.circular(12),
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
                return _TrackTile(
                  file: file,
                  allFiles: _sortedSongs,
                  allAudioFiles: widget.allAudioFiles,
                  onPlayFromAllList: (dynamic _) {
                    _onPlayFromFilteredList(index);
                  },
                  currentPlayingIndex: widget.currentPlayingIndex,
                  metadataCache: widget.metadataCache,
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
    final t = _getMetadataProperty(file.path, 'title');
    if (t != null && t.toString().trim().isNotEmpty) return t.toString();
    return p.basenameWithoutExtension(file.path);
  }

  String _displaySubtitle(File file) {
    final artist = _getMetadataProperty(file.path, 'artist');
    final album = _getMetadataProperty(file.path, 'album');
    final artistStr = artist != null && artist.toString().trim().isNotEmpty ? artist.toString() : 'Unknown Artist';
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: primaryText),
      ),
      subtitle: Text(
        _displaySubtitle(widget.file),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: secondaryText),
      ),
      trailing: (isCurrent && playing)
          ? const _PlayingBadge()
          : Icon(Icons.play_arrow, color: primaryText),
      onTap: _onTapSong,
    );
  }
}

class _PlayingBadge extends StatelessWidget {
  const _PlayingBadge();

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.equalizer, color: AppPalette.accent);
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