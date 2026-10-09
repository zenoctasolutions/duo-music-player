// lib/artists_page.dart
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:music/list_page.dart';
import 'package:music/player_screen.dart';
import 'package:path/path.dart' as p;
import 'ad_widgets.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'app_palette.dart';

// Helper to check system/app theme brightness
bool isDark(BuildContext context) => Theme.of(context).brightness == Brightness.dark;

/// Song data model
class Song {
  final String title;
  final String artist;
  final String album;
  final String filePath;
  final String? duration;
  final Uint8List? coverArt;
  final String folderPath;

  Song({
    required this.title,
    required this.artist,
    required this.album,
    required this.filePath,
    this.duration,
    this.coverArt,
    required this.folderPath,
  });

  @override
  String toString() {
    return 'Song(title: $title, artist: $artist, album: $album, folder: $folderPath)';
  }
}

/// Artist data model - groups by metadata artist but preserves folder information
class Artist {
  final String name;
  final Map<String, List<Song>> songsByFolder;
  final Uint8List? coverImage;

  Artist({
    required this.name,
    required this.songsByFolder,
    this.coverImage,
  });

  List<Song> get allSongs {
    return songsByFolder.values.expand((songs) => songs).toList();
  }

  int get songCount => allSongs.length;
  int get folderCount => songsByFolder.length;

  int get albumCount {
    final albums = allSongs.map((song) => song.album).toSet();
    return albums.length;
  }

  @override
  String toString() {
    return 'Artist(name: $name, songs: $songCount, folders: $folderCount, albums: $albumCount)';
  }
}

class ArtistsPage extends StatefulWidget {
  final List<FileSystemEntity> audioFiles;
  final void Function(String path, int index)? onPlay;
  final ThemeNotifier? themeNotifier;

  const ArtistsPage({
    Key? key,
    required this.audioFiles,
    this.onPlay,
    this.themeNotifier,
  }) : super(key: key);

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final Color _accentColor = const Color(0xFF1DB954);
  final Color _primaryColor = AppPalette.accent;
  final Color _highlightColor = AppPalette.accent;

  static const _supportedExtensions = [
    '.mp3',
    '.m4a',
    '.flac',
    '.wav',
    '.aac',
    '.ogg',
    '.opus',
    '.mp4',
    '.m4b',
    '.aiff',
    '.aif'
  ];

  bool _isLoading = true;
  List<Artist> _artists = [];
  String _loadingProgress = 'Initializing...';

  final Map<String, Song> _tempSongCache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadArtistsAndSongs();
    });
  }

  String _artistFromMetadata(dynamic metadata) {
    try {
      final artist = metadata?.artist?.toString().trim() ?? '';
      if (artist.isNotEmpty && artist.toLowerCase() != 'unknown artist') {
        return artist;
      }
    } catch (_) {}

    try {
      final dynamic md = metadata;
      final alternatives = [
        md.albumArtist,
        md.albumartist,
        md.performer,
        md.author,
        md.band,
        md.composer,
        md.interpret,
      ];

      for (final value in alternatives) {
        final s = value?.toString().trim() ?? '';
        if (s.isNotEmpty && s.toLowerCase() != 'unknown artist') {
          return s;
        }
      }
    } catch (_) {}

    return 'Unknown Artist';
  }

  Future<void> _loadArtistsAndSongs() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _loadingProgress = 'Scanning files...';
      _artists = [];
      _tempSongCache.clear();
    });

    try {
      final audioFiles = widget.audioFiles.where((e) => e is File).cast<File>().where((file) {
        final extension = p.extension(file.path).toLowerCase();
        return _supportedExtensions.contains(extension);
      }).toList();

      if (!mounted) return;
      setState(() => _loadingProgress = 'Found ${audioFiles.length} audio files');

      final List<Song> allSongs = [];
      const int batchSize = 12;

      for (int i = 0; i < audioFiles.length; i += batchSize) {
        if (!mounted) return;
        final end = (i + batchSize > audioFiles.length) ? audioFiles.length : i + batchSize;
        final batch = audioFiles.sublist(i, end);

        setState(() => _loadingProgress = 'Processing $end of ${audioFiles.length} files');

        final batchSongs = await Future.wait(batch.map((f) => _extractSongMetadata(f)));
        final cleaned = batchSongs.where((s) => s != null).cast<Song>().toList();
        allSongs.addAll(cleaned);

        if (mounted) _updateArtistsList(allSongs);
      }

      if (mounted) {
        _updateArtistsList(allSongs);
        setState(() {
          _isLoading = false;
          _loadingProgress = 'Completed';
        });
      }
    } catch (e) {
      debugPrint('Error loading artists: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadingProgress = 'Error: $e';
        });
      }
    }
  }

  Future<Song?> _extractSongMetadata(File file) async {
    try {
      final metadata = await readMetadata(file, getImage: true);

      String title = metadata?.title?.trim() ?? '';
      String artist = _artistFromMetadata(metadata);
      String album = metadata?.album?.trim() ?? '';
      final String folderPath = p.dirname(file.path);

      if (title.isEmpty) {
        title = p.basenameWithoutExtension(file.path);
      }

      // Do not guess artist from filename.
      // This avoids hero/heroine or movie names being shown as artist names.
      if (artist.isEmpty) {
        artist = 'Unknown Artist';
      }

      if (album.isEmpty) {
        album = p.basename(folderPath);
      }

      Uint8List? coverArt;
      if (metadata?.pictures != null && metadata!.pictures!.isNotEmpty) {
        try {
          final pic = metadata.pictures!.first;
          dynamic raw;
          try {
            raw = (pic as dynamic).bytes ?? (pic as dynamic).buffer ?? (pic as dynamic).data;
          } catch (_) {
            raw = null;
          }
          if (raw is Uint8List) {
            coverArt = raw;
          } else if (raw is List<int>) {
            coverArt = Uint8List.fromList(raw);
          }
        } catch (_) {}
      }

      final song = Song(
        title: title,
        artist: artist,
        album: album,
        filePath: file.path,
        coverArt: coverArt,
        folderPath: folderPath,
      );

      _tempSongCache[file.path] = song;
      return song;
    } catch (e) {
      debugPrint('Error extracting metadata for ${file.path}: $e');
      final fallback = Song(
        title: p.basenameWithoutExtension(file.path),
        artist: 'Unknown Artist',
        album: p.basename(p.dirname(file.path)),
        filePath: file.path,
        folderPath: p.dirname(file.path),
      );
      _tempSongCache[file.path] = fallback;
      return fallback;
    }
  }

  void _updateArtistsList(List<Song> allSongs) {
    final Map<String, Map<String, List<Song>>> artistsMap = {};

    for (final song in allSongs) {
      final artistName = (song.artist.isEmpty || song.artist.toLowerCase() == 'unknown artist')
          ? 'Unknown Artist'
          : song.artist;

      if (!artistsMap.containsKey(artistName)) {
        artistsMap[artistName] = {};
      }

      final folderPath = song.folderPath;
      artistsMap[artistName]!.putIfAbsent(folderPath, () => []).add(song);
    }

    final List<Artist> artists = [];

    for (final entry in artistsMap.entries) {
      final artistName = entry.key;
      final foldersMap = entry.value;

      for (final folderEntry in foldersMap.entries) {
        folderEntry.value.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
      }

      Uint8List? coverImage;
      for (final folderSongs in foldersMap.values) {
        for (final song in folderSongs) {
          if (song.coverArt != null && song.coverArt!.isNotEmpty) {
            coverImage = song.coverArt;
            break;
          }
        }
        if (coverImage != null) break;
      }

      artists.add(Artist(
        name: artistName,
        songsByFolder: foldersMap,
        coverImage: coverImage,
      ));
    }

    artists.sort((a, b) {
      if (a.name == 'Unknown Artist' && b.name != 'Unknown Artist') return 1;
      if (b.name == 'Unknown Artist' && a.name != 'Unknown Artist') return -1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    setState(() => _artists = artists);
  }

  void _refreshArtists() {
    setState(() {
      _isLoading = true;
      _artists.clear();
      _loadingProgress = 'Refreshing...';
    });
    _loadArtistsAndSongs();
  }

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    final bgColor = dark ? AppPalette.darkBackground : Colors.white;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;
    final txtColor = dark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          'Artists',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: txtColor,
          ),
        ),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        iconTheme: IconThemeData(color: txtColor),
      ),
      // FIX: Wrapped GlobalMiniPlayer in a Column with MainAxisSize.min
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
        ],
      ),
      body: _isLoading
          ? _buildLoadingIndicator(dark)
          : _artists.isEmpty
          ? _buildEmptyState(dark)
          : _buildArtistsList(dark),
    );
  }

  Widget _buildLoadingIndicator(bool dark) {
    final subColor = dark ? Colors.grey.shade400 : Colors.grey.shade700;
    final accent = dark ? _primaryColor : _accentColor;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(accent)),
          const SizedBox(height: 20),
          Text(_loadingProgress, style: TextStyle(color: subColor, fontSize: 16), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool dark) {
    final txtColor = dark ? Colors.white : Colors.black;
    final subColor = dark ? Colors.grey.shade400 : Colors.grey.shade700;
    final accent = dark ? _primaryColor : _accentColor;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.people_outline, size: 80, color: subColor),
          const SizedBox(height: 20),
          Text('No Artists Found', style: TextStyle(color: txtColor, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40.0),
            child: Text(
              'No music files with artist information were found.',
              style: TextStyle(color: subColor, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _refreshArtists,
            style: ElevatedButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildArtistsList(bool dark) {
    final subColor = dark ? Colors.grey.shade400 : Colors.grey.shade700;

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Row(
            children: [
              Text('${_artists.length} ${_artists.length == 1 ? 'artist' : 'artists'}',
                  style: TextStyle(color: subColor, fontSize: 14)),
              const Spacer(),
              Text('${_artists.fold(0, (sum, artist) => sum + artist.songCount)} songs',
                  style: TextStyle(color: subColor, fontSize: 14)),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _artists.length,
            itemBuilder: (context, index) {
              final artist = _artists[index];
              return _buildArtistCard(artist, dark);
            },
          ),
        ),
        const BannerAdWidget(),
      ],
    );
  }

  Widget _buildArtistCard(Artist artist, bool dark) {
    final cardColor = dark ? AppPalette.darkCard : Colors.grey.shade50;
    final txtColor = dark ? Colors.white : Colors.black;
    final subColor = dark ? Colors.grey.shade400 : Colors.grey.shade700;

    return Card(
      color: cardColor,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 0,
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: dark ? Colors.grey[800] : Colors.grey[300],
            borderRadius: BorderRadius.circular(8),
            image: artist.coverImage != null
                ? DecorationImage(
              image: MemoryImage(artist.coverImage!),
              fit: BoxFit.cover,
            )
                : null,
          ),
          child: artist.coverImage == null
              ? Center(
            child: Icon(
              Icons.person,
              color: dark ? Colors.white54 : Colors.black54,
              size: 30,
            ),
          )
              : null,
        ),
        title: Text(
          artist.name,
          style: TextStyle(color: txtColor, fontWeight: FontWeight.bold, fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4.0),
          child: Text(
            '${artist.songCount} songs • ${artist.folderCount} ${artist.folderCount == 1 ? 'folder' : 'folders'}',
            style: TextStyle(color: subColor, fontSize: 13),
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: subColor, size: 24),
        onTap: () => _navigateToArtistDetail(artist),
      ),
    );
  }

  void _navigateToArtistDetail(Artist artist) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ArtistDetailPage(
          artist: artist,
          onPlay: (path, idx) {
            if (widget.onPlay != null) widget.onPlay!(path, idx);
          },
        ),
      ),
    );
  }
}

////////////////////////////////////////////////////////////////////////////////
/// Artist Detail Page
////////////////////////////////////////////////////////////////////////////////

class ArtistDetailPage extends StatefulWidget {
  final Artist artist;
  final void Function(String path, int index)? onPlay;

  const ArtistDetailPage({
    Key? key,
    required this.artist,
    this.onPlay,
  }) : super(key: key);

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  String? _selectedFolder;
  List<Song> _currentFolderSongs = [];

  String? _currentPath;
  bool _isPlaying = false;
  int _currentIndexInFolder = -1;
  late String _pageId;

  late final VoidCallback _playbackListener;
  late final VoidCallback _isPlayingListener;

  @override
  void initState() {
    super.initState();

    if (widget.artist.songsByFolder.isNotEmpty) {
      _selectedFolder = widget.artist.songsByFolder.keys.first;
      _currentFolderSongs = widget.artist.songsByFolder[_selectedFolder]!;
      _pageId = 'artist:${widget.artist.name}:folder:${Uri.encodeComponent(_selectedFolder!)}';
    }

    _playbackListener = () {
      if (!mounted) return;
      setState(() {
        _currentPath = PlaybackState.current.value;
        _recomputeIndex();
      });
    };

    _isPlayingListener = () {
      if (!mounted) return;
      setState(() {
        _isPlaying = PlaybackState.isPlaying.value;
      });
    };

    try {
      PlaybackState.current.addListener(_playbackListener);
      PlaybackState.isPlaying.addListener(_isPlayingListener);
    } catch (_) {}

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _currentPath = PlaybackState.current.value;
      _isPlaying = PlaybackState.isPlaying.value;
      _recomputeIndex();
      setState(() {});
    });
  }

  @override
  void dispose() {
    try {
      PlaybackState.current.removeListener(_playbackListener);
      PlaybackState.isPlaying.removeListener(_isPlayingListener);
    } catch (_) {}
    super.dispose();
  }

  void _recomputeIndex() {
    final cur = PlaybackState.current.value;
    if (cur == null) {
      _currentIndexInFolder = -1;
      return;
    }
    final idx = _currentFolderSongs.indexWhere((song) => _normalizePath(song.filePath) == _normalizePath(cur));
    _currentIndexInFolder = idx;
  }

  String _normalizePath(String pth) {
    try {
      return p.normalize(pth).replaceAll('\\', '/').toLowerCase();
    } catch (_) {
      return pth.toLowerCase();
    }
  }

  List<String> _currentFolderPaths() {
    return _currentFolderSongs.map((s) => s.filePath).toList(growable: false);
  }

  void _selectFolder(String folderPath) {
    setState(() {
      _selectedFolder = folderPath;
      _currentFolderSongs = widget.artist.songsByFolder[folderPath]!;
      _pageId = 'artist:${widget.artist.name}:folder:${Uri.encodeComponent(folderPath)}';
      _currentIndexInFolder = -1;
    });
  }

  Future<void> _setCurrentPlaylistAndPlay(int index) async {
    if (index < 0 || index >= _currentFolderSongs.length) return;

    final paths = _currentFolderPaths();
    final currentPath = paths[index];

    try {
      try {
        PlaylistContext.setCurrentPlaylist(paths, pageId: _pageId);
      } catch (_) {}

      await PlaybackController.instance.setPlaylist(
        paths,
        startIndex: index,
        play: true,
        pageId: _pageId,
      );

      try {
        PlaylistContext.setCurrentPath(currentPath);
      } catch (_) {}

      if (mounted) {
        setState(() {
          _currentPath = currentPath;
          _currentIndexInFolder = index;
          _isPlaying = true;
        });
      }

      widget.onPlay?.call(currentPath, index);
    } catch (e) {
      debugPrint('Error playing song: $e');
    }
  }

  Future<void> _playAllFromCurrentFolder() async {
    if (_currentFolderSongs.isEmpty) return;
    await _setCurrentPlaylistAndPlay(0);
  }

  Future<void> _toggleOrPlayIndex(int index) async {
    final isPlayingHere = (_currentIndexInFolder == index) && _isPlaying;
    final isSamePath = (_currentIndexInFolder == index);

    if (isPlayingHere) {
      try {
        await PlaybackController.instance.pause();
      } catch (e) {
        debugPrint('Pause failed: $e');
      }
    } else if (isSamePath && !_isPlaying) {
      try {
        await PlaybackController.instance.resume();
        widget.onPlay?.call(_currentFolderSongs[index].filePath, index);
      } catch (e) {
        debugPrint('Resume failed: $e');
      }
    } else {
      await _setCurrentPlaylistAndPlay(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = isDark(context);
    final bgColor = dark ? AppPalette.darkBackground : Colors.grey.shade50;
    final txtColor = dark ? Colors.white : Colors.black;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;

    final title = widget.artist.name;
    final folders = widget.artist.songsByFolder.keys.toList();

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
        iconTheme: IconThemeData(color: txtColor),
        title: Text(
          'Artist Details',
          style: TextStyle(color: txtColor, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        elevation: 0,
        centerTitle: true,
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
          Container(
            width: double.infinity,
            color: cardColor,
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: dark ? Colors.grey[800] : Colors.grey[300],
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      )
                    ],
                    image: widget.artist.coverImage != null
                        ? DecorationImage(
                      image: MemoryImage(widget.artist.coverImage!),
                      fit: BoxFit.cover,
                    )
                        : null,
                  ),
                  child: widget.artist.coverImage == null
                      ? Icon(Icons.person, color: dark ? Colors.white54 : Colors.black54, size: 50)
                      : null,
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(color: txtColor, fontSize: 24, fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${widget.artist.songCount} songs • ${widget.artist.folderCount} ${widget.artist.folderCount == 1 ? 'folder' : 'folders'}',
                        style: TextStyle(
                          color: dark ? Colors.white70 : Colors.black54,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_selectedFolder != null && _currentFolderSongs.isNotEmpty)
                        ElevatedButton.icon(
                          onPressed: _playAllFromCurrentFolder,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppPalette.accent,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                          label: const Text('Play All', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          if (folders.length > 1)
            Container(
              height: 60,
              width: double.infinity,
              color: bgColor,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: folders.length,
                itemBuilder: (context, index) {
                  final folderPath = folders[index];
                  final folderName = p.basename(folderPath);
                  final isSelected = _selectedFolder == folderPath;
                  final songCount = widget.artist.songsByFolder[folderPath]!.length;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8, top: 12, bottom: 12),
                    child: ChoiceChip(
                      label: Text('$folderName ($songCount)', style: const TextStyle(fontWeight: FontWeight.bold)),
                      selected: isSelected,
                      onSelected: (_) => _selectFolder(folderPath),
                      backgroundColor: dark ? Colors.grey[800] : Colors.grey[300],
                      selectedColor: AppPalette.accent,
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.white : txtColor,
                      ),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      side: BorderSide.none,
                    ),
                  );
                },
              ),
            ),

          if (folders.length <= 1) const SizedBox(height: 16),

          Expanded(
            child: _selectedFolder == null
                ? Center(
              child: Text(
                'Select a folder',
                style: TextStyle(color: dark ? Colors.grey.shade700 : Colors.grey.shade400),
              ),
            )
                : _currentFolderSongs.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_off, size: 64, color: dark ? Colors.grey.shade700 : Colors.grey.shade400),
                  const SizedBox(height: 16),
                  Text(
                    'No songs in this folder',
                    style: TextStyle(color: dark ? Colors.grey.shade700 : Colors.grey.shade400, fontSize: 16),
                  ),
                ],
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.only(bottom: 12),
              itemCount: _currentFolderSongs.length,
              itemBuilder: (context, index) {
                final song = _currentFolderSongs[index];
                return _buildSongItem(song, index, dark);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSongItem(Song song, int index, bool dark) {
    final isPlayingHere = (_currentIndexInFolder == index) && _isPlaying;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;
    final txtColor = dark ? Colors.white : Colors.black;
    final subColor = dark ? Colors.grey.shade400 : Colors.grey.shade700;
    final highlight = AppPalette.accent;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isPlayingHere ? highlight.withOpacity(0.5) : Colors.transparent,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _setCurrentPlaylistAndPlay(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 30,
                  child: Text(
                    '${index + 1}',
                    style: TextStyle(
                      color: isPlayingHere ? highlight : subColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (song.coverArt != null && song.coverArt!.isNotEmpty) ...[
                  Container(
                    width: 44,
                    height: 44,
                    margin: const EdgeInsets.only(right: 14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      image: DecorationImage(image: MemoryImage(song.coverArt!), fit: BoxFit.cover),
                    ),
                  ),
                ] else ...[
                  Container(
                    width: 44,
                    height: 44,
                    margin: const EdgeInsets.only(right: 14),
                    decoration: BoxDecoration(
                      color: dark ? Colors.grey[800] : Colors.grey[200],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(Icons.music_note, color: subColor, size: 22),
                  ),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        song.title,
                        style: TextStyle(
                          color: isPlayingHere ? highlight : txtColor,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        song.album,
                        style: TextStyle(
                          color: subColor,
                          fontSize: 13,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF2A2A2A) : Colors.grey[100],
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: isPlayingHere
                        ? Icon(Icons.equalizer, size: 18, color: highlight)
                        : const Icon(Icons.play_arrow_rounded, size: 20),
                    color: highlight,
                    onPressed: () => _toggleOrPlayIndex(index),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Dummy ThemeNotifier for compatibility
class ThemeNotifier {
  ThemeNotifier();
}