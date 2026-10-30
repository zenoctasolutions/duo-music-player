// lib/create_playlist_page.dart
import 'dart:async';
import 'dart:convert';
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
import 'library/title_cleaner.dart';
import 'library/library_motion.dart';
import 'library/m3u_service.dart';
import 'library/widgets/playlist_mosaic.dart';
import 'motion/motion_kit.dart';
import 'package:flutter/services.dart' show Clipboard;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

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
      'surface': dark ? AppPalette.darkCard : const Color(0xFFF0F2F5),
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
          IconButton(tooltip: 'Cancel', 
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
        final name = TitleCleaner.title(null, path: f.path);
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

  Widget _newPlaylistTile(Map<String, Color> colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: 'New playlist',
        child: PressScale(
          onTap: _openCreateDialog,
          child: Container(
            constraints: const BoxConstraints(minHeight: 72),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colors['primary']!.withOpacity(0.08),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: colors['primary']!.withOpacity(0.35)),
            ),
            child: Row(children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: colors['primary'],
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.add_rounded, color: Colors.white, size: 32),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text('New playlist',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: colors['primary'])),
              ),
              Icon(Icons.chevron_right_rounded, color: colors['primary']),
            ]),
          ),
        ),
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
                  gradient: LinearGradient(colors: [
                    colors['primary']!.withOpacity(0.25),
                    colors['primary']!.withOpacity(0.06)
                  ], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.queue_music_rounded,
                    size: 56, color: colors['primary']),
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
              const SizedBox(height: 20),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: colors['primary'],
                  minimumSize: const Size(48, 48),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                ),
                onPressed: _openCreateDialog,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Create playlist'),
              ),
              TextButton.icon(
                onPressed: _importM3u,
                icon: const Icon(Icons.file_download_outlined),
                label: const Text('Import M3U'),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: names.length + 1,
      itemBuilder: (context, idx) {
        if (idx == 0) return _newPlaylistTile(colors);
        final i = idx - 1;
        final name = names[i];
        final songs = _playlists[name] ?? [];

        return FadeSlideIn(
          index: i < 8 ? i : 0,
          child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => _openManagePlaylist(name),
              borderRadius: BorderRadius.circular(22),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors['card'],
                  borderRadius: BorderRadius.circular(22),
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
                    PlaylistMosaic(
                      paths: songs,
                      loadCover: widget.loadCoverForFile,
                      placeholder: playlistGradientFor(name),
                      size: 64,
                      radius: 14,
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
                              fontSize: 13.5,
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
                        } else if (value == 'export') {
                          await _exportM3u(name);
                        } else if (value == 'share') {
                          await _sharePlaylist(name);
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
                          value: 'export',
                          child: Row(
                            children: [
                              Icon(Icons.file_upload_outlined,
                                  color: colors['primary'], size: 20),
                              const SizedBox(width: 8),
                              Text('Export as M3U',
                                  style:
                                  TextStyle(color: colors['onSurface'])),
                            ],
                          ),
                        ),
                        PopupMenuItem(
                          value: 'share',
                          child: Row(
                            children: [
                              Icon(Icons.share_outlined,
                                  color: colors['primary'], size: 20),
                              const SizedBox(width: 8),
                              Text('Share playlist',
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
          ),
        );
      },
    );
  }

  // ---------------- M3U export / share / import ----------------
  String _m3uText(String name, List<String> songs) =>
      M3uService.encode(name, songs);

  String _safeFileName(String name) {
    final n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_').trim();
    return n.isEmpty ? 'playlist' : n;
  }

  Future<void> _exportM3u(String name) async {
    final colors = _getColors(context);
    final songs = _playlists[name] ?? [];
    if (songs.isEmpty) {
      _showSnackBar('Playlist has no songs', colors['warning']!);
      return;
    }
    try {
      // App-specific storage: no storage permission needed (scoped storage).
      Directory dir;
      try {
        dir = (await getExternalStorageDirectory()) ??
            await getApplicationDocumentsDirectory();
      } catch (_) {
        dir = await getApplicationDocumentsDirectory();
      }
      final file = File(p.join(dir.path, '${_safeFileName(name)}.m3u8'));
      await file.writeAsString(_m3uText(name, songs), flush: true);
      if (!mounted) return;
      _showSnackBar('Saved ${p.basename(file.path)}', colors['success']!);
      await Share.shareXFiles([XFile(file.path, mimeType: 'audio/x-mpegurl')],
          text: name);
    } catch (e) {
      if (mounted) _showSnackBar('Export failed: $e', colors['error']!);
    }
  }

  Future<void> _sharePlaylist(String name) async {
    final colors = _getColors(context);
    final songs = _playlists[name] ?? [];
    if (songs.isEmpty) {
      _showSnackBar('Playlist has no songs', colors['warning']!);
      return;
    }
    try {
      final b = StringBuffer('$name (${songs.length} songs)\n');
      for (var i = 0; i < songs.length; i++) {
        b.writeln('${i + 1}. ${TitleCleaner.title(null, path: songs[i])}');
      }
      await Share.share(b.toString().trimRight(), subject: name);
    } catch (e) {
      if (mounted) _showSnackBar('Share failed: $e', colors['error']!);
    }
  }

  /// Find playlist files in the places apps and users commonly put them.
  /// (No system file picker is wired for non-image files, so this scans.)
  Future<List<File>> _scanForM3u() async {
    final dirs = <String>{};
    try {
      dirs.add((await getApplicationDocumentsDirectory()).path);
      final ext = await getExternalStorageDirectory();
      if (ext != null) dirs.add(ext.path);
    } catch (_) {}
    for (final d in ['Download', 'Documents', 'Music', 'Playlists']) {
      dirs.add('/storage/emulated/0/$d');
    }
    final found = <String, File>{};
    for (final d in dirs) {
      try {
        final dir = Directory(d);
        if (!await dir.exists()) continue;
        await for (final e in dir.list(recursive: true, followLinks: false)
            .handleError((_) {})) {
          if (e is File) {
            final l = e.path.toLowerCase();
            if (l.endsWith('.m3u') || l.endsWith('.m3u8')) found[e.path] = e;
          }
          if (found.length > 200) break;
        }
      } catch (_) {}
    }
    return found.values.toList()
      ..sort((a, b) => p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase()));
  }

  Future<void> _importM3u() async {
    final colors = _getColors(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: colors['card'],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          ListTile(
            leading: Icon(Icons.search, color: colors['primary']),
            title: Text('Find .m3u files on device',
                style: TextStyle(color: colors['onSurface'])),
            subtitle: Text('Downloads, Documents, Music, app folder',
                style: TextStyle(
                    color: colors['onSurface']!.withOpacity(0.6))),
            onTap: () => Navigator.pop(ctx, 'scan'),
          ),
          ListTile(
            leading: Icon(Icons.content_paste, color: colors['primary']),
            title: Text('Paste from clipboard',
                style: TextStyle(color: colors['onSurface'])),
            onTap: () => Navigator.pop(ctx, 'paste'),
          ),
          ListTile(
            leading: Icon(Icons.edit_note, color: colors['primary']),
            title: Text('Enter file path',
                style: TextStyle(color: colors['onSurface'])),
            onTap: () => Navigator.pop(ctx, 'path'),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
    if (choice == null || !mounted) return;

    try {
      String? content;
      String baseDir = '/storage/emulated/0/Music';
      String suggested = 'Imported playlist';
      if (choice == 'paste') {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        content = data?.text;
        if (content == null || !content.contains(RegExp(r'\S'))) {
          if (mounted) _showSnackBar('Clipboard is empty', colors['warning']!);
          return;
        }
      } else {
        File? file;
        if (choice == 'scan') {
          if (!mounted) return;
          showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => const Center(child: CircularProgressIndicator()));
          final files = await _scanForM3u();
          if (!mounted) return;
          Navigator.of(context, rootNavigator: true).pop();
          if (files.isEmpty) {
            _showSnackBar('No .m3u/.m3u8 files found. Try pasting or entering a path.',
                colors['warning']!);
            return;
          }
          file = await _pickFromList(files);
        } else {
          final path = await _askText('Playlist file path', '/storage/emulated/0/Download/list.m3u8');
          if (path != null && path.trim().isNotEmpty) file = File(path.trim());
        }
        if (file == null || !mounted) return;
        if (!await file.exists()) {
          if (mounted) _showSnackBar('File not found', colors['error']!);
          return;
        }
        final bytes = await file.readAsBytes();
        content = utf8.decode(bytes, allowMalformed: true);
        baseDir = p.dirname(file.path);
        suggested = p.basenameWithoutExtension(file.path);
      }
      if (!mounted) return;
      suggested = M3uService.playlistNameFromContent(content) ?? suggested;
      final entries = M3uService.parse(content, baseDir: baseDir);
      if (entries.isEmpty) {
        _showSnackBar('No tracks found in that playlist', colors['warning']!);
        return;
      }
      final res = M3uService.resolve(
          entries, widget.audioFiles.map((f) => f.path));
      await _showImportPreview(suggested, res);
    } catch (e) {
      if (mounted) _showSnackBar('Import failed: $e', colors['error']!);
    }
  }

  Future<File?> _pickFromList(List<File> files) {
    final colors = _getColors(context);
    return showDialog<File>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors['card'],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Choose playlist file',
            style: TextStyle(color: colors['onSurface'])),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: files.length,
            itemBuilder: (_, i) => ListTile(
              dense: true,
              leading: Icon(Icons.queue_music, color: colors['primary']),
              title: Text(p.basename(files[i].path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: colors['onSurface'])),
              subtitle: Text(p.dirname(files[i].path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11,
                      color: colors['onSurface']!.withOpacity(0.5))),
              onTap: () => Navigator.pop(ctx, files[i]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: TextStyle(
                      color: colors['onSurface']!.withOpacity(0.7)))),
        ],
      ),
    );
  }

  Future<String?> _askText(String title, String hint, {String initial = ''}) async {
    final colors = _getColors(context);
    final ctrl = TextEditingController(text: initial);
    try {
      return await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors['card'],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(title, style: TextStyle(color: colors['onSurface'])),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: colors['onSurface']),
            decoration: InputDecoration(hintText: hint),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel',
                    style: TextStyle(
                        color: colors['onSurface']!.withOpacity(0.7)))),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              style: ElevatedButton.styleFrom(backgroundColor: colors['primary']),
              child: const Text('OK', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
  }

  Future<void> _showImportPreview(String suggested, M3uResolution res) async {
    final colors = _getColors(context);
    final ctrl = TextEditingController(text: suggested);
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors['card'],
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Import playlist',
              style: TextStyle(color: colors['onSurface'])),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  style: TextStyle(color: colors['onSurface']),
                  decoration: const InputDecoration(labelText: 'Playlist name'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Matched ${res.matched.length} / Missing ${res.unresolved.length}',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: res.matched.isEmpty
                          ? colors['error']
                          : colors['success']),
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in res.matched.take(50))
                        _previewRow(colors, Icons.check_circle,
                            colors['success']!, M3uService.displayTitle(m.entry)),
                      for (final e in res.unresolved.take(50))
                        _previewRow(colors, Icons.help_outline,
                            colors['warning']!, M3uService.displayTitle(e)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text('Cancel',
                    style: TextStyle(
                        color: colors['onSurface']!.withOpacity(0.7)))),
            ElevatedButton(
              onPressed:
                  res.matched.isEmpty ? null : () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: colors['primary']),
              child: const Text('Create', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      var name = ctrl.text.trim();
      if (name.isEmpty) name = 'Imported playlist';
      if (_playlists.containsKey(name)) {
        var n = 2;
        while (_playlists.containsKey('$name ($n)')) {
          n++;
        }
        name = '$name ($n)';
      }
      await _savePlaylistToBox(name, res.paths);
      if (mounted) {
        _showSnackBar(
            'Imported "$name" (${res.matched.length} songs)', colors['success']!);
      }
    } catch (e) {
      if (mounted) _showSnackBar('Import failed: $e', colors['error']!);
    } finally {
      ctrl.dispose();
    }
  }

  Widget _previewRow(Map<String, Color> colors, IconData icon, Color c, String t) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(icon, size: 16, color: c),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    color: colors['onSurface']!.withOpacity(0.85))),
          ),
        ]),
      );

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
            PressScale(
              passive: true,
              child: IconButton(
                tooltip: 'Import M3U',
                icon: Icon(Icons.file_download_outlined,
                    color: colors['onSurface']),
                onPressed: _importM3u,
              ),
            ),
          if ((_newPlaylistName ?? '').isEmpty)
            Container(
              margin: const EdgeInsets.only(right: 8),
              child: IconButton(tooltip: 'New playlist', 
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
      'surface': dark ? AppPalette.darkCard : const Color(0xFFF0F2F5),
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
    final name = TitleCleaner.title(null, path: path);
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
          borderRadius: BorderRadius.circular(18),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
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
                        maxLines: 2,
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
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: colors['surface'],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(tooltip: 'Play', 
                        icon: isPlaying
                            ? EqualizerBars(color: colors['primary']!, playing: true, size: 18)
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
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: colors['surface'],
                        shape: BoxShape.circle,
                      ),
                      child: IconButton(tooltip: 'Remove from playlist', 
                        icon: const Icon(Icons.remove, size: 18),
                        onPressed: () async {
                          setState(() => _paths.removeAt(i));
                          await _box.put(_name, _paths);
                        },
                        color: colors['error'],
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    ReorderableDragStartListener(
                      index: i,
                      child: Semantics(
                        label: 'Drag to reorder',
                        child: SizedBox(
                          width: 40,
                          height: 48,
                          child: Icon(Icons.drag_handle_rounded,
                              color: colors['onSurface']!.withOpacity(0.55)),
                        ),
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

  Widget _buildHero(Map<String, Color> colors) {
    final grad = playlistGradientFor(_name);
    Widget btn(String label, IconData icon, bool filled, VoidCallback? onTap) => Expanded(
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
                  Icon(icon, size: 22, color: filled ? grad.last : Colors.white),
                  const SizedBox(width: 6),
                  Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: filled ? grad.last : Colors.white)),
                ]),
              ),
            ),
          ),
        );
    return FadeSlideIn(
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [grad.first, grad.last],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Column(children: [
          Row(children: [
            PlaylistMosaic(
              paths: _paths,
              loadCover: widget.loadCoverForFile,
              placeholder: [Colors.white.withOpacity(0.25), Colors.white.withOpacity(0.1)],
              size: 88,
              radius: 18,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_paths.length} song${_paths.length != 1 ? 's' : ''}',
                    style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ]),
          if (_paths.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(children: [
              btn('Play', Icons.play_arrow_rounded, true, () => _playAll(false)),
              const SizedBox(width: 10),
              btn('Shuffle', Icons.shuffle_rounded, false, () => _playAll(true)),
            ]),
          ],
        ]),
      ),
    );
  }

  void _playAll(bool shuffle) {
    if (widget.onPlay == null || _paths.isEmpty) return;
    final list = List<String>.from(_paths);
    if (shuffle) list.shuffle();
    PlaylistContext.setCurrentPlaylist(List<String>.from(list), pageId: 'playlist:$_name');
    widget.onPlay!(list.first, list);
    setState(() {});
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
                final name = TitleCleaner.title(null, path: f.path);
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
          IconButton(tooltip: 'Rename playlist', 
            icon: Icon(Icons.edit, color: colors['primary']),
            onPressed: _renamePlaylist,
          ),
          IconButton(tooltip: 'Save', 
            icon: Icon(Icons.save, color: colors['primary']),
            onPressed: _save,
          ),
          IconButton(tooltip: 'Delete playlist', 
            icon: Icon(Icons.delete, color: colors['error']),
            onPressed: _delete,
          ),
        ],
      ),
      body: Column(
        children: [
          // Hero: mosaic + actions
          _buildHero(colors),

          // Songs list
          Expanded(
            child: _paths.isEmpty
                ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: colors['primary']!.withOpacity(0.12),
                      ),
                      child: Icon(Icons.library_music_rounded, size: 46, color: colors['primary']),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'No songs in this playlist',
                      style: TextStyle(
                        fontSize: 17,
                        color: colors['onSurface'],
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Pick some tracks from the section below to get started',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors['onSurface']!.withOpacity(0.7), fontSize: 14),
                    ),
                    const SizedBox(height: 14),
                    Icon(Icons.keyboard_double_arrow_down_rounded, color: colors['primary']),
                  ],
                ),
              ),
            )
                : ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              buildDefaultDragHandles: false,
              itemCount: _paths.length,
              onReorder: (oldIndex, newIndex) async {
                if (newIndex > oldIndex) newIndex -= 1;
                setState(() {
                  final item = _paths.removeAt(oldIndex);
                  _paths.insert(newIndex, item);
                });
                await _box.put(_name, _paths);
              },
              proxyDecorator: (child, index, anim) => Material(
                color: Colors.transparent,
                elevation: 6,
                borderRadius: BorderRadius.circular(18),
                child: child,
              ),
              itemBuilder: (context, i) => KeyedSubtree(
                key: ValueKey('${_paths[i]}#$i'),
                child: _buildSongItem(i),
              ),
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