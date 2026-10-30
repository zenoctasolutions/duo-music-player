// lib/search/search_page.dart
//
// Full-screen "search everything": songs, albums, artists and playlists in one
// ranked, grouped list. Opened from the Library app bar.
import '../l10n/l10n.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../albums_page.dart' show AlbumDetailPage, SongMetadata;
import '../app_palette.dart';
import '../artists_page.dart' show Artist, ArtistDetailPage, Song;
import '../library/title_cleaner.dart';
import '../motion/motion_kit.dart';
import '../player_screen.dart' show PlaylistService;
import '../playlist_page.dart' show ManagePlaylistPage;
import 'search_history.dart';
import 'search_service.dart';

/// Per-song metadata the host (songs_page) already has cached.
class SearchMeta {
  final String? title;
  final String? artist;
  final String? album;
  const SearchMeta({this.title, this.artist, this.album});
}

class SearchPage extends StatefulWidget {
  final List<FileSystemEntity> audioFiles;
  final SearchMeta Function(String path) resolveMeta;

  /// Cover for a path (cache first, then tags); may return null.
  final Future<Uint8List?> Function(String path) loadCover;

  /// Plays [path] with [queue] as the queue context.
  final void Function(String path, List<String> queue) onPlay;
  final bool isDark;

  const SearchPage({
    super.key,
    required this.audioFiles,
    required this.resolveMeta,
    required this.loadCover,
    required this.onPlay,
    required this.isDark,
  });

  @override
  State<SearchPage> createState() => _SearchPageState();
}

SearchResults _searchInIsolate((SearchIndex, String) a) => a.$1.search(a.$2);

class _SearchPageState extends State<SearchPage> {
  static const int _isolateThreshold = 3000;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  int _seq = 0;

  SearchIndex? _index;
  SearchResults _results = SearchResults.empty;
  List<String> _tokens = const [];
  String _query = '';
  List<String> _history = const [];
  bool _searching = false;

  Color get _accent => AppPalette.accent;
  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF6F6F8);
  Color get _card => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _text => widget.isDark ? Colors.white : Colors.black87;
  Color get _sub => widget.isDark ? Colors.white60 : Colors.black54;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() {});
    });
    _buildIndex();
    SearchHistory.load().then((h) {
      if (mounted) setState(() => _history = h);
    });
  }

  Future<void> _buildIndex() async {
    final inputs = <SearchInput>[
      for (final f in widget.audioFiles)
        () {
          final m = widget.resolveMeta(f.path);
          return SearchInput(path: f.path, title: m.title, artist: m.artist, album: m.album);
        }(),
    ];
    final playlists = <String, List<String>>{};
    try {
      for (final name in await PlaylistService.getPlaylistNames()) {
        playlists[name] = await PlaylistService.getPlaylist(name);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() => _index = SearchService.buildIndex(inputs, playlists: playlists));
    if (_query.isNotEmpty) _run(_query);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String text) {
    _debounce?.cancel();
    setState(() {}); // clear-button visibility
    if (text.trim().isEmpty) {
      _seq++;
      setState(() {
        _query = '';
        _tokens = const [];
        _results = SearchResults.empty;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 200), () => _run(text));
  }

  Future<void> _run(String text) async {
    final index = _index;
    if (index == null) {
      _query = text.trim();
      return;
    }
    final my = ++_seq;
    final tokens = SearchService.tokenize(text);
    SearchResults res;
    if (index.size > _isolateThreshold) {
      if (mounted) setState(() => _searching = true);
      try {
        res = await compute(_searchInIsolate, (index, text));
      } catch (_) {
        res = index.search(text);
      }
    } else {
      res = index.search(text);
    }
    if (!mounted || my != _seq) return;
    setState(() {
      _query = text.trim();
      _tokens = tokens;
      _results = res;
      _searching = false;
    });
  }

  Future<void> _remember() async {
    final q = _controller.text.trim();
    if (q.isEmpty) return;
    final h = await SearchHistory.add(q);
    if (mounted) setState(() => _history = h);
  }

  void _useHistory(String q) {
    _controller.value = TextEditingValue(text: q, selection: TextSelection.collapsed(offset: q.length));
    _debounce?.cancel();
    setState(() {});
    _run(q);
  }

  void _clearField() {
    _controller.clear();
    _onChanged('');
    _focus.requestFocus();
  }

  // ---- navigation ----

  void _playSong(SearchSong s) {
    _remember();
    final queue = _results.songs.map((e) => e.path).toList();
    widget.onPlay(s.path, queue);
  }

  void _push(Widget page) {
    _remember();
    _focus.unfocus();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _openAlbum(SearchAlbum a) {
    final files = [for (final path in a.paths) File(path)];
    final cache = <String, SongMetadata>{
      for (final path in a.paths)
        path: () {
          final m = widget.resolveMeta(path);
          return SongMetadata(title: m.title, artist: m.artist, album: m.album);
        }(),
    };
    _push(AlbumDetailPage(
      albumName: a.name,
      songs: files,
      metadataCache: cache,
      isDarkMode: widget.isDark,
      onPlay: (path, _) => widget.onPlay(path, a.paths),
    ));
  }

  void _openArtist(SearchArtist a) {
    final songs = <Song>[
      for (final path in a.paths)
        () {
          final m = widget.resolveMeta(path);
          final dir = File(path).parent.path;
          return Song(
            title: TitleCleaner.title(m.title, path: path),
            artist: a.name,
            album: (m.album ?? '').trim().isEmpty ? 'Unknown Album' : m.album!.trim(),
            filePath: path,
            folderPath: dir,
          );
        }(),
    ];
    final byFolder = <String, List<Song>>{};
    for (final s in songs) {
      byFolder.putIfAbsent(s.folderPath, () => []).add(s);
    }
    _push(ArtistDetailPage(
      artist: Artist(name: a.name, songsByFolder: byFolder),
      onPlay: (path, _) => widget.onPlay(path, a.paths),
    ));
  }

  void _openPlaylist(SearchPlaylist pl) {
    _push(ManagePlaylistPage(
      playlistName: pl.name,
      songPaths: List<String>.from(pl.paths),
      allFiles: widget.audioFiles,
      onPlay: (path, queue) => widget.onPlay(path, queue),
      loadCoverForFile: (f) => widget.loadCover(f.path),
    ));
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_focus.hasFocus,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _focus.unfocus(); // first back closes the keyboard
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          surfaceTintColor: Colors.transparent,
          foregroundColor: _text,
          elevation: 0,
          titleSpacing: 0,
          title: TextField(
            controller: _controller,
            focusNode: _focus,
            autofocus: true,
            textInputAction: TextInputAction.search,
            cursorColor: _accent,
            style: TextStyle(color: _text, fontSize: 17),
            onChanged: _onChanged,
            onTap: () => setState(() {}),
            onSubmitted: (v) {
              _debounce?.cancel();
              _run(v);
              _remember();
              _focus.unfocus();
            },
            decoration: InputDecoration(
              hintText: context.l10n.searchHint,
              hintStyle: TextStyle(color: _sub, fontSize: 16),
              border: InputBorder.none,
            ),
          ),
          actions: [
            if (_controller.text.isNotEmpty)
              IconButton(
                tooltip: context.l10n.searchClearText,
                icon: Icon(Icons.close_rounded, color: _text),
                onPressed: _clearField,
              ),
          ],
          bottom: _searching
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(minHeight: 2, color: _accent, backgroundColor: Colors.transparent),
                )
              : null,
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    if (_controller.text.trim().isEmpty) return _historyView();
    if (_index == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_query.isNotEmpty && _results.isEmpty && !_searching) return _emptyView();

    final children = <Widget>[];
    var n = 0;
    void header(String label, int count) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 6),
        child: Semantics(
          header: true,
          child: Text('$label  $count', style: TextStyle(color: _accent, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: .4)),
        ),
      ));
    }

    Widget row(Widget child) => FadeSlideIn(
          key: ValueKey('r${n}_$_query'),
          index: (n++).clamp(0, 8),
          offset: 10,
          duration: Motion.medium,
          child: child,
        );

    if (_results.songs.isNotEmpty) {
      header(context.l10n.searchSongs, _results.songs.length);
      for (final s in _results.songs) {
        children.add(row(_tile(
          semantics: context.l10n.searchSongSemantics(s.title, s.artist.isEmpty ? '' : context.l10n.searchBy(s.artist)),
          path: s.path,
          title: s.title,
          subtitle: [if (s.artist.isNotEmpty) s.artist, if (s.album.isNotEmpty) s.album].join(' · '),
          onTap: () => _playSong(s),
        )));
      }
    }
    if (_results.albums.isNotEmpty) {
      header(context.l10n.searchAlbums, _results.albums.length);
      for (final a in _results.albums) {
        children.add(row(_tile(
          semantics: context.l10n.searchAlbumSemantics(a.name, a.paths.length),
          path: a.paths.first,
          icon: Icons.album_rounded,
          title: a.name,
          subtitle: [if (a.artist.isNotEmpty) a.artist, context.l10n.songCount(a.paths.length)].join(' · '),
          onTap: () => _openAlbum(a),
        )));
      }
    }
    if (_results.artists.isNotEmpty) {
      header(context.l10n.searchArtists, _results.artists.length);
      for (final a in _results.artists) {
        children.add(row(_tile(
          semantics: context.l10n.searchArtistSemantics(a.name, a.paths.length),
          path: a.paths.first,
          icon: Icons.person_rounded,
          round: true,
          title: a.name,
          subtitle: context.l10n.songCount(a.paths.length),
          onTap: () => _openArtist(a),
        )));
      }
    }
    if (_results.playlists.isNotEmpty) {
      header(context.l10n.searchPlaylists, _results.playlists.length);
      for (final pl in _results.playlists) {
        children.add(row(_tile(
          semantics: context.l10n.searchPlaylistSemantics(pl.name, pl.paths.length),
          icon: Icons.queue_music_rounded,
          title: pl.name,
          subtitle: context.l10n.songCount(pl.paths.length),
          onTap: () => _openPlaylist(pl),
        )));
      }
    }

    return NotificationListener<ScrollStartNotification>(
      onNotification: (_) {
        if (_focus.hasFocus) _focus.unfocus();
        return false;
      },
      child: ListView(padding: const EdgeInsets.only(bottom: 32), children: children),
    );
  }

  Widget _tile({
    required String semantics,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    String? path,
    IconData icon = Icons.music_note_rounded,
    bool round = false,
  }) {
    return Semantics(
      button: true,
      label: semantics,
      excludeSemantics: true,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Material(
          color: _card,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                _Thumb(path: path, icon: icon, round: round, load: widget.loadCover, fg: _sub, bg: _bg),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _highlighted(title, TextStyle(color: _text, fontSize: 15, fontWeight: FontWeight.w600)),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      _highlighted(subtitle, TextStyle(color: _sub, fontSize: 13)),
                    ],
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _highlighted(String text, TextStyle style) {
    final ranges = SearchService.highlightRanges(text, _tokens);
    if (ranges.isEmpty) {
      return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    }
    final spans = <TextSpan>[];
    var at = 0;
    for (final r in ranges) {
      if (r.$1 > at) spans.add(TextSpan(text: text.substring(at, r.$1)));
      spans.add(TextSpan(text: text.substring(r.$1, r.$2), style: TextStyle(color: _accent, fontWeight: FontWeight.w800)));
      at = r.$2;
    }
    if (at < text.length) spans.add(TextSpan(text: text.substring(at)));
    return Text.rich(TextSpan(style: style, children: spans), maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  Widget _emptyView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.search_off_rounded, size: 56, color: _sub),
          const SizedBox(height: 12),
          Text(context.l10n.searchNothingFound(_query), textAlign: TextAlign.center, style: TextStyle(color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(context.l10n.searchNothingFoundHint, textAlign: TextAlign.center, style: TextStyle(color: _sub)),
        ]),
      ),
    );
  }

  Widget _historyView() {
    if (_history.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.manage_search_rounded, size: 56, color: _sub),
            const SizedBox(height: 12),
            Text(context.l10n.searchLibraryTitle, style: TextStyle(color: _text, fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(context.l10n.searchLibraryHint, textAlign: TextAlign.center, style: TextStyle(color: _sub)),
          ]),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
          child: Row(children: [
            Expanded(child: Semantics(header: true, child: Text(context.l10n.searchRecent, style: TextStyle(color: _accent, fontWeight: FontWeight.w700, fontSize: 13, letterSpacing: .4)))),
            TextButton(
              onPressed: () async {
                await SearchHistory.clear();
                if (mounted) setState(() => _history = const []);
              },
              child: Text(context.l10n.searchClearAll, style: TextStyle(color: _accent)),
            ),
          ]),
        ),
        for (final q in _history)
          Dismissible(
            key: ValueKey('h_$q'),
            background: Container(color: Colors.red.withValues(alpha: .25)),
            onDismissed: (_) async {
              final h = await SearchHistory.remove(q);
              if (mounted) setState(() => _history = h);
            },
            child: ListTile(
              leading: Icon(Icons.history_rounded, color: _sub),
              title: Text(q, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: _text)),
              trailing: IconButton(
                tooltip: context.l10n.searchRemoveRecent(q),
                icon: Icon(Icons.close_rounded, color: _sub, size: 20),
                onPressed: () async {
                  final h = await SearchHistory.remove(q);
                  if (mounted) setState(() => _history = h);
                },
              ),
              onTap: () => _useHistory(q),
            ),
          ),
      ],
    );
  }
}

class _Thumb extends StatefulWidget {
  final String? path;
  final IconData icon;
  final bool round;
  final Future<Uint8List?> Function(String) load;
  final Color fg;
  final Color bg;
  const _Thumb({required this.path, required this.icon, required this.round, required this.load, required this.fg, required this.bg});

  @override
  State<_Thumb> createState() => _ThumbState();
}

class _ThumbState extends State<_Thumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    final path = widget.path;
    if (path != null) {
      widget.load(path).then((b) {
        if (mounted && b != null) setState(() => _bytes = b);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.round ? 24 : 10);
    return ClipRRect(
      borderRadius: radius,
      child: SizedBox(
        width: 48,
        height: 48,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover, cacheWidth: 144, gaplessPlayback: true, excludeFromSemantics: true)
            : Container(color: widget.bg, child: Icon(widget.icon, color: widget.fg, size: 22)),
      ),
    );
  }
}
