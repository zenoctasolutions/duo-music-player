import 'package:flutter_test/flutter_test.dart';
import 'package:music/audio_effects_service.dart';
import 'package:music/crossfade_service.dart';
import 'package:music/lyrics_service.dart';
import 'package:music/tag_editor_service.dart';

void main() {
  group('Pasted lyrics sync (TC3)', () {
    test('timed lines without LRC brackets are recognised as synced', () {
      final r = LrcParser.parse('00:12.50 First line\n(0:15) Second line\n00:20 Third');
      expect(r.synced, isTrue);
      expect(r.lines.map((l) => l.text), ['First line', 'Second line', 'Third']);
      expect(r.lines.first.time, const Duration(seconds: 12, milliseconds: 500));
    });

    test('a single lyric starting with a time stays plain', () {
      final r = LrcParser.parse('2:30 in the morning\nstill awake\nthinking of you');
      expect(r.synced, isFalse);
    });

    test('toLrc round-trips through the parser', () {
      final lines = [
        const LyricLine(Duration(seconds: 3, milliseconds: 250), 'Hello'),
        const LyricLine(Duration(minutes: 1, seconds: 2), 'World'),
      ];
      final lrc = LrcParser.toLrc(lines);
      expect(lrc, '[00:03.25]Hello\n[01:02.00]World');
      final back = LrcParser.parse(lrc);
      expect(back.synced, isTrue);
      expect(back.lines.map((l) => l.time), lines.map((l) => l.time));
    });

    test('cleanTitle strips filename / video noise for the online lookup', () {
      expect(LyricsService.cleanTitle('Shape of You (Official Video) [320kbps]'), 'Shape of You');
      expect(LyricsService.cleanTitle('03 - Numb'), 'Numb');
      expect(LyricsService.cleanTitle('Ed Sheeran - Perfect', artist: 'Ed Sheeran'), 'Perfect');
      expect(LyricsService.cleanTitle('Linkin Park - In the End'), 'In the End');
      expect(LyricsService.cleanTitle('Stay feat. Justin Bieber'), 'Stay');
      expect(LyricsService.cleanTitle('Believer - Remix', artist: 'Imagine Dragons'), 'Believer - Remix');
    });
  });

  group('LrcParser', () {
    test('plain lyrics are not treated as synced', () {
      final r = LrcParser.parse('\nFirst line\nSecond line\n\n');
      expect(r.synced, isFalse);
      expect(r.lines.map((l) => l.text), ['First line', 'Second line']);
    });

    test('parses timestamps, metadata tags, multi-stamps, offset and word tags', () {
      final r = LrcParser.parse('''
[ar:Artist]
[ti:Song]
[offset:+500]
[00:12.50]Hello <00:12.60>world
[00:05.00][00:20.00]Chorus
[01:02.3]Late line''');
      expect(r.synced, isTrue);
      expect(r.lines.map((l) => l.text).toList(), ['Chorus', 'Hello world', 'Chorus', 'Late line']);
      // +500 ms offset shifts everything earlier.
      expect(r.lines.first.time, const Duration(milliseconds: 4500));
      expect(r.lines[1].time, const Duration(milliseconds: 12000));
      expect(r.lines.last.time, const Duration(minutes: 1, milliseconds: 1800));
    });

    test('indexAt finds the line being sung', () {
      final lines = LrcParser.parse('[00:01.00]a\n[00:05.00]b\n[00:09.00]c').lines;
      expect(LrcParser.indexAt(lines, Duration.zero), -1);
      expect(LrcParser.indexAt(lines, const Duration(seconds: 5)), 1);
      expect(LrcParser.indexAt(lines, const Duration(seconds: 30)), 2);
    });
  });

  group('Volume normalization parsing', () {
    test('ReplayGain and R128 tags convert to LUFS', () {
      // RG gain of -6.5 dB relative to -18 LUFS => track is at -11.5 LUFS.
      expect(AudioEffectsService.loudnessFromTagMap({'replaygain_track_gain': '-6.50 dB'}), closeTo(-11.5, 0.001));
      expect(AudioEffectsService.loudnessFromTagMap({'replaygain_track_gain': '+2.00 dB'}), closeTo(-20.0, 0.001));
      // R128 Q7.8: -1280/256 = -5 dB relative to -23 => -18 LUFS.
      expect(AudioEffectsService.loudnessFromTagMap({'r128_track_gain': '-1280'}), closeTo(-18.0, 0.001));
      expect(AudioEffectsService.loudnessFromTagMap({'title': 'x'}), isNull);
    });

    test('ebur128 summary parsing takes the integrated value and ignores silence', () {
      const log = '[Parsed_ebur128_0] Summary:\n  Integrated loudness:\n    I:         -9.8 LUFS\n    Threshold: -20.1 LUFS';
      expect(AudioEffectsService.parseIntegratedLoudness(log), closeTo(-9.8, 0.001));
      expect(AudioEffectsService.parseIntegratedLoudness('I:  -70.0 LUFS'), isNull);
      expect(AudioEffectsService.parseIntegratedLoudness('nothing here'), isNull);
    });
  });

  group('Crossfade trigger', () {
    const dur = Duration(minutes: 3);
    test('starts only inside the last N seconds while playing', () {
      expect(CrossfadeService.shouldStart(seconds: 6, position: const Duration(seconds: 170), duration: dur, playing: true), isFalse);
      expect(CrossfadeService.shouldStart(seconds: 6, position: const Duration(seconds: 175), duration: dur, playing: true), isTrue);
      expect(CrossfadeService.shouldStart(seconds: 6, position: const Duration(seconds: 175), duration: dur, playing: false), isFalse);
      expect(CrossfadeService.shouldStart(seconds: 0, position: const Duration(seconds: 179), duration: dur, playing: true), isFalse);
    });
    test('skips very short songs and unknown durations', () {
      expect(CrossfadeService.shouldStart(seconds: 6, position: const Duration(seconds: 12), duration: const Duration(seconds: 15), playing: true), isFalse);
      expect(CrossfadeService.shouldStart(seconds: 6, position: const Duration(seconds: 12), duration: null, playing: true), isFalse);
    });
  });

  group('Tag editor ffmpeg args', () {
    final tags = SongTags(title: 'New Title', artist: 'Me', year: '2024');
    test('keeps all streams and copies audio when cover unchanged', () {
      final a = TagEditorService.buildArgs(input: '/m/a.mp3', output: '/t/o.mp3', tags: tags);
      expect(a, containsAllInOrder(['-i', '/m/a.mp3', '-map', '0', '-c', 'copy', '-map_metadata', '0']));
      expect(a, containsAll(['title=New Title', 'artist=Me', 'date=2024', 'album=']));
      expect(a, containsAllInOrder(['-id3v2_version', '3', '/t/o.mp3']));
      expect(a.last, '/t/o.mp3');
    });
    test('replacing the cover maps audio + new image as attached picture', () {
      final a = TagEditorService.buildArgs(input: '/m/a.flac', output: '/t/o.flac', tags: tags, coverPath: '/t/c.jpg');
      expect(a, containsAllInOrder(['-i', '/m/a.flac', '-i', '/t/c.jpg', '-map', '0:a', '-map', '1:0']));
      expect(a, containsAllInOrder(['-disposition:v:0', 'attached_pic']));
      expect(a.contains('-id3v2_version'), isFalse);
    });
    test('removing the cover keeps audio only', () {
      final a = TagEditorService.buildArgs(input: '/m/a.m4a', output: '/t/o.m4a', tags: tags, removeCover: true);
      expect(a, containsAllInOrder(['-map', '0:a', '-c', 'copy']));
    });
  });
}
