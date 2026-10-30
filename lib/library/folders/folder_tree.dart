// lib/library/folders/folder_tree.dart
//
// Pure-Dart folder tree over a flat list of audio file paths. No Flutter, no
// dart:io, so it is unit-testable. Only folders that (recursively) contain at
// least one given path exist in the tree.

class FolderNode {
  /// Absolute path without trailing slash ('/' for the filesystem root).
  final String path;

  /// Display name of this single segment.
  final String name;
  FolderNode? parent;
  final Map<String, FolderNode> _children = {};

  /// Full paths of the audio files directly inside this folder (unsorted).
  final List<String> songs = [];

  /// Set for storage roots (e.g. "Internal storage").
  String? rootLabel;

  FolderNode(this.path, this.name, [this.parent]);

  bool get isRoot => rootLabel != null;
  List<FolderNode> get children => _children.values.toList();

  int? _count;

  /// Number of songs in this folder and all sub-folders.
  int get totalCount =>
      _count ??= songs.length + _children.values.fold(0, (a, c) => a + c.totalCount);

  /// Sub-folders sorted A-Z (case-insensitive).
  List<FolderNode> sortedChildren() => children
    ..sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return c != 0 ? c : a.name.compareTo(b.name);
    });

  /// All songs below this folder (own first, then sub-folders A-Z).
  List<String> allSongs() {
    final out = <String>[...songs];
    for (final c in sortedChildren()) {
      out.addAll(c.allSongs());
    }
    return out;
  }

  /// First song found (own first, then descending) - used for cover art.
  String? get firstSong {
    if (songs.isNotEmpty) return songs.first;
    for (final c in sortedChildren()) {
      final s = c.firstSong;
      if (s != null) return s;
    }
    return null;
  }

  /// Follows chains of folders that hold no songs and have exactly one
  /// sub-folder (Music > Bollywood > 2020 with nothing else) and returns the
  /// deepest node of the chain, so the UI can show "Bollywood/2020" as one row.
  FolderNode collapsed() {
    var n = this;
    while (n.songs.isEmpty && n._children.length == 1) {
      n = n._children.values.first;
    }
    return n;
  }

  /// Label for the collapsed chain starting at this node ("A/B/C"), relative
  /// to this node.
  String collapsedLabel() {
    final end = collapsed();
    if (identical(end, this)) return name;
    final parts = <String>[name];
    var n = this;
    while (!identical(n, end)) {
      n = n._children.values.first;
      parts.add(n.name);
    }
    return parts.join('/');
  }

  /// Short display label for the collapsed chain: the last two segments,
  /// prefixed with an ellipsis when segments were dropped
  /// ("Android/media/com.whatsapp/WhatsApp" -> "…/com.whatsapp/WhatsApp").
  String collapsedShortLabel() {
    final parts = collapsedLabel().split('/');
    if (parts.length <= 2) return parts.join('/');
    return '…/${parts.sublist(parts.length - 2).join('/')}';
  }

  /// Ancestors from the storage root down to this node (inclusive).
  List<FolderNode> trail() {
    final out = <FolderNode>[];
    FolderNode? n = this;
    while (n != null) {
      out.insert(0, n);
      n = n.parent;
    }
    return out;
  }
}

class FolderTree {
  /// Storage roots (Internal storage, SD cards, ...), sorted: internal first.
  final List<FolderNode> roots;
  final Map<String, FolderNode> _byPath;
  FolderTree._(this.roots, this._byPath);

  FolderNode? nodeFor(String path) => _byPath[normalizeDir(path)];

  static final _emulated = RegExp(r'^/storage/emulated/\d+');
  static final _storage = RegExp(r'^/storage/[^/]+');

  static String normalizeDir(String d) {
    var s = d.replaceAll(RegExp(r'/{2,}'), '/');
    while (s.length > 1 && s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /// Returns (rootPath, label) for a directory path.
  static (String, String) rootOf(String dir) {
    final e = _emulated.firstMatch(dir);
    if (e != null) {
      final r = e.group(0)!;
      final user = r.substring('/storage/emulated/'.length);
      return (r, user == '0' ? 'Internal storage' : 'Internal storage ($user)');
    }
    final s = _storage.firstMatch(dir);
    if (s != null) {
      final r = s.group(0)!;
      final id = r.substring('/storage/'.length);
      if (id == 'self' || id == 'emulated') return (r, 'Internal storage');
      return (r, 'SD card ($id)');
    }
    if (dir == '/sdcard' || dir.startsWith('/sdcard/')) {
      return ('/sdcard', 'Internal storage');
    }
    return ('/', '/');
  }

  static String _dirname(String path) {
    final i = path.lastIndexOf('/');
    if (i <= 0) return '/';
    return path.substring(0, i);
  }

  static FolderTree build(Iterable<String> filePaths) {
    final byPath = <String, FolderNode>{};
    final roots = <String, FolderNode>{};

    FolderNode ensure(String dir) {
      final existing = byPath[dir];
      if (existing != null) return existing;
      final (rootPath, label) = rootOf(dir);
      if (dir == rootPath) {
        final r = roots.putIfAbsent(rootPath, () {
          final n = FolderNode(rootPath, label);
          n.rootLabel = label;
          return n;
        });
        byPath[dir] = r;
        return r;
      }
      final parent = ensure(_dirname(dir));
      final name = dir.substring(dir.lastIndexOf('/') + 1);
      final node = FolderNode(dir, name, parent);
      parent._children[name] = node;
      return byPath[dir] = node;
    }

    for (final raw in filePaths) {
      final path = raw.replaceAll(RegExp(r'/{2,}'), '/');
      if (!path.startsWith('/')) continue;
      final dir = normalizeDir(_dirname(path));
      ensure(dir).songs.add(path);
    }

    final list = roots.values.toList()
      ..sort((a, b) {
        int rank(FolderNode n) => n.path.startsWith('/storage/emulated') || n.path == '/sdcard' ? 0 : 1;
        final r = rank(a).compareTo(rank(b));
        return r != 0 ? r : a.path.compareTo(b.path);
      });
    return FolderTree._(list, byPath);
  }
}
