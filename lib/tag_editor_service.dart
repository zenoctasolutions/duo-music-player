// lib/tag_editor_service.dart
//
// Tag editor backend: reads tags with audio_metadata_reader and writes
// them with ffmpeg (stream copy — the audio itself is never re-encoded and
// all other tags/streams are preserved). The re-tagged copy is written to
// the app cache first, verified, and only then copied over the original
// through Android's MediaStore write-consent flow (TagWriteHelper.kt).

import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SongTags {
  String title;
  String artist;
  String album;
  String albumArtist;
  String genre;
  String year;
  String track;

  SongTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.genre = '',
    this.year = '',
    this.track = '',
  });

  /// ffmpeg -metadata keys (an empty value clears the tag).
  Map<String, String> toFfmpeg() => {
        'title': title.trim(),
        'artist': artist.trim(),
        'album': album.trim(),
        'album_artist': albumArtist.trim(),
        'genre': genre.trim(),
        'date': year.trim(),
        'track': track.trim(),
      };
}

class TagEditorService {
  TagEditorService._();

  static const MethodChannel _channel = MethodChannel('music_app/tags');

  /// Set to a song's path after its tags are saved, so the library can
  /// refresh that song's cached metadata/cover.
  static final ValueNotifier<String?> edited = ValueNotifier<String?>(null);

  static const _editable = {'.mp3', '.m4a', '.mp4', '.aac', '.flac', '.ogg', '.opus', '.wav'};
  static const _coverCapable = {'.mp3', '.m4a', '.mp4', '.flac'};

  static bool canEdit(String path) => _editable.contains(p.extension(path).toLowerCase());
  static bool canEditCover(String path) => _coverCapable.contains(p.extension(path).toLowerCase());

  static Future<(SongTags, Uint8List?)> read(String path) async {
    return compute(_readSync, path);
  }

  static (SongTags, Uint8List?) _readSync(String path) {
    try {
      final m = readMetadata(File(path), getImage: true);
      final tags = SongTags(
        title: m.title ?? '',
        artist: m.artist ?? '',
        album: m.album ?? '',
        genre: m.genres.isNotEmpty ? m.genres.first : '',
        year: (m.year != null && m.year!.year > 0) ? m.year!.year.toString() : '',
        track: m.trackNumber != null ? m.trackNumber.toString() : '',
      );
      final cover = m.pictures.isNotEmpty ? m.pictures.first.bytes : null;
      return (tags, cover);
    } catch (_) {
      return (SongTags(title: p.basenameWithoutExtension(path)), null);
    }
  }

  /// Pure helper (unit-tested): ffmpeg arguments for writing [tags].
  @visibleForTesting
  static List<String> buildArgs({
    required String input,
    required String output,
    required SongTags tags,
    String? coverPath,
    bool removeCover = false,
  }) {
    final ext = p.extension(input).toLowerCase();
    final args = <String>['-y', '-hide_banner', '-i', input];
    if (coverPath != null) args.addAll(['-i', coverPath]);

    if (coverPath != null) {
      args.addAll(['-map', '0:a', '-map', '1:0']);
    } else if (removeCover) {
      args.addAll(['-map', '0:a']);
    } else {
      args.addAll(['-map', '0']);
    }
    args.addAll(['-c', 'copy', '-map_metadata', '0']);
    tags.toFfmpeg().forEach((k, v) => args.addAll(['-metadata', '$k=$v']));
    if (coverPath != null) {
      args.addAll(['-disposition:v:0', 'attached_pic', '-metadata:s:v', 'title=Album cover', '-metadata:s:v', 'comment=Cover (front)']);
    }
    if (ext == '.mp3') args.addAll(['-id3v2_version', '3']);
    args.add(output);
    return args;
  }

  /// Writes [tags] into [path]. Returns null on success or a user-facing
  /// error message.
  static Future<String?> save(String path, SongTags tags, {String? coverPath, bool removeCover = false}) async {
    if (!canEdit(path)) return 'This file type can\'t be edited.';
    final tmpDir = await getTemporaryDirectory();
    final out = p.join(tmpDir.path, 'tagedit_${DateTime.now().millisecondsSinceEpoch}${p.extension(path)}');

    final session = await FFmpegKit.executeWithArguments(buildArgs(
      input: path,
      output: out,
      tags: tags,
      coverPath: canEditCover(path) ? coverPath : null,
      removeCover: canEditCover(path) && removeCover,
    ));
    final rc = await session.getReturnCode();
    final outFile = File(out);
    if (!ReturnCode.isSuccess(rc) || !await outFile.exists() || await outFile.length() == 0) {
      debugPrint('Tag write failed: ${await session.getAllLogsAsString()}');
      if (await outFile.exists()) await outFile.delete();
      return 'Couldn\'t write the tags to this file.';
    }

    // Safety check: the new file must have the same length of audio.
    final origDur = await _durationSec(path);
    final newDur = await _durationSec(out);
    if (origDur != null && newDur != null && (origDur - newDur).abs() > 1.0) {
      await outFile.delete();
      return 'Safety check failed — the file was not changed.';
    }

    try {
      final granted = await _channel.invokeMethod<bool>('requestWriteAccess', {'path': path}) ?? false;
      if (!granted) {
        await outFile.delete();
        return 'Permission to modify the file was not given.';
      }
      final ok = await _channel.invokeMethod<bool>('replaceFileContents', {'path': path, 'tempPath': out}) ?? false;
      if (!ok) return 'Couldn\'t save the file.';
      edited.value = null;
      edited.value = path;
    } on PlatformException catch (e) {
      if (await outFile.exists()) await outFile.delete();
      return e.code == 'NOT_INDEXED'
          ? 'This file isn\'t in the media library yet — try again after a rescan.'
          : 'Couldn\'t save the file (${e.message}).';
    }
    return null;
  }

  static Future<double?> _durationSec(String path) async {
    try {
      final info = (await FFprobeKit.getMediaInformation(path)).getMediaInformation();
      return double.tryParse(info?.getDuration() ?? '');
    } catch (_) {
      return null;
    }
  }

  /// System photo picker (no permission needed). Returns a cached copy path.
  static Future<String?> pickCoverImage() async {
    try {
      return await _channel.invokeMethod<String>('pickImage');
    } catch (_) {
      return null;
    }
  }
}
