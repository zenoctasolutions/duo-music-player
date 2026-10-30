import 'package:flutter_test/flutter_test.dart';
import 'package:music/library/m3u_service.dart';

void main() {
  group('encode', () {
    test('relative paths under common folder', () {
      final s = M3uService.encode('Mix', ['/m/a/one.mp3', '/m/a/sub/two.mp3'],
          durationOf: (p) => 61, titleOf: (p) => p.contains('one') ? 'One' : null, artistOf: (p) => 'Art');
      expect(s.split('\n')[0], '#EXTM3U');
      expect(s, contains('#PLAYLIST:Mix'));
      expect(s, contains('#EXTINF:61,Art - One'));
      expect(s, contains('\none.mp3\n'));
      expect(s, contains('\nsub/two.mp3\n'));
    });
    test('absolute when no common folder', () {
      final s = M3uService.encode('x', ['/a/one.mp3', '/b/two.mp3']);
      expect(s, contains('\n/a/one.mp3\n'));
      expect(s, contains('#EXTINF:-1,one'));
    });
    test('single track and empty', () {
      expect(M3uService.encode('x', ['/m/a/one.mp3']), contains('\none.mp3\n'));
      expect(M3uService.encode('x', []), startsWith('#EXTM3U'));
    });
  });

  group('parse', () {
    test('BOM, CRLF, comments, EXTINF, relative', () {
      final c = '\uFEFF#EXTM3U\r\n# comment\r\n#EXTINF:215,Artist - Song\r\nsub/a.mp3\r\n\r\n/abs/b.mp3\r\n';
      final e = M3uService.parse(c, baseDir: '/sd/pl');
      expect(e.length, 2);
      expect(e[0].path, '/sd/pl/sub/a.mp3');
      expect(e[0].durationSec, 215);
      expect(e[0].extTitle, 'Artist - Song');
      expect(e[1].path, '/abs/b.mp3');
      expect(e[1].extTitle, isNull);
    });
    test('file URI, percent-encoding, backslashes, dotdot, urls skipped', () {
      final c = 'file:///sd/My%20Music/a%20b.mp3\n..\\x\\c.mp3\nhttp://stream/x\n/sd/100%25.mp3\n';
      final e = M3uService.parse(c, baseDir: '/sd/pl');
      expect(e.map((x) => x.path).toList(), ['/sd/My Music/a b.mp3', '/sd/x/c.mp3', '/sd/100%.mp3']);
    });
    test('negative duration is null; lone CR', () {
      final e = M3uService.parse('#EXTINF:-1,T\r/a.mp3', baseDir: '/');
      expect(e.single.durationSec, isNull);
      expect(e.single.extTitle, 'T');
    });
    test('roundtrip', () {
      final paths = ['/m/x/a b.mp3', '/m/x/c.mp3'];
      final e = M3uService.parse(M3uService.encode('n', paths), baseDir: '/m/x');
      expect(e.map((x) => x.path).toList(), paths);
    });
  });

  group('resolve', () {
    final lib = ['/storage/Music/Alpha.mp3', '/storage/Music/Beta/Song.mp3', '/storage/Other/Song.mp3', '/storage/Music/03 - Gamma [www.iSongs.info].mp3'];
    test('exact, basename, ambiguous, title, unresolved', () {
      final entries = M3uService.parse(
          '/storage/Music/Alpha.mp3\n/old/ALPHA.MP3\n/old/Song.mp3\n#EXTINF:1,Gamma\n/old/zzz.mp3\n/old/missing.mp3\n',
          baseDir: '/');
      final r = M3uService.resolve(entries, lib);
      expect(r.matched.map((m) => m.how).toList(), ['path', 'title']);
      expect(r.matched[1].libraryPath, lib[3]);
      // Alpha dup collapsed; Song ambiguous -> unresolved
      expect(r.unresolved.map((e) => e.path), contains('/old/Song.mp3'));
      expect(r.unresolved.length, 2);
    });
    test('unique basename case-insensitive', () {
      final r = M3uService.resolve(M3uService.parse('C:\\Users\\me\\ALPHA.mp3', baseDir: '/'), lib);
      expect(r.matched.single.how, 'basename');
      expect(r.matched.single.libraryPath, lib[0]);
    });
  });
}
