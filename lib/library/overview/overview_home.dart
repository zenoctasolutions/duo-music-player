// lib/library/overview/overview_home.dart
//
// Art-forward "home" for Library > Overview: hero "Continue listening" card,
// quick actions, horizontal art shelves and a browse grid. Pure UI; every
// action is a callback supplied by ListPage, which owns navigation/playback.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shimmer/shimmer.dart';

import '../../app_palette.dart';
import '../../l10n/l10n.dart';
import '../../library_service.dart';
import '../../motion/motion_kit.dart';
import '../../player/art_colors.dart';
import '../title_cleaner.dart';

const double _kGutter = 20;
const double _kRadius = 22;

typedef OverviewCoverLoader = Future<Uint8List?> Function(File file);

class OverviewHome extends StatefulWidget {
  final List<File> files;
  final bool loading;
  final List<File> recentlyPlayed;
  final String? nowPlayingPath;
  final bool isPlaying;

  /// 0..1 progress of the current track (hint only).
  final double progress;
  final OverviewCoverLoader loadCover;
  final String? Function(String path)? resolveArtist;
  final String? Function(String path)? resolveAlbum;
  final int favoritesCount;
  final int artistsCount;
  final bool hasPlaylists;
  final double bottomPadding;

  final void Function(File file, List<File> queue, String pageId) onPlay;
  final VoidCallback onTogglePlay;
  final VoidCallback onShuffleAll;
  final VoidCallback onOpenRecent;
  final VoidCallback onOpenAdded;
  final VoidCallback onOpenMost;
  final VoidCallback onOpenFolders;
  final void Function(String dir, List<File> songs) onOpenFolder;
  final VoidCallback onOpenArtists;
  final VoidCallback onOpenAlbums;
  final VoidCallback onOpenGenres;
  final VoidCallback onOpenSmartMix;
  final VoidCallback onOpenPlaylists;
  final VoidCallback onOpenFavorites;

  const OverviewHome({
    super.key,
    required this.files,
    required this.loading,
    required this.recentlyPlayed,
    required this.nowPlayingPath,
    required this.isPlaying,
    required this.progress,
    required this.loadCover,
    this.resolveArtist,
    this.resolveAlbum,
    required this.favoritesCount,
    required this.artistsCount,
    required this.hasPlaylists,
    required this.bottomPadding,
    required this.onPlay,
    required this.onTogglePlay,
    required this.onShuffleAll,
    required this.onOpenRecent,
    required this.onOpenAdded,
    required this.onOpenMost,
    required this.onOpenFolders,
    required this.onOpenFolder,
    required this.onOpenArtists,
    required this.onOpenAlbums,
    required this.onOpenGenres,
    required this.onOpenSmartMix,
    required this.onOpenPlaylists,
    required this.onOpenFavorites,
  });

  @override
  State<OverviewHome> createState() => _OverviewHomeState();
}

class _OverviewHomeState extends State<OverviewHome> {
  List<File> _added = const [];
  List<File> _most = const [];
  Map<String, List<File>> _folders = const {};

  @override
  void initState() {
    super.initState();
    _recomputeLibrary();
    _recomputeMost();
    PlayStats.changes.addListener(_onStats);
  }

  @override
  void didUpdateWidget(covariant OverviewHome old) {
    super.didUpdateWidget(old);
    if (!identical(old.files, widget.files) || old.files.length != widget.files.length) {
      _recomputeLibrary();
      _recomputeMost();
    }
  }

  @override
  void dispose() {
    PlayStats.changes.removeListener(_onStats);
    super.dispose();
  }

  void _onStats() {
    if (!mounted) return;
    setState(_recomputeMost);
  }

  void _recomputeMost() {
    _most = PlayStats.mostPlayed(widget.files, limit: 20);
  }

  void _recomputeLibrary() {
    _added = LibraryInfo.dateAdded.isEmpty && widget.files.isEmpty
        ? const []
        : PlayStats.recentlyAdded(widget.files, limit: 20);
    final map = <String, List<File>>{};
    for (final f in widget.files) {
      map.putIfAbsent(p.dirname(f.path), () => []).add(f);
    }
    _folders = map;
  }

  File? get _heroFile {
    final path = widget.nowPlayingPath;
    if (path != null) return File(path);
    for (final f in widget.recentlyPlayed) {
      return f;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark ? AppPalette.darkBackground : Colors.white;
    final recent = widget.recentlyPlayed.take(20).toList();
    final folderEntries = _folders.entries.where((e) => e.value.isNotEmpty).take(20).toList();
    final reduced = Motion.reduced(context);
    final l = context.l10n;

    final children = <Widget>[];
    var i = 0;
    Widget wrap(Widget w) => i >= 6 || reduced ? w : FadeSlideIn(index: i++, child: w);

    if (widget.loading && widget.files.isEmpty) {
      children.add(_OverviewSkeleton(dark: dark));
    } else if (widget.files.isEmpty) {
      children.add(_EmptyHome(dark: dark));
    } else {
      children.add(wrap(Padding(
        padding: const EdgeInsets.fromLTRB(_kGutter, 8, _kGutter, 0),
        child: _HeroCard(
          file: _heroFile,
          isCurrent: widget.nowPlayingPath != null,
          isPlaying: widget.isPlaying && widget.nowPlayingPath != null,
          progress: widget.progress,
          loadCover: widget.loadCover,
          resolveArtist: widget.resolveArtist,
          resolveAlbum: widget.resolveAlbum,
          dark: dark,
          onPlayPause: () {
            final f = _heroFile;
            if (f == null) {
              widget.onShuffleAll();
            } else if (widget.nowPlayingPath == f.path) {
              widget.onTogglePlay();
            } else {
              widget.onPlay(f, widget.recentlyPlayed.isEmpty ? [f] : widget.recentlyPlayed, 'recently_played');
            }
          },
          onShuffleAll: widget.onShuffleAll,
        ),
      )));
      children.add(wrap(Padding(
        padding: const EdgeInsets.only(top: 16),
        child: _QuickActions(
          dark: dark,
          favorites: widget.favoritesCount,
          folders: _folders.length,
          hasPlaylists: widget.hasPlaylists,
          onShuffle: widget.onShuffleAll,
          onFavorites: widget.onOpenFavorites,
          onPlaylists: widget.onOpenPlaylists,
          onFolders: widget.onOpenFolders,
        ),
      )));
      children.add(wrap(_Shelf(
        title: l.recentlyAdded,
        count: _added.length,
        dark: dark,
        onSeeAll: widget.onOpenAdded,
        items: [
          for (final f in _added) _ShelfItem(file: f, title: _fileTitle(f), subtitle: _fileSub(f)),
        ],
        loadCover: widget.loadCover,
        onTap: (item) => widget.onPlay(item.file!, _added, 'recently_added'),
      )));
      children.add(wrap(_Shelf(
        title: l.recentlyPlayed,
        count: widget.recentlyPlayed.length,
        dark: dark,
        onSeeAll: widget.onOpenRecent,
        items: [
          for (final f in recent) _ShelfItem(file: f, title: _fileTitle(f), subtitle: _fileSub(f)),
        ],
        loadCover: widget.loadCover,
        onTap: (item) => widget.onPlay(item.file!, widget.recentlyPlayed, 'recently_played'),
      )));
      children.add(wrap(_Shelf(
        title: l.mostPlayed,
        count: _most.length,
        dark: dark,
        onSeeAll: widget.onOpenMost,
        items: [
          for (final f in _most)
            _ShelfItem(file: f, title: _fileTitle(f), subtitle: l.playCount(PlayStats.countFor(f.path))),
        ],
        loadCover: widget.loadCover,
        onTap: (item) => widget.onPlay(item.file!, _most, 'most_played'),
      )));
      children.add(wrap(_Shelf(
        title: l.folders,
        count: _folders.length,
        dark: dark,
        onSeeAll: widget.onOpenFolders,
        items: [
          for (final e in folderEntries)
            _ShelfItem(
              file: e.value.first,
              title: p.basename(e.key).isEmpty ? e.key : p.basename(e.key),
              subtitle: l.songCount(e.value.length),
              folderDir: e.key,
              folderSongs: e.value,
            ),
        ],
        loadCover: widget.loadCover,
        onTap: (item) => widget.onOpenFolder(item.folderDir!, item.folderSongs!),
      )));
      children.add(wrap(_BrowseGrid(
        dark: dark,
        artists: widget.artistsCount,
        onArtists: widget.onOpenArtists,
        onAlbums: widget.onOpenAlbums,
        onGenres: widget.onOpenGenres,
        onSmartMix: widget.onOpenSmartMix,
      )));
    }

    return Container(
      color: bg,
      child: ListView.builder(
        padding: EdgeInsets.only(top: 4, bottom: widget.bottomPadding),
        itemCount: children.length,
        itemBuilder: (_, idx) => children[idx],
      ),
    );
  }

  static String _fileTitle(File f) => TitleCleaner.title(null, path: f.path);
  static String _fileSub(File f) {
    final dir = p.basename(p.dirname(f.path)).trim();
    return dir.isEmpty ? TitleCleaner.unknownArtist : dir;
  }
}

// ───────────────────────── shared bits ─────────────────────────

Color _surface(bool dark) => dark ? AppPalette.darkCard : const Color(0xFFF3F5F9);
Color _textOf(bool dark) => dark ? Colors.white : const Color(0xFF111111);
Color _subOf(bool dark) => dark ? const Color(0xFFB3B3B3) : Colors.grey.shade700;

/// Cover image decoded at display size with a gradient placeholder.
class _CoverImage extends StatefulWidget {
  final File? file;
  final OverviewCoverLoader loadCover;
  final double size;
  final double radius;
  final IconData icon;
  const _CoverImage({
    required this.file,
    required this.loadCover,
    required this.size,
    this.radius = 18,
    this.icon = Icons.music_note_rounded,
  });

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _future = widget.file == null ? null : widget.loadCover(widget.file!);
  }

  @override
  void didUpdateWidget(covariant _CoverImage old) {
    super.didUpdateWidget(old);
    if (old.file?.path != widget.file?.path) {
      _future = widget.file == null ? null : widget.loadCover(widget.file!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = (widget.size * dpr).round();
    final accent = AppPalette.accent;
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withOpacity(0.55), accent.withOpacity(0.18)],
        ),
      ),
      child: Center(child: Icon(widget.icon, color: Colors.white70, size: widget.size * 0.36)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: _future == null
            ? placeholder
            : FutureBuilder<Uint8List?>(
                future: _future,
                builder: (context, snap) {
                  final bytes = snap.data;
                  if (bytes == null || bytes.isEmpty) return placeholder;
                  return Image.memory(bytes,
                      fit: BoxFit.cover, cacheWidth: px, gaplessPlayback: true, filterQuality: FilterQuality.low);
                },
              ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final bool dark;
  final VoidCallback? onSeeAll;
  const _SectionHeader({required this.title, required this.dark, this.onSeeAll});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kGutter, 0, _kGutter - 8, 4),
      child: Row(children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: _textOf(dark), letterSpacing: -0.2)),
          ),
        ),
        if (onSeeAll != null)
          Semantics(
            button: true,
            label: context.l10n.seeAllSection(title),
            child: TextButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                onSeeAll!();
              },
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: AppPalette.accentText(dark: dark),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(context.l10n.seeAll, style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
      ]),
    );
  }
}

// ───────────────────────── hero ─────────────────────────

class _TrackInfo {
  final String title;
  final String? artist;
  final String? album;
  const _TrackInfo(this.title, this.artist, [this.album]);
}

final Map<String, _TrackInfo> _infoCache = {};

class _HeroCard extends StatefulWidget {
  final File? file;
  final bool isCurrent;
  final bool isPlaying;
  final double progress;
  final OverviewCoverLoader loadCover;
  final String? Function(String path)? resolveArtist;
  final String? Function(String path)? resolveAlbum;
  final bool dark;
  final VoidCallback onPlayPause;
  final VoidCallback onShuffleAll;
  const _HeroCard({
    required this.file,
    required this.isCurrent,
    required this.isPlaying,
    required this.progress,
    required this.loadCover,
    this.resolveArtist,
    this.resolveAlbum,
    required this.dark,
    required this.onPlayPause,
    required this.onShuffleAll,
  });

  @override
  State<_HeroCard> createState() => _HeroCardState();
}

class _HeroCardState extends State<_HeroCard> {
  Uint8List? _cover;
  Color? _tint;
  _TrackInfo? _info;
  String? _loadedFor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _HeroCard old) {
    super.didUpdateWidget(old);
    if (old.file?.path != widget.file?.path) _load();
  }

  Future<void> _load() async {
    final f = widget.file;
    _loadedFor = f?.path;
    if (f == null) {
      setState(() {
        _cover = null;
        _tint = null;
        _info = null;
      });
      return;
    }
    _info = _infoCache[f.path] ?? _TrackInfo(TitleCleaner.title(null, path: f.path), null);
    final cover = await widget.loadCover(f).catchError((_) => null);
    if (!mounted || _loadedFor != f.path) return;
    setState(() => _cover = cover);
    final tint = await ArtColors.extract(cover);
    if (mounted && _loadedFor == f.path) setState(() => _tint = tint);
    if (!_infoCache.containsKey(f.path)) {
      try {
        final meta = readMetadata(f, getImage: false);
        final info = _TrackInfo(
          TitleCleaner.title(meta.title, path: f.path),
          TitleCleaner.artist(meta.artist, albumArtist: null),
          meta.album?.trim(),
        );
        _infoCache[f.path] = info;
        if (mounted && _loadedFor == f.path) setState(() => _info = info);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.accent;
    final tint = _tint == null ? accent : ArtColors.accent(_tint!, dark: true, fallback: accent);
    final f = widget.file;
    final dpr = MediaQuery.devicePixelRatioOf(context);

    if (f == null) {
      final l = context.l10n;
      return _heroShell(
        tint: accent,
        background: null,
        child: Row(children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(18)),
            child: const Icon(Icons.music_note_rounded, color: Colors.white, size: 36),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.playSomething,
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(l.playSomethingSubtitle,
                  style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ]),
          ),
          const SizedBox(width: 12),
          _RoundPlay(playing: false, label: l.shuffleAll, icon: Icons.shuffle_rounded, onTap: widget.onShuffleAll),
        ]),
      );
    }

    final info = _info ?? _TrackInfo(TitleCleaner.title(null, path: f.path), null);
    // Prefer the artist the player already knows (its metadata cache) over
    // the lazily-read tags; never show "Unknown Artist" while tags load —
    // fall back to the album, else nothing.
    final knownArtist = widget.resolveArtist?.call(f.path);
    final knownAlbum = widget.resolveAlbum?.call(f.path);
    final String? artist = knownArtist ??
        info.artist ??
        ((knownAlbum != null && knownAlbum.isNotEmpty)
            ? knownAlbum
            : (info.album != null && info.album!.isNotEmpty ? info.album : null));
    final bgImage = _cover == null
        ? null
        : ExcludeSemantics(child: ImageFiltered(
            imageFilter: _blur,
            child: Image.memory(_cover!,
                fit: BoxFit.cover, cacheWidth: (160 * dpr).round().clamp(120, 480), gaplessPlayback: true),
          ));
    return Semantics(
      container: true,
      label: '${widget.isCurrent ? context.l10n.heroSemanticsContinue : context.l10n.heroSemanticsLast}: ${artist == null ? info.title : context.l10n.heroSemanticsBy(info.title, artist)}',
      child: _heroShell(
        tint: tint,
        background: bgImage,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          ExcludeSemantics(child: Text(
            widget.isCurrent
                ? (widget.isPlaying ? context.l10n.heroNowPlaying : context.l10n.heroContinueListening)
                : context.l10n.heroPickUp,
            style: const TextStyle(
                color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2),
          )),
          const SizedBox(height: 12),
          Row(children: [
            ExcludeSemantics(child: _CoverImage(file: f, loadCover: widget.loadCover, size: 88, radius: 18)),
            const SizedBox(width: 16),
            Expanded(
              child: ExcludeSemantics(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(info.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700, height: 1.15)),
                if (artist != null) ...[
                  const SizedBox(height: 4),
                  Text(artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 14)),
                ],
              ])),
            ),
            const SizedBox(width: 12),
            _RoundPlay(
              playing: widget.isPlaying,
              label: widget.isPlaying ? context.l10n.pause : context.l10n.play,
              icon: widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              onTap: widget.onPlayPause,
            ),
          ]),
          if (widget.isCurrent && widget.progress > 0) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: widget.progress.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: Colors.white24,
                valueColor: const AlwaysStoppedAnimation(Colors.white),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  static final _blur = ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24);

  Widget _heroShell({required Color tint, required Widget? background, required Widget child}) {
    final base = HSLColor.fromColor(tint).withLightness(0.2).toColor();
    return ClipRRect(
      borderRadius: BorderRadius.circular(_kRadius),
      child: Stack(children: [
        Positioned.fill(child: ColoredBox(color: base)),
        if (background != null) Positioned.fill(child: background),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [tint.withOpacity(0.55), base.withOpacity(0.88)],
              ),
            ),
          ),
        ),
        Padding(padding: const EdgeInsets.all(18), child: child),
      ]),
    );
  }
}

class _RoundPlay extends StatelessWidget {
  final bool playing;
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _RoundPlay({required this.playing, required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        haptic: true,
        child: Container(
          width: 56,
          height: 56,
          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
          child: Icon(icon, size: 32, color: const Color(0xFF15131F)),
        ),
      ),
    );
  }
}

// ───────────────────────── quick actions ─────────────────────────

class _QuickActions extends StatelessWidget {
  final bool dark;
  final int favorites;
  final int folders;
  final bool hasPlaylists;
  final VoidCallback onShuffle;
  final VoidCallback onFavorites;
  final VoidCallback onPlaylists;
  final VoidCallback onFolders;
  const _QuickActions({
    required this.dark,
    required this.favorites,
    required this.folders,
    required this.hasPlaylists,
    required this.onShuffle,
    required this.onFavorites,
    required this.onPlaylists,
    required this.onFolders,
  });

  @override
  Widget build(BuildContext context) {
    final accent = AppPalette.accent;
    final l = context.l10n;
    final items = <_ChipData>[
      _ChipData(l.shuffleAll, null, Icons.shuffle_rounded, accent, onShuffle, filled: true),
      _ChipData(l.favorites, '$favorites', Icons.favorite_rounded, Colors.redAccent, onFavorites),
      _ChipData(hasPlaylists ? l.playlists : l.newPlaylist, null, Icons.queue_music_rounded, Colors.green, onPlaylists),
      _ChipData(l.folders, '$folders', Icons.folder_rounded, Colors.purpleAccent, onFolders),
    ];
    final chipH = math.max(52.0, MediaQuery.textScalerOf(context).scale(14) * 1.4 + 20);
    return SizedBox(
      height: chipH,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: _kGutter),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => _ActionChip(data: items[i], dark: dark),
      ),
    );
  }
}

class _ChipData {
  final String label;
  final String? count;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool filled;
  _ChipData(this.label, this.count, this.icon, this.color, this.onTap, {this.filled = false});
}

class _ActionChip extends StatelessWidget {
  final _ChipData data;
  final bool dark;
  const _ActionChip({required this.data, required this.dark});

  @override
  Widget build(BuildContext context) {
    final fg = data.filled ? Colors.white : _textOf(dark);
    return Semantics(
      button: true,
      label: data.count == null ? data.label : '${data.label}, ${data.count}',
      excludeSemantics: true,
      child: PressScale(
        onTap: data.onTap,
        haptic: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: data.filled ? data.color : _surface(dark),
            borderRadius: BorderRadius.circular(26),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(data.icon, size: 20, color: data.filled ? Colors.white : data.color),
            const SizedBox(width: 8),
            Text(data.label, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 14)),
            if (data.count != null) ...[
              const SizedBox(width: 8),
              Text(data.count!, style: TextStyle(color: fg.withOpacity(0.6), fontWeight: FontWeight.w600, fontSize: 13)),
            ],
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── shelves ─────────────────────────

class _ShelfItem {
  final File? file;
  final String title;
  final String subtitle;
  final String? folderDir;
  final List<File>? folderSongs;
  const _ShelfItem({this.file, required this.title, required this.subtitle, this.folderDir, this.folderSongs});
}

class _SnapPhysics extends ScrollPhysics {
  final double itemExtent;
  const _SnapPhysics({required this.itemExtent, super.parent});

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(itemExtent: itemExtent, parent: buildParent(ancestor));

  double _target(ScrollMetrics m, double velocity) {
    var page = m.pixels / itemExtent;
    if (velocity < -toleranceFor(m).velocity) {
      page -= 0.5;
    } else if (velocity > toleranceFor(m).velocity) {
      page += 0.5;
    }
    return (page.roundToDouble() * itemExtent).clamp(m.minScrollExtent, m.maxScrollExtent);
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final target = _target(position, velocity);
    if (target != position.pixels) {
      return ScrollSpringSimulation(spring, position.pixels, target, velocity, tolerance: toleranceFor(position));
    }
    return null;
  }

  @override
  bool get allowImplicitScrolling => false;
}

class _Shelf extends StatelessWidget {
  final String title;
  final int count;
  final bool dark;
  final VoidCallback onSeeAll;
  final List<_ShelfItem> items;
  final OverviewCoverLoader loadCover;
  final void Function(_ShelfItem item) onTap;
  const _Shelf({
    required this.title,
    required this.count,
    required this.dark,
    required this.onSeeAll,
    required this.items,
    required this.loadCover,
    required this.onTap,
  });

  static const double _card = 144;
  static const double _gap = 14;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    // Title (14sp) + subtitle (12sp) lines at the user's font scale.
    final ts = MediaQuery.textScalerOf(context);
    final textH = (ts.scale(14) + ts.scale(12)) * 1.3;
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionHeader(title: title, dark: dark, onSeeAll: onSeeAll),
        SizedBox(
          height: _card + 22 + textH,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(_kGutter, 8, _kGutter, 0),
            physics: const _SnapPhysics(itemExtent: _card + _gap, parent: BouncingScrollPhysics()),
            itemCount: items.length,
            itemExtent: _card + _gap,
            itemBuilder: (_, i) {
              final it = items[i];
              return Padding(
                padding: const EdgeInsets.only(right: _gap),
                child: _ShelfCard(item: it, dark: dark, size: _card, loadCover: loadCover, onTap: () => onTap(it)),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class _ShelfCard extends StatelessWidget {
  final _ShelfItem item;
  final bool dark;
  final double size;
  final OverviewCoverLoader loadCover;
  final VoidCallback onTap;
  const _ShelfCard({required this.item, required this.dark, required this.size, required this.loadCover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${item.title}, ${item.subtitle}',
      excludeSemantics: true,
      child: PressScale(
        onTap: onTap,
        haptic: true,
        child: SizedBox(
          width: size,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_kRadius),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(dark ? 0.35 : 0.12), blurRadius: 10, offset: const Offset(0, 4))],
              ),
              child: _CoverImage(
                file: item.file,
                loadCover: loadCover,
                size: size,
                radius: _kRadius,
                icon: item.folderDir != null ? Icons.folder_rounded : Icons.music_note_rounded,
              ),
            ),
            const SizedBox(height: 8),
            Text(item.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: _textOf(dark), fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(item.subtitle,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _subOf(dark), fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── browse grid ─────────────────────────

class _BrowseGrid extends StatelessWidget {
  final bool dark;
  final int artists;
  final VoidCallback onArtists;
  final VoidCallback onAlbums;
  final VoidCallback onGenres;
  final VoidCallback onSmartMix;
  const _BrowseGrid({
    required this.dark,
    required this.artists,
    required this.onArtists,
    required this.onAlbums,
    required this.onGenres,
    required this.onSmartMix,
  });

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final tiles = <_TileData>[
      _TileData(l.browseArtists, l.browseArtistsSub, Icons.person_rounded, Colors.teal, onArtists),
      _TileData(l.browseAlbums, l.browseAlbumsSub, Icons.album_rounded, Colors.deepOrange, onAlbums),
      _TileData(l.browseGenres, l.browseGenresSub, Icons.category_rounded, Colors.indigo, onGenres),
      _TileData(l.browseSmartMix, l.browseSmartMixSub, Icons.auto_awesome_rounded, Colors.pink, onSmartMix),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _SectionHeader(title: l.browse, dark: dark),
        Padding(
          padding: const EdgeInsets.fromLTRB(_kGutter, 8, _kGutter, 0),
          child: Column(children: [
            Row(children: [
              Expanded(child: _BrowseTile(data: tiles[0], dark: dark)),
              const SizedBox(width: 12),
              Expanded(child: _BrowseTile(data: tiles[1], dark: dark)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _BrowseTile(data: tiles[2], dark: dark)),
              const SizedBox(width: 12),
              Expanded(child: _BrowseTile(data: tiles[3], dark: dark)),
            ]),
          ]),
        ),
      ]),
    );
  }
}

class _TileData {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  _TileData(this.title, this.subtitle, this.icon, this.color, this.onTap);
}

class _BrowseTile extends StatelessWidget {
  final _TileData data;
  final bool dark;
  const _BrowseTile({required this.data, required this.dark});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '${data.title}, ${data.subtitle}',
      excludeSemantics: true,
      child: PressScale(
        onTap: data.onTap,
        haptic: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 84),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kRadius),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [data.color.withOpacity(dark ? 0.32 : 0.18), _surface(dark)],
            ),
          ),
          child: Row(children: [
            Icon(data.icon, color: data.color, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(data.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: _textOf(dark), fontWeight: FontWeight.w700, fontSize: 15)),
                const SizedBox(height: 2),
                Text(data.subtitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _subOf(dark), fontSize: 12)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

// ───────────────────────── loading / empty ─────────────────────────

class _OverviewSkeleton extends StatelessWidget {
  final bool dark;
  const _OverviewSkeleton({required this.dark});

  @override
  Widget build(BuildContext context) {
    final base = dark ? const Color(0xFF2A2A2A) : Colors.grey.shade300;
    final hi = dark ? const Color(0xFF3A3A3A) : Colors.grey.shade100;
    Widget box(double w, double h, [double r = 12]) => Container(
        width: w, height: h, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(r)));
    return Shimmer.fromColors(
      baseColor: base,
      highlightColor: hi,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_kGutter, 8, 0, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(right: _kGutter),
              child: box(double.infinity, 160, _kRadius),
            ),
            const SizedBox(height: 16),
            Row(children: [box(120, 44, 24), const SizedBox(width: 10), box(110, 44, 24), const SizedBox(width: 10), box(100, 44, 24)]),
            const SizedBox(height: 28),
            box(160, 20, 8),
            const SizedBox(height: 14),
            Row(children: [for (var i = 0; i < 3; i++) ...[box(144, 144, _kRadius), const SizedBox(width: 14)]]),
          ]),
        ),
      ),
    );
  }
}

class _EmptyHome extends StatelessWidget {
  final bool dark;
  const _EmptyHome({required this.dark});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(_kGutter, 80, _kGutter, 0),
      child: Column(children: [
        Icon(Icons.library_music_rounded, size: 56, color: _subOf(dark)),
        const SizedBox(height: 12),
        Text(context.l10n.noMusicFound, style: TextStyle(color: _textOf(dark), fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(context.l10n.noMusicFoundSub, style: TextStyle(color: _subOf(dark), fontSize: 14)),
      ]),
    );
  }
}
