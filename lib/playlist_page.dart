// lib/create_playlist_page.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:music/list_page.dart';
import 'package:path/path.dart' as p;
// import 'package:audio_metadata_reader/audio_metadata_reader.dart'; // Unused in this file directly, but kept if needed
import 'player_screen.dart'; // For PlaylistContext and PlaybackState
import 'banner_ad_widget3.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';

// Helper to check system theme
bool isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

typedef OnPlayCallback = void Function(String path, List<String> playlistPaths);

/// CreatePlaylistPage - Lists all playlists and allows creating new ones
class CreatePlaylistPage extends StatefulWidget {
  final List<FileSystemEntity> audioFiles;
  final OnPlayCallback? onPlay;
  final Widget? miniPlayer;
  final Future<Uint8List?> Function(File file) loadCoverForFile;
  final void Function(int index)? onNavTap;
  // themeController removed - system theme handled by context

  const CreatePlaylistPage({
    Key? key,
    required this.audioFiles,
    this.onPlay,
    this.miniPlayer,
    required this.loadCoverForFile,
    this.onNavTap, required themeController, required String pageId,
    // this.themeController, // Removed
  }) : super(key: key);

  @override
  State<CreatePlaylistPage> createState() => _CreatePlaylistPageState();
}

class _CreatePlaylistPageState extends State<CreatePlaylistPage> {
  static const _boxName = 'custom_playlists'; // Matches PlayerScreen service

  late Box _box;
  Map<String, List<String>> _playlists = {};
  String? _newPlaylistName;
  List<bool> _selected = [];
  bool _loading = true;
  bool _creating = false;

  // playback listeners
  VoidCallback? _playbackListener;

  @override
  void initState() {
    super.initState();
    _selected = List<bool>.filled(widget.audioFiles.length, false);
    _initHiveAndLoad();
    _attachPlaybackListeners();
  }

  void _attachPlaybackListeners() {
    _playbackListener = () {
      if (mounted) setState(() {});
    };
    try {
      // Assuming PlaybackState is defined in player_screen.dart or list_page.dart
      // If it's in list_page.dart, ensure that file is imported or PlaybackState is accessible.
      // For this file's context, we rely on the import 'player_screen.dart' or wherever PlaybackState resides.
      // Since the original code imported list_page.dart for PlaybackController, we assume PlaybackState is available.
    } catch (_) {}
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _initHiveAndLoad() async {
    try {
      try {
        await Hive.initFlutter();
      } catch (_) {}
      if (!Hive.isBoxOpen(_boxName)) {
        _box = await Hive.openBox(_boxName);
      } else {
        _box = Hive.box(_boxName);
      }

      _loadFromBox();

      // Listen to box changes (e.g. from player screen adding songs)
      _box.listenable().addListener(() {
        if (mounted) _loadFromBox();
      });
    } catch (e) {
      debugPrint('Hive init/load error: $e');
      _playlists = {};
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _loadFromBox() {
    final keys = _box.keys.cast<String>().toList();
    final Map<String, List<String>> converted = {};
    for (var key in keys) {
      final val = _box.get(key);
      if (val is List) {
        converted[key] = List<String>.from(val.map((e) => e.toString()));
      }
    }
    setState(() {
      _playlists = converted;
    });
  }

  Future<void> _savePlaylistToBox(String name, List<String> paths) async {
    await _box.put(name, paths);
  }

  Future<void> _deletePlaylistFromBox(String name) async {
    await _box.delete(name);
  }

  // ---------------- Color System ----------------
  Color get _primaryColor => AppPalette.accent;

  Map<String, Color> _getColors(BuildContext context) {
    final dark = isDark(context);
    return {
      'primary': _primaryColor,
      'background': dark ? AppPalette.darkBackground : const Color(0xFFF8F9FD),
      'card': dark ? AppPalette.darkCard : Colors.white,
      'surface': dark ? const Color(0xFF2C2C2C) : const Color(0xFFF0F2F5),
      'onSurface': dark ? Colors.white : Colors.black,
      'outline': dark ? const Color(0xFF404040) : const Color(0xFFE0E0E0),
      'success': dark ? const Color(0xFF66BB6A) : const Color(0xFF4CAF50),
      'warning': dark ? const Color(0xFFFFB74D) : const Color(0xFFFF9800),
      'error': dark ? const Color(0xFFCF6679) : const Color(0xFFB00020),
    };
  }

  // ---------------- playlist actions ----------------
  Future<void> _createPlaylistWithSelected() async {
    final colors = _getColors(context);
    if ((_newPlaylistName ?? '').trim().isEmpty) {
      _showSnackBar('Please enter playlist name', colors['warning']!);
      return;
    }

    final name = _newPlaylistName!.trim();
    if (_playlists.containsKey(name)) {
      final overwrite = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Playlist exists',
              style: TextStyle(color: colors['onSurface'])),
          content: Text('A playlist named "$name" already exists. Overwrite?',
              style: TextStyle(color: colors['onSurface']!.withOpacity(0.7))),
          backgroundColor: colors['card'],
          shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel',
                  style: TextStyle(
                      color: colors['onSurface']!.withOpacity(0.7))),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style:
              ElevatedButton.styleFrom(backgroundColor: colors['primary']),
              child: const Text('Yes', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (overwrite != true) return;
    }

    final selectedPaths = <String>[];
    for (int i = 0; i < widget.audioFiles.length; i++) {
      if (_selected[i]) selectedPaths.add(widget.audioFiles[i].path);
    }

    setState(() => _creating = true);
    await Future.delayed(const Duration(milliseconds: 300));

    await _savePlaylistToBox(name, selectedPaths);

    setState(() {
      _creating = false;
      _newPlaylistName = null;
      _selected = List<bool>.filled(widget.audioFiles.length, false);
    });

    _showSnackBar('Playlist "$name" created', colors['success']!);
  }

  Future<void> _deletePlaylist(String name) async {
    final colors = _getColors(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete playlist',
            style: TextStyle(color: colors['onSurface'])),
        content: Text('Are you sure you want to delete "$name"?',
            style: TextStyle(color: colors['onSurface']!.withOpacity(0.7))),
        backgroundColor: colors['card'],
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel',
                style: TextStyle(
                    color: colors['onSurface']!.withOpacity(0.7))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: colors['error']),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _deletePlaylistFromBox(name);
      _showSnackBar('Deleted "$name"', colors['success']!);
    }
  }

  Future<void> _openManagePlaylist(String name) async {
    await Navigator.push<Map?>(
      // Refresh is handled by Hive listener
      context,
      MaterialPageRoute(
        builder: (_) => ManagePlaylistPage(
          playlistName: name,
          songPaths: List<String>.from(_playlists[name] ?? []),
          allFiles: widget.audioFiles,
          onPlay: widget.onPlay,
          miniPlayer: widget.miniPlayer,
          loadCoverForFile: widget.loadCoverForFile,
          onNavTap: widget.onNavTap,
        ),
      ),
    );
  }

  void _openCreateDialog() {
    final colors = _getColors(context);
    _newPlaylistName = null;
    _selected = List<bool>.filled(widget.audioFiles.length, false);

    // Enter name -> then select songs mode
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: colors['card'],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Create New Playlist',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors['onSurface'],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: colors['surface'],
                  borderRadius: BorderRadius.circular(12),
                  border:
                  Border.all(color: colors['outline']!.withOpacity(0.3)),
                ),
                child: TextField(
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: 'Playlist name',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    hintStyle: TextStyle(
                        color: colors['onSurface']!.withOpacity(0.5)),
                  ),
                  style: TextStyle(
                      color: colors['onSurface'], fontWeight: FontWeight.w500),
                  onChanged: (v) => _newPlaylistName = v,
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                            color: colors['onSurface']!.withOpacity(0.7),
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        if ((_newPlaylistName ?? '').trim().isEmpty) {
                          _showSnackBar('Please enter playlist name',
                              colors['warning']!);
                          return;
                        }
                        Navigator.pop(context);
                        // Enter selection mode
                        setState(() {});
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors['primary'],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text(
                        'Next',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildCoverImage(File file) {
    final colors = _getColors(context);
    return FutureBuilder<Uint8List?>(
      future: widget.loadCoverForFile(file),
      builder: (context, snap) {
        if (snap.hasData && snap.data != null && snap.data!.isNotEmpty) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(snap.data!,
                width: 44, height: 44, fit: BoxFit.cover),
          );
        }
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colors['surface']!.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.music_note,
              color: colors['onSurface']!.withOpacity(0.5), size: 20),
        );
      },
    );
  }

  // ---------------- UI builders ----------------

  Widget _buildSelectionHeader() {
    final colors = _getColors(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors['card'],
        border: Border(
          bottom: BorderSide(color: colors['outline']!.withOpacity(0.1)),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors['primary']!.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.playlist_add, color: colors['primary'], size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Select Songs',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors['onSurface'],
                  ),
                ),
                Text(
                  'For "${_newPlaylistName ?? ''}"',
                  style: TextStyle(
                    color: colors['onSurface']!.withOpacity(0.7),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _newPlaylistName = null;
                _selected = List<bool>.filled(widget.audioFiles.length, false);
              });
            },
            icon: Icon(Icons.close,
                color: colors['onSurface']!.withOpacity(0.7)),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectionList() {
    final colors = _getColors(context);
    final dark = isDark(context);
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: widget.audioFiles.length,
      itemBuilder: (context, i) {
        final f = widget.audioFiles[i];
        final name = p.basenameWithoutExtension(f.path);
        final subtitle = p.basename(p.dirname(f.path));
        final sel = _selected[i];

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => setState(() => _selected[i] = !_selected[i]),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sel
                      ? colors['primary']!.withOpacity(0.08)
                      : colors['card'],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: sel
                          ? colors['primary']!
                          : colors['outline']!.withOpacity(0.1)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(dark ? 0.08 : 0.03),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        border: Border.all(
                            color:
                            sel ? colors['primary']! : colors['outline']!,
                            width: 2),
                        borderRadius: BorderRadius.circular(4),
                        color: sel ? colors['primary'] : Colors.transparent,
                      ),
                      child: sel
                          ? const Icon(Icons.check,
                          size: 14, color: Colors.white)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    _buildCoverImage(File(f.path)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: colors['onSurface'],
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors['onSurface']!.withOpacity(0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSelectionBottomBar() {
    final selectedCount = _selected.where((s) => s).length;
    final colors = _getColors(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors['card'],
        border: Border(
            top: BorderSide(color: colors['outline']!.withOpacity(0.1))),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: colors['primary']!.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '$selectedCount selected',
              style: TextStyle(
                color: colors['primary'],
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () {
              setState(() {
                _selected = List<bool>.filled(widget.audioFiles.length, false);
              });
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
            child: Text('Clear',
                style: TextStyle(
                    color: colors['onSurface']!.withOpacity(0.7))),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: selectedCount > 0 && !_creating
                ? _createPlaylistWithSelected
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: colors['primary'],
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: _creating
                ? SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
                : const Text('Save Playlist',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistsList() {
    final colors = _getColors(context);
    final dark = isDark(context);
    final names = _playlists.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (names.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  color: colors['surface'],
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.playlist_add,
                    size: 48, color: colors['onSurface']!.withOpacity(0.5)),
              ),
              const SizedBox(height: 24),
              Text(
                'No Playlists Yet',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors['onSurface'],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Create your first playlist to organize your favorite songs',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: colors['onSurface']!.withOpacity(0.7),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: names.length,
      itemBuilder: (context, i) {
        final name = names[i];
        final songs = _playlists[name] ?? [];

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openManagePlaylist(name),
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors['card'],
                  borderRadius: BorderRadius.circular(16),
                  border:
                  Border.all(color: colors['outline']!.withOpacity(0.1)),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(dark ? 0.12 : 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            colors['primary']!,
                            colors['primary']!.withOpacity(0.7)
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.queue_music,
                          color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors['onSurface'],
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${songs.length} song${songs.length != 1 ? 's' : ''}',
                            style: TextStyle(
                              color: colors['onSurface']!.withOpacity(0.7),
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                    PopupMenuButton<String>(
                      color: colors['card'],
                      onSelected: (value) async {
                        if (value == 'play') {
                          if (songs.isNotEmpty) {
                            if (widget.onPlay != null) {
                              // Sync playlist context before playing
                              PlaylistContext.setCurrentPlaylist(
                                  List<String>.from(songs),
                                  pageId: 'playlist:$name');
                              // Pass paths to parent to handle setPlaylist & Playback
                              widget.onPlay!(
                                  songs.first, List<String>.from(songs));
                            }
                          } else {
                            _showSnackBar('Playlist has no songs',
                                colors['warning']!);
                          }
                        } else if (value == 'manage') {
                          await _openManagePlaylist(name);
                        } else if (value == 'delete') {
                          await _deletePlaylist(name);
                        }
                      },
                      icon: Icon(Icons.more_vert,
                          color: colors['onSurface']!.withOpacity(0.7)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'play',
                          child: Row(
                            children: [
                              Icon(Icons.play_arrow,
                                  color: colors['primary'], size: 20),
                              const SizedBox(width: 8),
                              Text('Play',
                                  style:
                                  TextStyle(color: colors['onSurface'])),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'manage',
                          child: Row(
                            children: [
                              Icon(Icons.edit,
                                  color: colors['primary'], size: 20),
                              const SizedBox(width: 8),
                              Text('Manage',
                                  style:
                                  TextStyle(color: colors['onSurface'])),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(Icons.delete,
                                  color: colors['error'], size: 20),
                              const SizedBox(width: 8),
                              Text('Delete',
                                  style: TextStyle(color: colors['error'])),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = _getColors(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: colors['background'],
        body: Center(
            child: CircularProgressIndicator(color: colors['primary'])),
      );
    }

    return Scaffold(
      backgroundColor: colors['background'],
      appBar: AppBar(
        title: Text(
          (_newPlaylistName ?? '').isNotEmpty ? 'Select Songs' : 'Playlists',
          style: TextStyle(
            color: colors['onSurface'],
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: isDark(context) ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: colors['onSurface']),
        actions: [
          if ((_newPlaylistName ?? '').isEmpty)
            Container(
              margin: const EdgeInsets.only(right: 8),
              child: IconButton(
                icon: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: colors['primary'],
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 20),
                ),
                onPressed: _openCreateDialog,
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if ((_newPlaylistName ?? '').isNotEmpty) _buildSelectionHeader(),
          if ((_newPlaylistName ?? '').isNotEmpty)
            Expanded(child: _buildSelectionList()),
          if ((_newPlaylistName ?? '').isNotEmpty)
            _buildSelectionBottomBar()
          else
            Expanded(child: _buildPlaylistsList()),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.miniPlayer != null)
            Container(color: colors['background'], child: widget.miniPlayer),
          const BannerAdWidget3(),
        ],
      ),
    );
  }
}

//////////////////////////////////////////////////////////////////////////////
/// ManagePlaylistPage - View & Edit a single playlist
class ManagePlaylistPage extends StatefulWidget {
  final String playlistName;
  final List<String> songPaths;
  final List<FileSystemEntity> allFiles;
  final OnPlayCallback? onPlay;
  final Widget? miniPlayer;
  final Future<Uint8List?> Function(File file) loadCoverForFile;
  final void Function(int index)? onNavTap;

  const ManagePlaylistPage({
    Key? key,
    required this.playlistName,
    required this.songPaths,
    required this.allFiles,
    this.onPlay,
    this.miniPlayer,
    required this.loadCoverForFile,
    this.onNavTap,
  }) : super(key: key);

  @override
  State<ManagePlaylistPage> createState() => _ManagePlaylistPageState();
}

class _ManagePlaylistPageState extends State<ManagePlaylistPage> {
  static const _boxName = 'custom_playlists';

  late Box _box;
  late String _name;
  late List<String> _paths;
  List<bool> _selectAdd = [];
  bool _loading = true;

  final Map<String, Uint8List?> _coverCache = {};

  @override
  void initState() {
    super.initState();
    _name = widget.playlistName;
    _paths = List<String>.from(widget.songPaths);
    _selectAdd = List<bool>.filled(widget.allFiles.length, false);
    _initBox();
  }

  Future<void> _initBox() async {
    if (!Hive.isBoxOpen(_boxName)) {
      _box = await Hive.openBox(_boxName);
    } else {
      _box = Hive.box(_boxName);
    }
    setState(() => _loading = false);
  }

  // ---------------- Color System (Managed) ----------------
  Color get _primaryColor => AppPalette.accent;

  Map<String, Color> _getColors(BuildContext context) {
    final dark = isDark(context);
    return {
      'primary': _primaryColor,
      'background': dark ? AppPalette.darkBackground : const Color(0xFFF8F9FD),
      'card': dark ? AppPalette.darkCard : Colors.white,
      'surface': dark ? const Color(0xFF2C2C2C) : const Color(0xFFF0F2F5),
      'onSurface': dark ? Colors.white : Colors.black,
      'outline': dark ? const Color(0xFF404040) : const Color(0xFFE0E0E0),
      'success': dark ? const Color(0xFF66BB6A) : const Color(0xFF4CAF50),
      'error': dark ? const Color(0xFFCF6679) : const Color(0xFFB00020),
    };
  }

  // Helper: Check if song currently playing (highlight)
  bool _isPathCurrentlyPlaying(String path) {
    try {
      final currentPath = PlaylistContext.currentPathNotifier.value;
      final currentPageId = PlaylistContext.getCurrentPageId();
      return currentPath != null &&
          currentPath == path &&
          currentPageId == 'playlist:$_name';
    } catch (_) {
      return false;
    }
  }

  // NOTE: Assuming PlaybackState is available via global import or scope
  bool get _globalIsPlaying {
    // This assumes PlaybackState is defined in one of the imports
    // If not, you may need to import list_page.dart where PlaybackState is defined
    // However, list_page.dart might import THIS file, causing a cycle.
    // Ideally, PlaybackState should be in a separate shared file.
    // For now, we will use a try-catch to simulate safe access if available.
    return false; // Placeholder if PlaybackState isn't globally reachable
  }

  Future<void> _save() async {
    final keys = _box.keys.cast<String>().toList();
    final Map<String, List<String>> allPlaylists = {};
    for (var k in keys) {
      allPlaylists[k] = List<String>.from(_box.get(k) as List);
    }

    allPlaylists.remove(widget.playlistName); // remove old key if renamed
    allPlaylists[_name] = _paths;

    await _box.put(_name, _paths);
    if (_name != widget.playlistName) {
      await _box.delete(widget.playlistName);
    }

    _showSnackBar('Playlist saved', _getColors(context)['success']!);
    Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final colors = _getColors(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Delete playlist',
            style: TextStyle(color: colors['onSurface'])),
        content: Text('Delete "$_name"?',
            style: TextStyle(color: colors['onSurface']!.withOpacity(0.7))),
        backgroundColor: colors['card'],
        shape:
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text('Cancel',
                style: TextStyle(
                    color: colors['onSurface']!.withOpacity(0.7))),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            style: ElevatedButton.styleFrom(backgroundColor: colors['error']),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _box.delete(_name);
      _showSnackBar('Deleted "$_name"', _getColors(context)['success']!);
      Navigator.of(context).pop();
    }
  }

  Future<void> _addSelectedToPlaylist() async {
    final toAdd = <String>[];
    for (int i = 0; i < widget.allFiles.length; i++) {
      if (_selectAdd[i]) {
        final pth = widget.allFiles[i].path;
        if (!_paths.contains(pth)) toAdd.add(pth);
      }
    }
    if (toAdd.isEmpty) {
      _showSnackBar('Select songs to add',
          _getColors(context)['onSurface']!.withOpacity(0.7));
      return;
    }
    setState(() {
      _paths.addAll(toAdd);
      _selectAdd = List<bool>.filled(widget.allFiles.length, false);
    });
    // Auto save on add
    await _box.put(_name, _paths);
    _showSnackBar('Songs added', _getColors(context)['success']!);
  }

  Future<void> _renamePlaylist() async {
    final controller = TextEditingController(text: _name);
    final colors = _getColors(context);
    final newName = await showDialog<String?>(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: colors['card'],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Rename Playlist',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors['onSurface'],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: colors['surface'],
                  borderRadius: BorderRadius.circular(12),
                  border:
                  Border.all(color: colors['outline']!.withOpacity(0.3)),
                ),
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: 'New name',
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    hintStyle: TextStyle(
                        color: colors['onSurface']!.withOpacity(0.5)),
                  ),
                  style: TextStyle(
                      color: colors['onSurface'], fontWeight: FontWeight.w500),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(c, null),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(
                        'Cancel',
                        style: TextStyle(
                            color: colors['onSurface']!.withOpacity(0.7),
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(c, controller.text.trim()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors['primary'],
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text(
                        'Rename',
                        style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != _name) {
      if (_box.containsKey(newName)) {
        _showSnackBar(
            'A playlist with that name exists', _getColors(context)['error']!);
        return;
      }
      // Delete old key, add new key
      await _box.delete(_name);
      await _box.put(newName, _paths);
      setState(() => _name = newName);
      _showSnackBar('Renamed', _getColors(context)['success']!);
    }
  }

  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Widget _buildCoverImage(String path) {
    final colors = _getColors(context);
    final key = path;
    if (_coverCache.containsKey(key)) {
      final cached = _coverCache[key];
      if (cached != null && cached.isNotEmpty) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child:
          Image.memory(cached, width: 44, height: 44, fit: BoxFit.cover),
        );
      }
    }

    return FutureBuilder<Uint8List?>(
      future: widget.loadCoverForFile(File(path)),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.done &&
            snap.hasData &&
            snap.data != null) {
          final bytes = snap.data!;
          _coverCache[key] = bytes;
          if (bytes.isNotEmpty) {
            return ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(bytes,
                  width: 44, height: 44, fit: BoxFit.cover),
            );
          }
        }
        // placeholder
        return Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: colors['surface']!.withOpacity(0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.music_note,
              color: colors['onSurface']!.withOpacity(0.5), size: 20),
        );
      },
    );
  }

  Widget _buildSongItem(int i) {
    final colors = _getColors(context);
    final dark = isDark(context);
    final path = _paths[i];
    final name = p.basenameWithoutExtension(path);
    final folder = p.basename(p.dirname(path));

    final playing = _isPathCurrentlyPlaying(path);
    // Note: _globalIsPlaying is stubbed to false to avoid import cycles if not available.
    // If you need real-time play state, access PlaybackState directly if imported.
    final isPlaying = playing; // && _globalIsPlaying;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: playing
                  ? colors['primary']!.withOpacity(0.08)
                  : colors['card'],
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: playing
                    ? colors['primary']!.withOpacity(0.3)
                    : colors['outline']!.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(dark ? 0.08 : 0.04),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              children: [
                _buildCoverImage(path),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: colors['onSurface'],
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors['onSurface']!.withOpacity(0.7),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // PLAY BUTTON
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colors['surface'],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: isPlaying
                            ? const Icon(Icons.equalizer, size: 18)
                            : const Icon(Icons.play_arrow, size: 18),
                        onPressed: () {
                          if (widget.onPlay != null) {
                            PlaylistContext.setCurrentPlaylist(
                                List<String>.from(_paths),
                                pageId: 'playlist:$_name');
                            widget.onPlay!(path, List<String>.from(_paths));
                          }
                          setState(() {});
                        },
                        color: colors['primary'],
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // REMOVE BUTTON
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: colors['surface'],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(
                        icon: const Icon(Icons.remove, size: 18),
                        onPressed: () async {
                          setState(() => _paths.removeAt(i));
                          await _box.put(_name, _paths);
                        },
                        color: colors['error'],
                        padding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAddSongsSection() {
    final colors = _getColors(context);
    final dark = isDark(context);
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors['card'],
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors['outline']!.withOpacity(0.1)),
      ),
      child: ExpansionTile(
        collapsedBackgroundColor: colors['card'],
        backgroundColor: colors['card'],
        iconColor: colors['primary'],
        title: Text(
          'Add Songs to Playlist',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: colors['onSurface'],
            fontSize: 16,
          ),
        ),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: colors['primary']!.withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Icons.add, color: colors['primary'], size: 20),
        ),
        children: [
          SizedBox(
            height: 280,
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: widget.allFiles.length,
              itemBuilder: (context, i) {
                final f = widget.allFiles[i];
                final sel = _selectAdd[i];
                final name = p.basenameWithoutExtension(f.path);
                final folder = p.basename(p.dirname(f.path));
                final already = _paths.contains(f.path);

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: already
                          ? null
                          : () => setState(() => _selectAdd[i] = !_selectAdd[i]),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: already
                              ? colors['success']!.withOpacity(0.06)
                              : colors['card'],
                          borderRadius: BorderRadius.circular(8),
                          border: already
                              ? Border.all(
                              color: colors['success']!.withOpacity(0.3))
                              : Border.all(
                              color: colors['outline']!.withOpacity(0.1)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black
                                  .withOpacity(dark ? 0.06 : 0.03),
                              blurRadius: 8,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: already
                                      ? colors['success']!
                                      : (sel
                                      ? colors['primary']!
                                      : colors['outline']!),
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(4),
                                color: sel
                                    ? colors['primary']
                                    : Colors.transparent,
                              ),
                              child: already
                                  ? Icon(Icons.check,
                                  size: 14, color: colors['success'])
                                  : (sel
                                  ? const Icon(Icons.check,
                                  size: 14, color: Colors.white)
                                  : null),
                            ),
                            const SizedBox(width: 12),
                            _buildCoverImage(f.path),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: colors['onSurface'],
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    folder,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                      colors['onSurface']!.withOpacity(0.7),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (already)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: colors['success']!.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Added',
                                  style: TextStyle(
                                    color: colors['success'],
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                ElevatedButton(
                  onPressed: _addSelectedToPlaylist,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors['primary'],
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Add Selected',
                      style: TextStyle(color: Colors.white)),
                ),
                const SizedBox(width: 12),
                TextButton(
                  onPressed: () => setState(() =>
                  _selectAdd = List<bool>.filled(widget.allFiles.length, false)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  child: Text('Clear',
                      style: TextStyle(
                          color: colors['onSurface']!.withOpacity(0.7))),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = _getColors(context);
    if (_loading) {
      return Scaffold(
        backgroundColor: colors['background'],
        body: Center(
            child: CircularProgressIndicator(color: colors['primary'])),
      );
    }

    return Scaffold(
      backgroundColor: colors['background'],
      appBar: AppBar(
        title: Text(
          _name,
          style: TextStyle(
            color: colors['onSurface'],
            fontWeight: FontWeight.w600,
            fontSize: 20,
          ),
        ),
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: isDark(context) ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: colors['onSurface']),
        actions: [
          IconButton(
            icon: Icon(Icons.edit, color: colors['primary']),
            onPressed: _renamePlaylist,
          ),
          IconButton(
            icon: Icon(Icons.save, color: colors['primary']),
            onPressed: _save,
          ),
          IconButton(
            icon: Icon(Icons.delete, color: colors['error']),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(
        children: [
          // Playlist info card
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  colors['primary']!,
                  colors['primary']!.withOpacity(0.8)
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.queue_music,
                      color: Colors.white, size: 32),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${_paths.length} song${_paths.length != 1 ? 's' : ''}',
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.8),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Songs list
          Expanded(
            child: _paths.isEmpty
                ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.music_off,
                      size: 64,
                      color: colors['onSurface']!.withOpacity(0.5)),
                  const SizedBox(height: 16),
                  Text(
                    'No songs in this playlist',
                    style: TextStyle(
                      fontSize: 16,
                      color: colors['onSurface']!.withOpacity(0.7),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Add songs using the section below',
                    style: TextStyle(
                      color: colors['onSurface']!.withOpacity(0.7),
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
                : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _paths.length,
              itemBuilder: (context, i) => _buildSongItem(i),
            ),
          ),

          // Add songs section
          _buildAddSongsSection(),
        ],
      ),
      // FIX: Wrapped miniPlayer inside a Column with MainAxisSize.min
      bottomNavigationBar: widget.miniPlayer != null
          ? Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            color: colors['background'],
            child: widget.miniPlayer,
          ),
          const BannerAdWidget(),
        ],
      )
          : const BannerAdWidget(),
    );
  }
}