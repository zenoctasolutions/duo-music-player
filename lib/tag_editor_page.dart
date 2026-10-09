// lib/tag_editor_page.dart
//
// "Edit tags" screen: title, artist, album, album artist, genre, year,
// track number and cover art. Saving rewrites the file's tags with
// ffmpeg (audio untouched) after Android asks the user for permission.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_palette.dart';
import 'tag_editor_service.dart';
import 'ad_widgets.dart';

class TagEditorPage extends StatefulWidget {
  final String path;
  final bool isDark;

  /// Called after a successful save so the library can refresh the song.
  final void Function(String path)? onSaved;
  const TagEditorPage({super.key, required this.path, required this.isDark, this.onSaved});

  @override
  State<TagEditorPage> createState() => _TagEditorPageState();
}

class _TagEditorPageState extends State<TagEditorPage> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _album = TextEditingController();
  final _albumArtist = TextEditingController();
  final _genre = TextEditingController();
  final _year = TextEditingController();
  final _track = TextEditingController();

  Uint8List? _cover;
  String? _newCoverPath;
  bool _removeCover = false;
  bool _loading = true;
  bool _saving = false;

  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _card => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _text => widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _sub => widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final (tags, cover) = await TagEditorService.read(widget.path);
    if (!mounted) return;
    _title.text = tags.title;
    _artist.text = tags.artist;
    _album.text = tags.album;
    _albumArtist.text = tags.albumArtist;
    _genre.text = tags.genre;
    _year.text = tags.year;
    _track.text = tags.track;
    setState(() {
      _cover = cover;
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final c in [_title, _artist, _album, _albumArtist, _genre, _year, _track]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickCover() async {
    final path = await TagEditorService.pickCoverImage();
    if (path == null || !mounted) return;
    final bytes = await File(path).readAsBytes();
    setState(() {
      _newCoverPath = path;
      _cover = bytes;
      _removeCover = false;
    });
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    final year = _year.text.trim();
    if (year.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(year)) {
      _snack('Year should be 4 digits, e.g. 2024');
      return;
    }
    if (_track.text.trim().isNotEmpty && int.tryParse(_track.text.trim()) == null) {
      _snack('Track should be a number');
      return;
    }
    setState(() => _saving = true);
    final err = await TagEditorService.save(
      widget.path,
      SongTags(
        title: _title.text,
        artist: _artist.text,
        album: _album.text,
        albumArtist: _albumArtist.text,
        genre: _genre.text,
        year: year,
        track: _track.text,
      ),
      coverPath: _newCoverPath,
      removeCover: _removeCover,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (err != null) {
      _snack(err);
      return;
    }
    widget.onSaved?.call(widget.path);
    _snack('Tags saved');
    Navigator.pop(context, true);
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  Widget _field(String label, TextEditingController c, {TextInputType? type, IconData? icon}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: c,
          keyboardType: type,
          style: TextStyle(color: _text),
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: _sub),
            prefixIcon: icon == null ? null : Icon(icon, color: _sub, size: 20),
            filled: true,
            fillColor: _card,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppPalette.accent)),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.accent;
    final coverEditable = TagEditorService.canEditCover(widget.path);
    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        title: const Text('Edit tags'),
        actions: [
          if (!_loading)
            _saving
                ? const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                : TextButton(onPressed: _save, child: Text('Save', style: TextStyle(color: accent, fontWeight: FontWeight.w700, fontSize: 16))),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
              Center(
                child: Column(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      width: 150,
                      height: 150,
                      color: accent.withOpacity(0.12),
                      child: (_cover != null && !_removeCover)
                          ? Image.memory(_cover!, fit: BoxFit.cover)
                          : Icon(Icons.music_note_rounded, size: 64, color: accent),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (coverEditable)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton.icon(
                        onPressed: _pickCover,
                        icon: Icon(Icons.image_outlined, color: accent),
                        label: Text('Change cover', style: TextStyle(color: accent)),
                      ),
                      if (_cover != null && !_removeCover)
                        TextButton.icon(
                          onPressed: () => setState(() {
                            _removeCover = true;
                            _newCoverPath = null;
                          }),
                          icon: Icon(Icons.hide_image_outlined, color: _sub),
                          label: Text('Remove', style: TextStyle(color: _sub)),
                        ),
                    ])
                  else
                    Text('Cover art editing isn\'t supported for ${p.extension(widget.path).toUpperCase().replaceFirst('.', '')} files',
                        style: TextStyle(color: _sub, fontSize: 12)),
                ]),
              ),
              const SizedBox(height: 16),
              _field('Title', _title, icon: Icons.title_rounded),
              _field('Artist', _artist, icon: Icons.person_outline_rounded),
              _field('Album', _album, icon: Icons.album_outlined),
              _field('Album artist', _albumArtist, icon: Icons.people_outline_rounded),
              _field('Genre', _genre, icon: Icons.category_outlined),
              Row(children: [
                Expanded(child: _field('Year', _year, type: TextInputType.number, icon: Icons.calendar_today_outlined)),
                const SizedBox(width: 12),
                Expanded(child: _field('Track #', _track, type: TextInputType.number, icon: Icons.format_list_numbered_rounded)),
              ]),
              const SizedBox(height: 4),
              Text(
                'Saving rewrites only the tags — the audio is copied untouched. Android will ask you to allow '
                'Duo Music Player to modify this file.',
                style: TextStyle(color: _sub, fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(widget.path, style: TextStyle(color: _sub.withOpacity(0.7), fontSize: 11)),
            ]),
    );
  }
}
