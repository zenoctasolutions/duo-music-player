import 'package:flutter_test/flutter_test.dart';
import 'package:music/search/search_history.dart';
import 'package:music/search/search_service.dart';

SearchIndex idx() => SearchService.buildIndex(const [
      SearchInput(path: '/m/Rock/believer-1.mp3', title: 'Believer [www.SenSongsMp3.co]', artist: 'Imagine Dragons', album: 'Evolve'),
      SearchInput(path: '/m/Rock/thunder.mp3', title: 'Thunder', artist: 'Imagine Dragons', album: 'Evolve'),
      SearchInput(path: '/m/Pop/cafe.mp3', title: 'Café del Mar', artist: 'Énergie', album: 'Chill'),
      SearchInput(path: '/m/Pop/x.mp3', title: 'The Believer Song', artist: 'Someone', album: 'Misc'),
      SearchInput(path: '/m/Pop/y.mp3', title: 'Disbelief', artist: 'Other', album: 'Misc'),
    ], playlists: const {
      'Road Trip': ['/m/Rock/thunder.mp3'],
      'Gym': [],
    });

void main() {
  test('tokenise folds case, punctuation and diacritics', () {
    expect(SearchService.tokenize('  Café--DEL, Mar '), ['cafe', 'del', 'mar']);
    expect(SearchService.fold('Énergie'), 'energie');
  });

  test('diacritics match both ways', () {
    expect(idx().search('cafe').songs.single.title, 'Café del Mar');
    expect(idx().search('CAFÉ').songs.single.title, 'Café del Mar');
    expect(idx().search('energie').artists.single.name, 'Énergie');
  });

  test('ranks prefix > word-start > substring', () {
    final titles = idx().search('belie').songs.map((s) => s.title).toList();
    expect(titles, ['Believer', 'The Believer Song', 'Disbelief']);
  });

  test('matches cleaned title, not site junk', () {
    expect(idx().search('sensongs').songs, isEmpty);
    expect(idx().search('believer').songs.first.title, 'Believer');
  });

  test('multi-token requires all tokens, any field', () {
    final r = idx().search('thunder imagine');
    expect(r.songs.single.title, 'Thunder');
    expect(idx().search('thunder zzz').isEmpty, isTrue);
  });

  test('matches file name and folder', () {
    expect(idx().search('thunder.mp3').songs.length, 1);
    expect(idx().search('pop').songs.length, 3);
  });

  test('groups albums, artists and playlists', () {
    final r = idx().search('evolve');
    expect(r.albums.single.paths.length, 2);
    expect(idx().search('imagine').artists.single.paths.length, 2);
    final pl = idx().search('road');
    expect(pl.playlists.single.name, 'Road Trip');
    expect(pl.playlists.single.paths, ['/m/Rock/thunder.mp3']);
    expect(idx().search('gym').playlists.single.paths, isEmpty);
  });

  test('empty query returns nothing', () {
    expect(idx().search('   ').isEmpty, isTrue);
  });

  test('highlight ranges map onto the original text', () {
    expect(SearchService.highlightRanges('Café del Mar', ['cafe']), [(0, 4)]);
    expect(SearchService.highlightRanges('The Believer', ['bel']), [(4, 7)]);
    expect(SearchService.highlightRanges('abc', ['x']), isEmpty);
  });

  test('history keeps 12 distinct, newest first', () {
    var h = <String>[];
    for (var i = 0; i < 15; i++) {
      h = SearchHistory.pushed(h, 'q$i');
    }
    expect(h.length, 12);
    expect(h.first, 'q14');
    h = SearchHistory.pushed(h, 'Q10');
    expect(h.first, 'Q10');
    expect(h.where((e) => e.toLowerCase() == 'q10').length, 1);
    expect(SearchHistory.pushed(h, '  ').length, h.length);
  });
}
