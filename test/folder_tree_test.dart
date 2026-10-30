import 'package:flutter_test/flutter_test.dart';
import 'package:music/library/folders/folder_tree.dart';

void main() {
  final paths = [
    '/storage/emulated/0/Music/Rock/a.mp3',
    '/storage/emulated/0/Music/Rock/b.mp3',
    '/storage/emulated/0/Music/Pop/c.mp3',
    '/storage/emulated/0/Download/d.mp3',
    '/storage/1234-ABCD/Songs/2020/e.mp3',
  ];

  test('detects internal and SD roots', () {
    final t = FolderTree.build(paths);
    expect(t.roots.map((r) => r.path), ['/storage/emulated/0', '/storage/1234-ABCD']);
    expect(t.roots[0].rootLabel, 'Internal storage');
    expect(t.roots[1].rootLabel, 'SD card (1234-ABCD)');
  });

  test('recursive counts', () {
    final t = FolderTree.build(paths);
    expect(t.roots[0].totalCount, 4);
    expect(t.nodeFor('/storage/emulated/0/Music')!.totalCount, 3);
    expect(t.nodeFor('/storage/emulated/0/Music/Rock')!.songs.length, 2);
    expect(t.roots[1].totalCount, 1);
  });

  test('sorted children A-Z case-insensitive', () {
    final t = FolderTree.build([
      '/storage/emulated/0/b/x.mp3',
      '/storage/emulated/0/A/x.mp3',
      '/storage/emulated/0/c/x.mp3',
    ]);
    expect(t.roots[0].sortedChildren().map((c) => c.name), ['A', 'b', 'c']);
  });

  test('single-child chains collapse', () {
    final t = FolderTree.build(paths);
    final sd = t.roots[1];
    final songs = sd.sortedChildren().single;
    expect(songs.collapsed().path, '/storage/1234-ABCD/Songs/2020');
    expect(songs.collapsedLabel(), 'Songs/2020');
    final music = t.nodeFor('/storage/emulated/0/Music')!;
    expect(music.collapsed(), same(music));
  });

  test('trailing and duplicate slashes', () {
    final t = FolderTree.build(['/storage/emulated/0//Music//a.mp3']);
    expect(t.nodeFor('/storage/emulated/0/Music/')!.songs, ['/storage/emulated/0/Music/a.mp3']);
  });

  test('files directly at root, sdcard alias, trail', () {
    final t = FolderTree.build(['/storage/emulated/0/a.mp3', '/sdcard/Music/b.mp3']);
    expect(t.roots.length, 2);
    final n = FolderTree.build(paths).nodeFor('/storage/emulated/0/Music/Rock')!;
    expect(n.trail().map((e) => e.name), ['Internal storage', 'Music', 'Rock']);
    expect(n.parent!.allSongs().length, 3);
  });

  test('empty input', () {
    expect(FolderTree.build(const []).roots, isEmpty);
  });
}
