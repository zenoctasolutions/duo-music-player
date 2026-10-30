// lib/library/widgets/playlist_mosaic.dart
//
// 2x2 cover mosaic for a playlist (first four tracks that have art), with a
// gradient placeholder when there is none. Covers load lazily via the same
// loader the playlist pages already receive.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class PlaylistMosaic extends StatefulWidget {
  final List<String> paths;
  final Future<Uint8List?> Function(File file) loadCover;
  final double size;
  final double radius;
  final List<Color> placeholder;

  const PlaylistMosaic({
    super.key,
    required this.paths,
    required this.loadCover,
    required this.placeholder,
    this.size = 64,
    this.radius = 16,
  });

  @override
  State<PlaylistMosaic> createState() => _PlaylistMosaicState();
}

class _PlaylistMosaicState extends State<PlaylistMosaic> {
  List<Uint8List> _covers = const [];
  bool _loaded = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PlaylistMosaic old) {
    super.didUpdateWidget(old);
    final a = old.paths.take(8).join('|');
    final b = widget.paths.take(8).join('|');
    if (a != b) _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final found = <Uint8List>[];
    // Look through a few extra tracks in case some have no art.
    for (final path in widget.paths.take(8)) {
      if (found.length >= 4) break;
      try {
        final b = await widget.loadCover(File(path));
        if (b != null && b.isNotEmpty) found.add(b);
      } catch (_) {}
    }
    if (!mounted || gen != _gen) return;
    setState(() {
      _covers = found;
      _loaded = true;
    });
  }

  Widget _img(Uint8List b) => Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 160);

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    Widget inner;
    if (_covers.isEmpty) {
      inner = Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: widget.placeholder),
        ),
        child: Center(child: Icon(Icons.queue_music_rounded, color: Colors.white.withOpacity(_loaded ? 0.95 : 0.6), size: s * 0.46)),
      );
    } else if (_covers.length < 4) {
      inner = _img(_covers.first);
    } else {
      inner = Column(children: [
        for (var r = 0; r < 2; r++)
          Expanded(
            child: Row(children: [
              for (var c = 0; c < 2; c++) Expanded(child: SizedBox.expand(child: _img(_covers[r * 2 + c]))),
            ]),
          ),
      ]);
    }
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.radius),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: ClipRRect(borderRadius: BorderRadius.circular(widget.radius), child: inner),
    );
  }
}

/// Deterministic gradient per playlist name.
List<Color> playlistGradientFor(String name) {
  const g = [
    [Color(0xFF7C4DFF), Color(0xFFD946EF)],
    [Color(0xFFFF9A3C), Color(0xFFFF4E78)],
    [Color(0xFF22D3EE), Color(0xFF4F46E5)],
    [Color(0xFF34D399), Color(0xFF0EA5A4)],
    [Color(0xFFFFB020), Color(0xFFE5254B)],
    [Color(0xFF6366F1), Color(0xFFDB2777)],
  ];
  var h = 0;
  for (final u in name.codeUnits) {
    h = (h * 31 + u) & 0x7fffffff;
  }
  return g[h % g.length];
}
