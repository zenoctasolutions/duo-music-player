// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get navLibrary => 'Library';

  @override
  String get navRadio => 'Radio';

  @override
  String get navDuo => 'Duo';

  @override
  String get navConverter => 'Converter';

  @override
  String get navSettings => 'Settings';

  @override
  String navTabSemantics(int index, int total) {
    return 'Tab $index of $total';
  }

  @override
  String get navSelected => 'Selected';

  @override
  String get tabOverview => 'Overview';

  @override
  String get tabSongs => 'Songs';

  @override
  String get tipShuffleOn => 'Shuffle: On';

  @override
  String get tipShuffleOff => 'Shuffle: Off';

  @override
  String get tipSortSongs => 'Sort songs';

  @override
  String get tipRefreshSongs => 'Refresh songs';

  @override
  String get tipSearchEverywhere => 'Search everywhere';

  @override
  String get tipSearch => 'Search';

  @override
  String get tipCloseSearch => 'Close search';

  @override
  String get searchSongsHint => 'Search songs...';

  @override
  String get shuffleAll => 'Shuffle all';

  @override
  String get favorites => 'Favorites';

  @override
  String get playlists => 'Playlists';

  @override
  String get newPlaylist => 'New playlist';

  @override
  String get folders => 'Folders';

  @override
  String get recentlyAdded => 'Recently added';

  @override
  String get recentlyPlayed => 'Recently played';

  @override
  String get mostPlayed => 'Most played';

  @override
  String get browse => 'Browse';

  @override
  String get seeAll => 'See all';

  @override
  String seeAllSection(String section) {
    return 'See all $section';
  }

  @override
  String get playSomething => 'Play something';

  @override
  String get playSomethingSubtitle =>
      'Start with a shuffle of your whole library';

  @override
  String get heroNowPlaying => 'NOW PLAYING';

  @override
  String get heroContinueListening => 'CONTINUE LISTENING';

  @override
  String get heroPickUp => 'PICK UP WHERE YOU LEFT OFF';

  @override
  String get heroSemanticsContinue => 'Continue listening';

  @override
  String get heroSemanticsLast => 'Last played';

  @override
  String heroSemanticsBy(String title, String artist) {
    return '$title by $artist';
  }

  @override
  String get play => 'Play';

  @override
  String get pause => 'Pause';

  @override
  String songCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return '$_temp0';
  }

  @override
  String playCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count plays',
      one: '1 play',
    );
    return '$_temp0';
  }

  @override
  String get browseArtists => 'Artists';

  @override
  String get browseArtistsSub => 'Browse by artist';

  @override
  String get browseAlbums => 'Albums';

  @override
  String get browseAlbumsSub => 'Browse by album';

  @override
  String get browseGenres => 'Genres';

  @override
  String get browseGenresSub => 'Browse by genre';

  @override
  String get browseSmartMix => 'Smart Mix';

  @override
  String get browseSmartMixSub => 'Mood and tempo';

  @override
  String get noMusicFound => 'No music found';

  @override
  String get noMusicFoundSub => 'Songs on your device will appear here.';

  @override
  String get share => 'Share';

  @override
  String get queue => 'Queue';

  @override
  String get abLoop => 'A-B';

  @override
  String get abSet => 'A set';

  @override
  String get visualizer => 'Visualizer';

  @override
  String get more => 'More';

  @override
  String get lyrics => 'Lyrics';

  @override
  String get cover => 'Cover';

  @override
  String get playbackSpeed => 'Playback Speed';

  @override
  String get willPlayNext => 'Will play next';

  @override
  String songsWillPlayNext(int count) {
    return '$count songs will play next';
  }

  @override
  String get addedToQueue => 'Added to queue';

  @override
  String addedSongsToQueue(int count) {
    return 'Added $count songs to queue';
  }

  @override
  String get alreadyInQueue => 'Already in queue';

  @override
  String get alreadyPlaying => 'Already playing';

  @override
  String get queueCleared => 'Queue cleared';

  @override
  String get queueAlreadyEmpty => 'Queue already empty';

  @override
  String get undo => 'Undo';

  @override
  String abLooping(String a, String b) {
    return 'Looping $a - $b';
  }

  @override
  String get abLoopCleared => 'A-B loop cleared';

  @override
  String abSetAt(String time) {
    return 'A set at $time';
  }

  @override
  String get abTooShort => 'B must be at least 1s after A';

  @override
  String get searchHint => 'Search songs, albums, artists, playlists';

  @override
  String get searchClearText => 'Clear search text';

  @override
  String searchNothingFound(String query) {
    return 'Nothing found for \"$query\"';
  }

  @override
  String get searchNothingFoundHint =>
      'Check the spelling or try a shorter word, an artist or an album name.';

  @override
  String get searchLibraryTitle => 'Search your whole library';

  @override
  String get searchLibraryHint =>
      'Songs, albums, artists and playlists, with or without accents.';

  @override
  String get searchRecent => 'RECENT SEARCHES';

  @override
  String get searchClearAll => 'Clear all';

  @override
  String searchRemoveRecent(String query) {
    return 'Remove \"$query\" from recent searches';
  }

  @override
  String get searchSongs => 'SONGS';

  @override
  String get searchAlbums => 'ALBUMS';

  @override
  String get searchArtists => 'ARTISTS';

  @override
  String get searchPlaylists => 'PLAYLISTS';

  @override
  String searchSongSemantics(String title, String by) {
    return 'Song $title$by. Double tap to play.';
  }

  @override
  String searchBy(String artist) {
    return ' by $artist';
  }

  @override
  String searchAlbumSemantics(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return 'Album $name, $_temp0. Double tap to open.';
  }

  @override
  String searchArtistSemantics(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return 'Artist $name, $_temp0. Double tap to open.';
  }

  @override
  String searchPlaylistSemantics(String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count songs',
      one: '1 song',
    );
    return 'Playlist $name, $_temp0. Double tap to open.';
  }

  @override
  String get settingsEqualizer => 'Equalizer';

  @override
  String get settingsEqualizerSub => 'Adjust audio bands and apply presets';

  @override
  String get settingsSoundEffects => 'Sound effects';

  @override
  String get settingsSoundEffectsSub =>
      'Bass boost, virtualizer, loudness, volume normalization';

  @override
  String get settingsLastfm => 'Last.fm';

  @override
  String get settingsLastfmSub => 'Scrobble your listening history';

  @override
  String get settingsMono => 'Mono audio (Duo Mode)';

  @override
  String get settingsRadio => 'Internet Radio';

  @override
  String get settingsRadioSub =>
      'Listen to live stations from around the world';

  @override
  String get settingsCheckVersion => 'Check Latest Version';

  @override
  String get settingsCheckVersionSub => 'Open Play Store to update the app';

  @override
  String get settingsOurApps => 'Our Apps';

  @override
  String get settingsOurAppsSub => 'Discover more apps from Zenocta Solutions';

  @override
  String get settingsAppearance => 'Appearance';

  @override
  String get settingsAppearanceSub =>
      'Accent color, pure black theme, start screen';

  @override
  String get settingsLibraryFilters => 'Library filters';

  @override
  String get settingsLibraryFiltersSub =>
      'Hide short clips and exclude folders';

  @override
  String get settingsSleepTimer => 'Sleep Timer';

  @override
  String get settingsSleepTimerSub =>
      'Stop after a set time or at the end of the song';

  @override
  String get settingsAudiobooks => 'Audiobooks & long files';

  @override
  String get settingsAudiobooksSub =>
      'Remember where you stopped and resume there';

  @override
  String get settingsAudioCutter => 'Audio Cutter';

  @override
  String get settingsAudioCutterSub => 'Trim local audio files';

  @override
  String get settingsUrlDownloader => 'URL Downloader';

  @override
  String get settingsUrlDownloaderSub => 'Download MP3 audio files via links';

  @override
  String get settingsBackup => 'Backup & Restore';

  @override
  String get settingsBackupSub =>
      'Save or restore playlists, lyrics and favorites';

  @override
  String get settingsVersionUnavailable => 'Version info not available';

  @override
  String get settingsCancel => 'Cancel';

  @override
  String settingsVersion(String version) {
    return 'Version $version';
  }

  @override
  String get settingsMonoOnSub =>
      'On — both ears get the same mix, so Duo Mode can\'t split songs. Tap to turn it off in Accessibility.';

  @override
  String get settingsMonoOffSub =>
      'Must stay off so each ear gets its own song. Opens Accessibility settings.';

  @override
  String get previous => 'Previous';

  @override
  String get next => 'Next';

  @override
  String get openPlayer => 'Open player';

  @override
  String get swipeNextSong => 'Next song';

  @override
  String get swipePreviousSong => 'Previous song';

  @override
  String get back => 'Back';

  @override
  String get close => 'Close';

  @override
  String get songInfo => 'Song info';

  @override
  String get nowPlayingTitle => 'Now Playing';

  @override
  String get cast => 'Cast';

  @override
  String get lyricsEditLocal => 'Add / Edit Local Lyrics';

  @override
  String get lyricsOnline => 'Online Lyrics';

  @override
  String get removeFromQueue => 'Remove from queue';

  @override
  String get repeatOff => 'Repeat Off';

  @override
  String get repeatOne => 'Repeat One';

  @override
  String get abLoopLabel => 'A-B loop';

  @override
  String get pageDotsLabel => 'Art and lyrics pages';

  @override
  String get favoriteAdd => 'Add to favorites';

  @override
  String get favoriteRemove => 'Remove from favorites';

  @override
  String get nowPlayingState => 'now playing';

  @override
  String get notPlayingState => 'not playing';

  @override
  String get seekSlider => 'Seek';

  @override
  String get mini => 'Mini player';

  @override
  String castingTo(String device) {
    return 'Casting to $device';
  }

  @override
  String seekBackBy(int seconds) {
    return 'Back $seconds seconds';
  }

  @override
  String seekForwardBy(int seconds) {
    return 'Forward $seconds seconds';
  }

  @override
  String speedSemantics(String speed) {
    return 'Playback speed ${speed}x';
  }

  @override
  String seekValue(String position, String total) {
    return '$position of $total';
  }

  @override
  String moreOptionsFor(String title) {
    return 'More options for $title';
  }

  @override
  String songRowSemantics(String title, String artist, String state) {
    return '$title, $artist, $state';
  }

  @override
  String get queueOptions => 'Queue options';

  @override
  String get playNext => 'Play next';

  @override
  String get addToQueue => 'Add to queue';
}
