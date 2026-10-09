import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:music/library_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    LibraryInfo.durationMs.clear();
    LibraryInfo.dateAdded.clear();
  });

  group('LibraryFilter', () {
    test('hides songs inside an excluded folder and its subfolders only', () async {
      await LibraryFilter.setMinDuration(0);
      await LibraryFilter.setExcluded({'/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes/'});
      expect(LibraryFilter.allows('/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes/2026/a.opus'), isFalse);
      expect(LibraryFilter.allows('/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes/b.opus'), isFalse);
      expect(LibraryFilter.allows('/storage/emulated/0/WhatsApp/Media/WhatsApp Voice Notes Old/c.mp3'), isTrue);
      expect(LibraryFilter.allows('/storage/emulated/0/Music/song.mp3'), isTrue);
    });

    test('minimum duration hides short clips but never songs of unknown length', () async {
      await LibraryFilter.setExcluded({});
      await LibraryFilter.setMinDuration(30);
      LibraryInfo.durationMs['/m/short.mp3'] = 5000;
      LibraryInfo.durationMs['/m/long.mp3'] = 180000;
      expect(LibraryFilter.allows('/m/short.mp3'), isFalse);
      expect(LibraryFilter.allows('/m/long.mp3'), isTrue);
      expect(LibraryFilter.allows('/m/unknown.mp3'), isTrue);
      expect(LibraryFilter.allows('/m/fallback.mp3', knownDurationMs: 10000), isFalse);
      await LibraryFilter.setMinDuration(0);
      expect(LibraryFilter.allows('/m/short.mp3'), isTrue);
    });
  });

  group('PlayStats', () {
    test('counts plays, ignores duplicate reports of one start, ranks most played', () async {
      await PlayStats.recordPlay('/m/a.mp3');
      await PlayStats.recordPlay('/m/a.mp3'); // same start reported twice
      await PlayStats.recordPlay('/m/b.mp3');
      await PlayStats.recordPlay('/m/a.mp3'); // a genuinely new play (different song in between)
      expect(PlayStats.countFor('/m/a.mp3'), 2);
      expect(PlayStats.countFor('/m/b.mp3'), 1);
      final ranked = PlayStats.mostPlayed([File('/m/b.mp3'), File('/m/a.mp3'), File('/m/c.mp3')]);
      expect(ranked.map((f) => f.path), ['/m/a.mp3', '/m/b.mp3']);
    });

    test('recently added sorts newest first', () {
      LibraryInfo.dateAdded['/m/old.mp3'] = 1000;
      LibraryInfo.dateAdded['/m/new.mp3'] = 5000;
      final list = PlayStats.recentlyAdded([File('/m/old.mp3'), File('/m/new.mp3')]);
      expect(list.first.path, '/m/new.mp3');
    });
  });
}
