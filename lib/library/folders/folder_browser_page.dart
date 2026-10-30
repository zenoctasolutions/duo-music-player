// lib/library/folders/folder_browser_page.dart
//
// Hierarchical folder browser (storage roots > folders > songs). Pure UI:
// the host supplies the (already filtered) files, a cover loader and an
// `onPlay` callback; tree logic lives in folder_tree.dart.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../app_palette.dart';
import '../../library_service.dart';
import '../../motion/motion_kit.dart';
import '../../ui/app_page_bar.dart';
import '../library_motion.dart';
import '../queue_menu.dart';
import '../title_cleaner.dart';
import 'folder_tree.dart';

class FolderBrowserPage extends StatefulWidget {
  final List<File> audioFiles;
  final Future<Uint8List?> Function(File file) loadCover;

  /// Plays [file] with [queue] as the queue; pageId is `folder:<path>`.
  final void Function(File file, List<File> queue, String pageId) onPlay;

  /// Optional display-title resolver (e.g. from tags). Defaults to a title
  /// derived from the file name via [TitleCleaner].
  final String Function(File file)? titleOf;
  final String? nowPlayingPath;
  final bool loading;
  final String? initialPath;

  const FolderBrowserPage({
    super.key,
    required this.audioFiles,
    required this.loadCover,
    required this.onPlay,
    this.titleOf,
    this.nowPlayingPath,
    this.loading = false,
    this.initialPath,
  });

  @override
  State<FolderBrowserPage> createState() => _FolderBrowserPageState();
}

class _FolderBrowserPageState extends State<FolderBrowserPage> {
  late FolderTree _tree;
  late Map<String, File> _files;
  FolderNode? _current; // null = list of storage roots
  final Map<String, Future<Uint8List?>> _covers = {};
  final Map<String, String> _titles = {};

  @override
  void initState() {
    super.initState();
    _rebuild();
    final ip = widget.initialPath;
    if (ip != null) _current = _tree.nodeFor(ip);
  }

  @override
  void didUpdateWidget(FolderBrowserPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.audioFiles, widget.audioFiles) ||
        old.audioFiles.length != widget.audioFiles.length) {
      final path = _current?.path;
      _rebuild();
      _current = path == null ? null : _tree.nodeFor(path);
    }
  }

  void _rebuild() {
    _files = {for (final f in widget.audioFiles) f.path: f};
    _tree = FolderTree.build(_files.keys);
    _titles.clear();
  }

  String _title(File f) => _titles.putIfAbsent(f.path, () {
        final t = widget.titleOf?.call(f);
        return (t != null && t.trim().isNotEmpty) ? t : TitleCleaner.title(null, path: f.path);
      });

  Future<Uint8List?> _cover(String path) {
    final f = _files[path];
    if (f == null) return Future.value(null);
    return _covers.putIfAbsent(path, () => widget.loadCover(f));
  }

  List<File> _filesOf(Iterable<String> paths) =>
      [for (final s in paths) if (_files[s] != null) _files[s]!];

  List<File> _sortedSongs(FolderNode n) {
    final l = _filesOf(n.songs);
    l.sort((a, b) => _title(a).toLowerCase().compareTo(_title(b).toLowerCase()));
    return l;
  }

  /// Every song under [n]: own songs by title, then sub-folders A-Z.
  List<File> _queueOf(FolderNode n) {
    final out = <File>[..._sortedSongs(n)];
    for (final c in n.sortedChildren()) {
      out.addAll(_queueOf(c));
    }
    return out;
  }

  void _go(FolderNode? n) => setState(() => _current = n);

  void _play(List<File> q, {bool shuffle = false, FolderNode? node, File? start}) {
    if (q.isEmpty) return;
    final list = List<File>.of(q);
    if (shuffle) list.shuffle(Random());
    final pid = 'folder:${node?.path ?? ''}';
    widget.onPlay(start ?? list.first, list, pid);
  }

  Future<void> _exclude(FolderNode n) async {
    final label = n.isRoot ? n.rootLabel! : n.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Exclude this folder?'),
        content: Text(
            '"$label" and its sub-folders will be hidden from your library. You can bring it back in Settings > Library filters.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Exclude')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await LibraryFilter.setExcluded({...LibraryFilter.excludedFolders, n.path});
    if (!mounted) return;
    final prefix = n.path.endsWith('/') ? n.path : '${n.path}/';
    setState(() {
      _files.removeWhere((k, _) => k.startsWith(prefix));
      _tree = FolderTree.build(_files.keys);
      _current = n.parent == null ? null : _tree.nodeFor(n.parent!.path);
    });
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text('Excluded "$label"'), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? AppPalette.darkBackground : Colors.white;
    final fg = dark ? Colors.white : Colors.black87;
    final sub = dark ? const Color(0xFFB3B3B3) : Colors.grey.shade700;
    final card = dark ? AppPalette.darkCard : const Color(0xFFF3F4F8);
    final accent = AppPalette.accent;
    final cur = _current;

    Widget body;
    if (widget.loading && widget.audioFiles.isEmpty) {
      body = _Skeleton(dark: dark);
    } else if (_tree.roots.isEmpty) {
      body = _Empty(fg: fg, sub: sub);
    } else {
      body = _buildList(cur, dark: dark, fg: fg, sub: sub, card: card, accent: accent);
    }

    return PopScope(
      canPop: cur == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && cur != null) _go(cur.parent);
      },
      child: Scaffold(
        backgroundColor: bg,
        appBar: AppPageBar(
          title: cur == null ? 'Folders' : (cur.isRoot ? cur.rootLabel! : cur.name),
          foregroundColor: fg,
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: () => cur == null ? Navigator.maybePop(context) : _go(cur.parent),
          ),
          actions: [
            if (cur != null)
              PopupMenuButton<String>(
                tooltip: 'Folder options',
                onSelected: (v) {
                  if (v == 'x') _exclude(cur);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'x', child: Text('Exclude this folder')),
                ],
              ),
          ],
        ),
        body: body,
      ),
    );
  }

  Widget _buildList(FolderNode? cur,
      {required bool dark,
      required Color fg,
      required Color sub,
      required Color card,
      required Color accent}) {
    final List<FolderNode> subs;
    final List<File> songs;
    if (cur == null) {
      subs = _tree.roots;
      songs = const [];
    } else {
      subs = cur.sortedChildren();
      songs = _sortedSongs(cur);
    }
    final bottom = 120 + MediaQuery.paddingOf(context).bottom;
    final hasActions = cur != null && cur.totalCount > 0;
    final header = <Widget>[
      if (cur != null) _Breadcrumbs(node: cur, onTap: _go, fg: fg, accent: accent, card: card),
      if (hasActions) _ActionRow(
        node: cur,
        accent: accent,
        card: card,
        fg: fg,
        onPlay: () => _play(_queueOf(cur), node: cur),
        onShuffle: () => _play(_queueOf(cur), node: cur, shuffle: true),
        paths: cur.allSongs().where(_files.containsKey).toList(),
        onExclude: () => _exclude(cur),
      ),
    ];
    final total = header.length + subs.length + songs.length;
    return ListView.builder(
      padding: EdgeInsets.only(bottom: bottom, top: 4),
      itemCount: total,
      itemBuilder: (context, i) {
        if (i < header.length) return header[i];
        var j = i - header.length;
        if (j < subs.length) {
          final n = subs[j];
          final target = n.isRoot ? n : n.collapsed();
          final title = n.isRoot ? n.rootLabel! : n.collapsedShortLabel();
          final fullLabel = n.isRoot ? null : n.collapsedLabel();
          return FadeSlideIn(
            index: min(j, 8),
            offset: 10,
            child: _FolderRow(
              key: ValueKey('f:${n.path}'),
              title: title,
              fullLabel: fullLabel != null && fullLabel != title ? fullLabel : null,
              path: target.path,
              count: n.totalCount,
              icon: n.isRoot ? Icons.sd_storage_rounded : Icons.folder_rounded,
              coverPath: n.firstSong,
              loadCover: _cover,
              dark: dark,
              fg: fg,
              sub: sub,
              card: card,
              accent: accent,
              onTap: () => _go(target),
              paths: n.allSongs().where(_files.containsKey).toList(),
            ),
          );
        }
        j -= subs.length;
        final f = songs[j];
        final playing = f.path == widget.nowPlayingPath;
        return _SongRow(
          key: ValueKey('s:${f.path}'),
          title: _title(f),
          file: f,
          playing: playing,
          loadCover: _cover,
          fg: fg,
          sub: sub,
          accent: accent,
          dark: dark,
          onTap: () => _play(songs, node: cur, start: f),
        );
      },
    );
  }
}

class _Breadcrumbs extends StatefulWidget {
  final FolderNode node;
  final void Function(FolderNode?) onTap;
  final Color fg, accent, card;
  const _Breadcrumbs(
      {required this.node, required this.onTap, required this.fg, required this.accent, required this.card});

  @override
  State<_Breadcrumbs> createState() => _BreadcrumbsState();
}

class _BreadcrumbsState extends State<_Breadcrumbs> {
  final _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final trail = widget.node.trail();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_ctrl.hasClients) _ctrl.jumpTo(_ctrl.position.maxScrollExtent);
    });
    return SizedBox(
      height: 56,
      child: ListView.separated(
        controller: _ctrl,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: trail.length + 1, // synthetic "Storage" chip + trail
        separatorBuilder: (_, __) =>
            Icon(Icons.chevron_right_rounded, size: 18, color: widget.fg.withValues(alpha: 0.5)),
        itemBuilder: (_, i) {
          final real = i == 0 ? null : trail[i - 1];
          final label = real == null ? 'Storage' : (real.isRoot ? real.rootLabel! : real.name);
          final isCurrent = real != null && identical(real, widget.node);
          return Semantics(
            button: !isCurrent,
            label: isCurrent ? 'Current folder $label' : 'Go to $label',
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Center(
                  widthFactor: 1,
                  child: ActionChip(
                    label: Text(label,
                        style: TextStyle(
                            color: isCurrent ? Colors.white : widget.fg,
                            fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500)),
                    backgroundColor: isCurrent ? widget.accent : widget.card,
                    side: BorderSide.none,
                    shape: const StadiumBorder(),
                    onPressed: isCurrent ? null : () => widget.onTap(real),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final FolderNode node;
  final Color accent, card, fg;
  final VoidCallback onPlay, onShuffle, onExclude;
  final List<String> paths;
  const _ActionRow({
    required this.node,
    required this.accent,
    required this.card,
    required this.fg,
    required this.onPlay,
    required this.onShuffle,
    required this.onExclude,
    required this.paths,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn(String label, IconData icon, VoidCallback onTap, {bool primary = false}) => Expanded(
          child: Semantics(
            button: true,
            label: label,
            child: PressScale(
              onTap: onTap,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  color: primary ? accent : card,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(icon, size: 20, color: primary ? Colors.white : fg),
                  const SizedBox(width: 6),
                  Text(label,
                      style: TextStyle(
                          fontWeight: FontWeight.w600, color: primary ? Colors.white : fg)),
                ]),
              ),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
      child: Row(children: [
        btn('Play', Icons.play_arrow_rounded, onPlay, primary: true),
        const SizedBox(width: 10),
        btn('Shuffle', Icons.shuffle_rounded, onShuffle),
        SizedBox(
          width: 48,
          height: 48,
          child: QueueMenuButton(paths: paths, color: fg),
        ),
      ]),
    );
  }
}

class _Cover extends StatelessWidget {
  final String? path;
  final Future<Uint8List?> Function(String) load;
  final double size;
  final IconData fallback;
  final Color tint;
  const _Cover(
      {required this.path, required this.load, required this.size, required this.fallback, required this.tint});

  @override
  Widget build(BuildContext context) {
    final ph = Container(
      width: size,
      height: size,
      color: tint.withValues(alpha: 0.16),
      child: Icon(fallback, color: tint, size: size * 0.5),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 52 ? 14 : 10),
      child: path == null
          ? ph
          : FutureBuilder<Uint8List?>(
              future: load(path!),
              builder: (_, snap) {
                final d = snap.data;
                if (d == null) return ph;
                return Image.memory(d,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    cacheWidth: (size * 2).round(),
                    errorBuilder: (_, __, ___) => ph);
              }),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final String title, path;
  final String? fullLabel;
  final int count;
  final IconData icon;
  final String? coverPath;
  final Future<Uint8List?> Function(String) loadCover;
  final bool dark;
  final Color fg, sub, card, accent;
  final VoidCallback onTap;
  final List<String> paths;
  const _FolderRow({
    super.key,
    required this.title,
    this.fullLabel,
    required this.path,
    required this.count,
    required this.icon,
    required this.coverPath,
    required this.loadCover,
    required this.dark,
    required this.fg,
    required this.sub,
    required this.card,
    required this.accent,
    required this.onTap,
    required this.paths,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
      child: Semantics(
        button: true,
        label: '${fullLabel ?? title}, $count ${count == 1 ? 'song' : 'songs'}',
        child: PressScale(
          passive: true,
          child: Material(
            color: card,
            borderRadius: BorderRadius.circular(22),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 72),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 0, 8),
                  child: Row(children: [
                    ExcludeSemantics(
                        child: _Cover(path: coverPath, load: loadCover, size: 56, fallback: icon, tint: accent)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ExcludeSemantics(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: fg, fontSize: 15.5, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text('$count song${count == 1 ? '' : 's'}',
                            style: TextStyle(color: sub, fontSize: 12.5)),
                        if (fullLabel != null)
                          Text(_middleEllipsis(fullLabel!),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: sub.withOpacity(0.8), fontSize: 11.5)),
                      ])),
                    ),
                    SizedBox(
                        width: 48, height: 48, child: QueueMenuButton(paths: paths, color: sub)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  final String title;
  final File file;
  final bool playing, dark;
  final Future<Uint8List?> Function(String) loadCover;
  final Color fg, sub, accent;
  final VoidCallback onTap;
  const _SongRow({
    super.key,
    required this.title,
    required this.file,
    required this.playing,
    required this.loadCover,
    required this.fg,
    required this.sub,
    required this.accent,
    required this.dark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: playing,
      label: playing ? '$title, now playing' : title,
      child: ListTile(
        minVerticalPadding: 8,
        contentPadding: const EdgeInsets.only(left: 20, right: 12),
        onTap: onTap,
        leading: _Cover(
            path: file.path, load: loadCover, size: 48, fallback: Icons.music_note_rounded, tint: accent),
        title: Text(title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: playing ? accent : fg,
                fontWeight: playing ? FontWeight.w700 : FontWeight.w500)),
        subtitle: Text(file.path.split('/').last,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: sub, fontSize: 12)),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (playing) EqualizerBars(color: accent, playing: true, size: 18),
          SizedBox(width: 48, height: 48, child: QueueMenuButton(paths: [file.path], color: sub)),
        ]),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final Color fg, sub;
  const _Empty({required this.fg, required this.sub});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.folder_off_rounded, size: 64, color: sub),
            const SizedBox(height: 12),
            Text('No folders yet',
                style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Folders that contain music will show up here.',
                textAlign: TextAlign.center, style: TextStyle(color: sub)),
          ]),
        ),
      );
}

class _Skeleton extends StatelessWidget {
  final bool dark;
  const _Skeleton({required this.dark});

  @override
  Widget build(BuildContext context) {
    final base = dark ? const Color(0xFF2A2A30) : const Color(0xFFE4E6EB);
    final hi = dark ? const Color(0xFF3A3A42) : const Color(0xFFF4F5F8);
    final reduced = Motion.reduced(context);
    final list = ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      itemCount: 7,
      itemBuilder: (_, __) => Container(
        height: 72,
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(22)),
      ),
    );
    return Semantics(
      label: 'Loading folders',
      child: reduced ? list : Shimmer.fromColors(baseColor: base, highlightColor: hi, child: list),
    );
  }
}

/// Shortens [s] by replacing its middle with an ellipsis (Flutter's
/// TextOverflow only truncates the end).
String _middleEllipsis(String s, {int max = 38}) {
  if (s.length <= max) return s;
  final head = (max - 1) ~/ 2;
  final tail = max - 1 - head;
  return '${s.substring(0, head)}…${s.substring(s.length - tail)}';
}
