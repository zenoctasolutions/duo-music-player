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
import 'motion/motion_kit.dart';

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

  BoxDecoration get _card => BoxDecoration(
        color: c.cardColor,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: c.divider),
      );

  Widget _header(IconData icon, String title, String sub, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: AppPalette.accent.withOpacity(0.14), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: AppPalette.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Semantics(
                header: true,
                child: Text(title, style: TextStyle(color: c.primaryText, fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              const SizedBox(height: 2),
              Text(sub, style: TextStyle(color: c.secondaryText, fontSize: 13, height: 1.3)),
            ]),
          ),
          if (trailing != null) trailing,
        ]),
      );

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
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        FadeSlideIn(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: _card,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _header(Icons.timer_outlined, 'Hide short audio',
                  'Skip clips shorter than this: voice notes, call recordings, notification sounds.'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final s in LibraryFilter.minDurationChoices)
                  ChoiceChip(
                    label: Text(_durationLabel(s)),
                    selected: _minDuration == s,
                    showCheckmark: false,
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    selectedColor: accent.withOpacity(0.18),
                    side: BorderSide(color: _minDuration == s ? accent : c.divider),
                    labelStyle: TextStyle(color: _minDuration == s ? accent : c.primaryText, fontWeight: _minDuration == s ? FontWeight.w700 : FontWeight.normal),
                    onSelected: (_) => _setMin(s),
                  ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: 20),
        FadeSlideIn(
          index: 1,
          child: Container(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            decoration: _card,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _header(
                Icons.folder_open_rounded,
                'Folders',
                'Untick a folder to hide its songs from the library.',
                trailing: _excluded.isNotEmpty
                    ? TextButton(
                        onPressed: () async {
                          setState(() => _excluded.clear());
                          await LibraryFilter.setExcluded(_excluded);
                        },
                        child: Text('Show all', style: TextStyle(color: accent)),
                      )
                    : null,
              ),
              if (_folders == null)
                const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
              else if (_folders!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No audio folders found.', textAlign: TextAlign.center, style: TextStyle(color: c.secondaryText)),
                )
              else
                for (final f in _folders!)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: !_excluded.contains(f.path) && !_excluded.any((e) => f.path.startsWith('$e/')),
                    activeColor: accent,
                    onChanged: (v) => _toggleFolder(f.path, v ?? true),
                    secondary: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: (_looksLikeClutter(f.path) ? Colors.orange : accent).withOpacity(0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _looksLikeClutter(f.path) ? Icons.mic_none_rounded : Icons.folder_rounded,
                        color: _looksLikeClutter(f.path) ? Colors.orange : accent,
                      ),
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
        ),
      ]),
    );
  }
}
