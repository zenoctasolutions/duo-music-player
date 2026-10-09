// lib/library_filters_page.dart
//
// Settings → Library filters: hide short clips (voice notes, call
// recordings, notification sounds) and exclude whole folders from the
// library. Backed by LibraryFilter (library_service.dart); the library
// rescans automatically when the filter changes.

import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'library_service.dart';
import 'ad_widgets.dart';
import 'settings_page.dart' show SettingsColors;

class LibraryFiltersPage extends StatefulWidget {
  final bool isDark;
  const LibraryFiltersPage({super.key, required this.isDark});

  @override
  State<LibraryFiltersPage> createState() => _LibraryFiltersPageState();
}

class _LibraryFiltersPageState extends State<LibraryFiltersPage> {
  SettingsColors get c => SettingsColors(widget.isDark);

  List<FolderStat>? _folders;
  late Set<String> _excluded;
  late int _minDuration;

  @override
  void initState() {
    super.initState();
    _excluded = Set.of(LibraryFilter.excludedFolders);
    _minDuration = LibraryFilter.minDurationSec;
    _loadFolders();
  }

  Future<void> _loadFolders() async {
    final list = await LibraryFilter.scanFolders();
    if (mounted) setState(() => _folders = list);
  }

  String _durationLabel(int s) => s == 0 ? 'Off' : (s < 60 ? '${s}s' : '${s ~/ 60} min');

  Future<void> _setMin(int s) async {
    setState(() => _minDuration = s);
    await LibraryFilter.setMinDuration(s);
  }

  Future<void> _toggleFolder(String path, bool include) async {
    setState(() {
      if (include) {
        _excluded.remove(path);
      } else {
        _excluded.add(path);
      }
    });
    await LibraryFilter.setExcluded(_excluded);
  }

  /// Folders whose name suggests non-music audio — surfaced as a hint.
  bool _looksLikeClutter(String path) {
    final l = path.toLowerCase();
    return l.contains('voice notes') ||
        l.contains('whatsapp audio') ||
        l.contains('call') && l.contains('record') ||
        l.contains('/recordings') ||
        l.contains('/notifications') ||
        l.contains('/ringtones') ||
        l.contains('/alarms') ||
        l.contains('telegram');
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.accent;
    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: c.backgroundColor,
      appBar: AppBar(
        title: const Text('Library filters'),
        backgroundColor: c.appBarBackground,
        foregroundColor: c.appBarForeground,
        elevation: 0,
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: c.cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.divider)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Hide short audio', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700, fontSize: 16)),
            const SizedBox(height: 2),
            Text('Skip clips shorter than this — voice notes, call recordings, notification sounds.',
                style: TextStyle(color: c.secondaryText, fontSize: 13)),
            const SizedBox(height: 12),
            Wrap(spacing: 8, children: [
              for (final s in LibraryFilter.minDurationChoices)
                ChoiceChip(
                  label: Text(_durationLabel(s)),
                  selected: _minDuration == s,
                  selectedColor: accent.withOpacity(0.18),
                  labelStyle: TextStyle(color: _minDuration == s ? accent : c.primaryText, fontWeight: _minDuration == s ? FontWeight.w700 : FontWeight.normal),
                  onSelected: (_) => _setMin(s),
                ),
            ]),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text('Folders', style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w700, fontSize: 16))),
          if (_excluded.isNotEmpty)
            TextButton(
              onPressed: () async {
                setState(() => _excluded.clear());
                await LibraryFilter.setExcluded(_excluded);
              },
              child: Text('Show all', style: TextStyle(color: accent)),
            ),
        ]),
        Text('Untick a folder to hide its songs from the library.', style: TextStyle(color: c.secondaryText, fontSize: 13)),
        const SizedBox(height: 8),
        if (_folders == null)
          const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
        else if (_folders!.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text('No audio folders found.', textAlign: TextAlign.center, style: TextStyle(color: c.secondaryText)),
          )
        else
          Container(
            decoration: BoxDecoration(color: c.cardColor, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.divider)),
            child: Column(children: [
              for (final f in _folders!)
                CheckboxListTile(
                  value: !_excluded.contains(f.path) && !_excluded.any((e) => f.path.startsWith('$e/')),
                  activeColor: accent,
                  onChanged: (v) => _toggleFolder(f.path, v ?? true),
                  secondary: Icon(
                    _looksLikeClutter(f.path) ? Icons.mic_none_rounded : Icons.folder_rounded,
                    color: _looksLikeClutter(f.path) ? Colors.orange : accent,
                  ),
                  title: Text(f.name.isEmpty ? f.path : f.name,
                      style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '${f.count} file${f.count == 1 ? '' : 's'}'
                    '${f.shortCount > 0 ? ' · ${f.shortCount} under 30s' : ''}\n${f.path}',
                    style: TextStyle(color: c.secondaryText, fontSize: 12),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                ),
            ]),
          ),
      ]),
    );
  }
}
