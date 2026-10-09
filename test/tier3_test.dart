import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music/artwork_service.dart';
import 'package:music/auto_browse.dart';
import 'package:music/lastfm_service.dart';
import 'package:music/position_memory_service.dart';
import 'package:music/queue_manager.dart';

void main() {
  group('Android Auto browse tree', () {
    final lib = AutoLibrary(
      allPaths: const ['/m/a.mp3', '/m/b.mp3', '/m/c.mp3'],
      title: (p) => {'/m/a.mp3': 'Alpha', '/m/b.mp3': 'Bravo', '/m/c.mp3': 'Charlie'}[p]!,
      artist: (p) => p == '/m/c.mp3' ? 'Queen' : 'Zen',
      favorites: const {'/m/b.mp3'},
      recent: const ['/m/c.mp3', '/gone.mp3', '/m/a.mp3'],
      playlists: const {'Road trip': ['/m/c.mp3', '/m/a.mp3']},
    );

    test('root lists the categories', () {
      final root = AutoBrowse.children(AudioService.browsableRootId, lib);
      expect(root.map((m) => m.title), ['Recently played', 'Favorites', 'Most played', 'Recently added', 'Playlists', 'All songs']);
      expect(root.every((m) => m.playable == false), isTrue);
    });

    test('categories drop missing files and are playable songs', () {
      final recent = AutoBrowse.children(AutoBrowse.catRecent, lib);
      expect(recent.map((m) => m.title), ['Charlie', 'Alpha']);
      expect(recent.first.playable, isTrue);
      expect(AutoBrowse.children(AutoBrowse.catFavorites, lib).single.title, 'Bravo');
      final playlists = AutoBrowse.children(AutoBrowse.catPlaylists, lib);
      expect(playlists.single.title, 'Road trip');
      expect(AutoBrowse.children(playlists.single.id, lib).map((m) => m.title), ['Charlie', 'Alpha']);
    });

    test('tapping a song queues its category from that song', () {
      final item = AutoBrowse.children(AutoBrowse.catAll, lib)[1];
      final r = AutoBrowse.resolvePlay(item.id, lib)!;
      expect(r.$1, ['/m/a.mp3', '/m/b.mp3', '/m/c.mp3']);
      expect(r.$2, 1);
      expect(AutoBrowse.resolvePlay('song|cat:all|/nope.mp3', lib), isNull);
    });

    test('voice search matches titles first, then artists; empty = recent', () {
      expect(AutoBrowse.search('brav', lib), ['/m/b.mp3']);
      expect(AutoBrowse.search('queen', lib), ['/m/c.mp3']);
      expect(AutoBrowse.search('', lib), ['/m/c.mp3', '/m/a.mp3']);
    });
  });

  group('Multiple queues', () {
    test('edits are not replacements', () {
      const q = ['a', 'b', 'c', 'd'];
      expect(QueueManager.isReplacement(q, ['a', 'b', 'c', 'd']), isFalse);
      expect(QueueManager.isReplacement(q, ['a', 'b', 'c', 'd', 'e']), isFalse); // add to queue
      expect(QueueManager.isReplacement(q, ['a', 'c', 'd']), isFalse); // remove one
      expect(QueueManager.isReplacement(q, ['d', 'c', 'b', 'a']), isFalse); // reorder
    });
    test('a different list is a replacement', () {
      const q = ['a', 'b', 'c', 'd', 'e'];
      // Same songs minus one but in a different order (e.g. Most Played).
      expect(QueueManager.isReplacement(q, ['c', 'a', 'b', 'd']), isTrue);
      expect(QueueManager.isReplacement(q, ['x', 'y']), isTrue);
      // Different source page always counts.
      expect(QueueManager.isReplacement(q, ['a', 'b', 'c', 'd'], prevPage: 'songs', nextPage: 'most_played'), isTrue);
      expect(QueueManager.isReplacement(null, ['x']), isFalse);
    });
  });

  group('Audiobook mode', () {
    test('long files and audiobook folders qualify', () {
      expect(PositionMemoryService.qualifies(path: '/m/mix.mp3', duration: const Duration(minutes: 45), minMinutes: 20, audiobookFolders: false), isTrue);
      expect(PositionMemoryService.qualifies(path: '/m/song.mp3', duration: const Duration(minutes: 4), minMinutes: 20, audiobookFolders: true), isFalse);
      expect(PositionMemoryService.qualifies(path: '/s/Audiobooks/ch1.mp3', duration: const Duration(minutes: 4), minMinutes: 20, audiobookFolders: true), isTrue);
      expect(PositionMemoryService.qualifies(path: '/s/Podcasts/ep.mp3', duration: null, minMinutes: 20, audiobookFolders: true), isTrue);
      expect(PositionMemoryService.qualifies(path: '/s/Audiobooks/ch1.mp3', duration: const Duration(minutes: 4), minMinutes: 20, audiobookFolders: false), isFalse);
    });
  });

  group('Album art lookup', () {
    test('album cache key is shared across songs of an album', () {
      expect(ArtworkService.keyFor(artist: 'Queen', album: 'A Night at the Opera', title: 'x'),
          ArtworkService.keyFor(artist: 'QUEEN', album: 'A Night At The Opera!', title: 'y'));
    });
    test('picks the result with matching artist and album only', () {
      final results = <Map>[
        {'artistName': 'Queen Latifah', 'collectionName': 'Black Reign', 'artworkUrl100': 'x'},
        {'artistName': 'Queen', 'collectionName': 'A Night at the Opera (Deluxe)', 'artworkUrl100': 'right'},
      ];
      expect(ArtworkService.pickBest(results, artist: 'Queen', album: 'A Night at the Opera')?['artworkUrl100'], 'right');
      expect(ArtworkService.pickBest(results, artist: 'Queen', album: 'Jazz'), isNull);
      expect(ArtworkService.pickBest(results, artist: 'Beatles', album: 'Abbey Road'), isNull);
    });
    test('multi-artist tags, soundtrack suffixes and site names still match', () {
      final results = <Map>[
        {'artistName': 'Mithoon', 'collectionName': 'Bollywood Unplugged', 'trackName': 'Tum Hi Ho (Instrumental)', 'artworkUrl100': 'wrong'},
        {'artistName': 'Mithoon & Arijit Singh', 'collectionName': 'Aashiqui 2 (Original Motion Picture Soundtrack)', 'trackName': 'Tum Hi Ho', 'artworkUrl100': 'right'},
      ];
      expect(
          ArtworkService.pickBest(results,
              artist: 'Mithoon, Ankit Tiwari & Jeet Gannguli', album: 'Aashiqui 2 (2013)', title: 'Tum Hi Ho - PagalWorld.com')?['artworkUrl100'],
          'right');
      // Artist alone is not enough.
      expect(ArtworkService.pickBest(results, artist: 'Mithoon', album: 'Something Else', title: 'Other Song'), isNull);
    });
    test('artist split and album cleaning', () {
      expect(ArtworkService.splitArtists('Mithoon, Ankit Tiwari & Jeet Gannguli'), ['Mithoon', 'Ankit Tiwari', 'Jeet Gannguli']);
      expect(ArtworkService.splitArtists('Stay feat. Justin Bieber'), ['Stay', 'Justin Bieber']);
      expect(ArtworkService.cleanAlbum('Aashiqui 2 (2013) - PagalWorld.com'), 'Aashiqui 2');
      expect(ArtworkService.cleanAlbum('<unknown>'), '');
    });
  });

  group('Last.fm', () {
    test('api_sig follows the documented algorithm', () {
      // md5("api_keyxxxxmethodauth.getMobileSessionpasswordpwusernameuserSECRET")
      final sig = LastFmService.signature(
        {'method': 'auth.getMobileSession', 'username': 'user', 'password': 'pw', 'api_key': 'xxxx', 'format': 'json'},
        'SECRET',
      );
      expect(sig, '6ff857ea7a9a6b9a75c0f3796bdbd9c2');
    });
    test('scrobble after half the track or 4 minutes, never for <30 s', () {
      expect(LastFmService.shouldScrobble(duration: const Duration(minutes: 3), listened: const Duration(seconds: 89)), isFalse);
      expect(LastFmService.shouldScrobble(duration: const Duration(minutes: 3), listened: const Duration(seconds: 90)), isTrue);
      expect(LastFmService.shouldScrobble(duration: const Duration(minutes: 20), listened: const Duration(minutes: 4)), isTrue);
      expect(LastFmService.shouldScrobble(duration: const Duration(seconds: 25), listened: const Duration(seconds: 25)), isFalse);
    });
  });
}
