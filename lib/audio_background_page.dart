// lib/audio_background_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart'; // only for MediaItem
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';

import 'list_page.dart'; // FavoritesNotifier from your app

class AudioBackgroundPage extends StatefulWidget {
  final List<File> initialFiles;
  const AudioBackgroundPage({Key? key, this.initialFiles = const []}) : super(key: key);

  @override
  State<AudioBackgroundPage> createState() => _AudioBackgroundPageState();
}

class _AudioBackgroundPageState extends State<AudioBackgroundPage> {
  final AudioPlayer _player = AudioPlayer();
  List<File> _files = [];
  int _currentIndex = -1;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  final Map<String, Uint8List?> _coverCache = {};
  Set<String> _favorites = {};

  // UI colors
  final Color _darkBg = AppPalette.darkBackground;
  final Color _card = AppPalette.darkCard;
  final Color _accent = AppPalette.accent;
  final Color _subtitle = const Color(0xFFB0B0B0);

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int?>? _currentIndexSub;
  StreamSubscription<SequenceState?>? _seqSub;

  @override
  void initState() {
    super.initState();
    _files = List<File>.from(widget.initialFiles);
    _initPlayerListeners();
    _initFavorites();
    if (_files.isNotEmpty) setPlaylist(_files);
  }

  void _initPlayerListeners() {
    _posSub = _player.positionStream.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = _player.durationStream.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d ?? Duration.zero);
    });
    _stateSub = _player.playerStateStream.listen((st) {
      if (!mounted) return;
      setState(() {
        _isPlaying = st.playing;
        if (st.processingState == ProcessingState.completed) {
          _stopAndReset();
        }
      });
    });
    _currentIndexSub = _player.currentIndexStream.listen((idx) {
      if (!mounted) return;
      setState(() {
        _currentIndex = idx ?? -1;
      });
    });
    _seqSub = _player.sequenceStateStream.listen((s) {
      if (!mounted) return;
      // Update duration from player after sequence/track change
      setState(() {
        _duration = _player.duration ?? Duration.zero;
      });
    });
  }

  Future<void> _initFavorites() async {
    await FavoritesNotifier.instance.init();
    setState(() {
      _favorites = Set<String>.from(FavoritesNotifier.instance.favoritesSet);
    });
    FavoritesNotifier.instance.addListener(_onFavChanged);
  }

  void _onFavChanged() {
    if (!mounted) return;
    setState(() {
      _favorites = Set<String>.from(FavoritesNotifier.instance.favoritesSet);
    });
  }

  @override
  void dispose() {
    FavoritesNotifier.instance.removeListener(_onFavChanged);
    _posSub?.cancel();
    _durSub?.cancel();
    _stateSub?.cancel();
    _currentIndexSub?.cancel();
    _seqSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  /// Public: replace playlist
  Future<void> setPlaylist(List<File> files) async {
    _files = List<File>.from(files);

    // create AudioSource with MediaItem tag for each file (required by just_audio_background)
    final sources = _files.map((f) {
      final mediaItem = _fileToMediaItem(f);
      return AudioSource.uri(Uri.file(f.path), tag: mediaItem);
    }).toList();

    try {
      await _player.setAudioSource(ConcatenatingAudioSource(children: sources));
    } catch (e) {
      debugPrint('Error setting audio source: $e');
    }
    setState(() {});
  }

  Future<void> _playAt(int index) async {
    if (index < 0 || index >= _files.length) return;
    _currentIndex = index;
    try {
      await _player.seek(Duration.zero, index: index);
      await _player.setSpeed(1.0);
      await _player.play();
    } catch (e) {
      debugPrint('Play error: $e');
    }
    setState(() {});
  }

  Future<void> _pause() async => await _player.pause();
  Future<void> _resume() async => await _player.play();
  Future<void> _stopAndReset() async {
    await _player.stop();
    _currentIndex = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    if (mounted) setState(() {});
  }

  Future<void> _toggleFavorite(File f) async {
    final path = f.path;
    if (_favorites.contains(path)) {
      await FavoritesNotifier.instance.remove(path);
    } else {
      await FavoritesNotifier.instance.add(path);
    }
  }

  MediaItem _fileToMediaItem(File f) {
    // build a MediaItem tag for just_audio_background
    final title = p.basenameWithoutExtension(f.path);
    final album = p.basename(p.dirname(f.path));
    return MediaItem(
      id: f.path,
      album: album,
      title: title,
      // extras can carry the file path for your app logic
      extras: {'filePath': f.path},
    );
  }

  /// Load embedded cover art (or fallback to sidecar files).
  Future<Uint8List?> _loadCover(File f) async {
    final key = f.path;
    if (_coverCache.containsKey(key)) return _coverCache[key];

    try {
      final meta = await readMetadata(f, getImage: true);
      if (meta != null) {
        try {
          if (meta.pictures != null && meta.pictures is List && meta.pictures.isNotEmpty) {
            final first = (meta.pictures as List).first;
            try {
              final dyn = first;
              final b = (dyn as dynamic).bytes;
              if (b is Uint8List) {
                _coverCache[key] = b;
                return b;
              } else if (b is List<int>) {
                final u = Uint8List.fromList(b.cast<int>());
                _coverCache[key] = u;
                return u;
              }
            } catch (_) {}
            if (first is Uint8List) {
              _coverCache[key] = first;
              return first;
            }
            if (first is List<int>) {
              final u = Uint8List.fromList(first.cast<int>());
              _coverCache[key] = u;
              return u;
            }
            if (first is Map && first['bytes'] != null) {
              final u = Uint8List.fromList(List<int>.from(first['bytes']));
              _coverCache[key] = u;
              return u;
            }
          }
        } catch (_) {}
      }
    } catch (e) {
      // metadata library couldn't parse — fallback gracefully
      debugPrint('Error reading metadata: $e');
    }

    // fallback to side-car cover files
    try {
      final dir = Directory(p.dirname(f.path));
      if (await dir.exists()) {
        final list = await dir.list().toList();
        for (final e in list) {
          if (e is File) {
            final name = p.basename(e.path).toLowerCase();
            if (['cover.jpg','cover.png','folder.jpg','folder.png','album.jpg','album.png','artwork.jpg','artwork.png']
                .any((n) => name.contains(n))) {
              final bytes = await e.readAsBytes();
              _coverCache[key] = bytes;
              return bytes;
            }
          }
        }
      }
    } catch (_) {}

    _coverCache[key] = null;
    return null;
  }

  String _format(Duration d) {
    final two = (int n) => n.toString().padLeft(2, '0');
    if (d.inHours > 0) return '${two(d.inHours)}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
    return '${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}';
  }

  // --- UI below (kept largely the same as your design) ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: _darkBg,
      appBar: AppBar(
        title: const Text('Background Audio'),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: AppPalette.darkBackground,
        elevation: 0,
      ),
      body: Column(
        children: [
          Expanded(child: _buildFileList()),
          Container(
            color: _darkBg,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _buildMiniPlayer(),
          ),
        ],
      ),
    );
  }

  Widget _buildFileList() {
    if (_files.isEmpty) {
      return Center(child: Text('No files assigned to playlist', style: TextStyle(color: _subtitle)));
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _files.length,
      itemBuilder: (context, i) {
        final f = _files[i];
        final isCurrent = i == _currentIndex;
        final fav = _favorites.contains(f.path);

        return FutureBuilder<Uint8List?>(
          future: _loadCover(f),
          builder: (context, snap) {
            final cover = snap.data;
            return Card(
              color: isCurrent ? _accent.withOpacity(0.12) : _card,
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                onTap: () => _playAt(i),
                leading: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: cover != null ? Image.memory(cover, fit: BoxFit.cover) : Container(
                      color: Colors.black26,
                      child: Icon(Icons.music_note, color: _subtitle),
                    ),
                  ),
                ),
                title: Text(p.basenameWithoutExtension(f.path), style: const TextStyle(color: Colors.white)),
                subtitle: Text(p.basename(p.dirname(f.path)), style: TextStyle(color: _subtitle)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(tooltip: 'Favorite', 
                      icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.red : _subtitle),
                      onPressed: () => _toggleFavorite(f),
                    ),
                    IconButton(tooltip: 'Play', 
                      icon: Icon(Icons.play_arrow, color: _subtitle),
                      onPressed: () => _playAt(i),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildMiniPlayer() {
    final hasTrack = _currentIndex >= 0 && _currentIndex < _files.length;
    final title = hasTrack ? p.basenameWithoutExtension(_files[_currentIndex].path) : 'No track';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text('${_format(_position)} / ${_format(_duration)}', style: TextStyle(color: _subtitle, fontSize: 12)),
                ],
              ),
            ),
            IconButton(tooltip: 'Previous', icon: Icon(Icons.skip_previous, color: _subtitle), onPressed: _currentIndex > 0 ? () => _playAt(_currentIndex - 1) : null),
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: AppPalette.gradientColors),
                shape: BoxShape.circle,
              ),
              child: IconButton(tooltip: _isPlaying ? 'Pause' : 'Play', 
                icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.white),
                onPressed: () async {
                  if (_isPlaying) await _pause(); else await _resume();
                },
              ),
            ),
            IconButton(tooltip: 'Next', icon: Icon(Icons.skip_next, color: _subtitle), onPressed: (_currentIndex < _files.length - 1) ? () => _playAt(_currentIndex + 1) : null),
          ],
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(
          value: (_duration.inMilliseconds > 0) ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0) : 0,
          minHeight: 3,
          backgroundColor: Colors.black26,
          valueColor: AlwaysStoppedAnimation<Color>(_accent),
        ),
      ],
    );
  }
}
