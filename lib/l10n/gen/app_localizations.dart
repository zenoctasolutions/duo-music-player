import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[Locale('en')];

  /// Bottom navigation label
  ///
  /// In en, this message translates to:
  /// **'Library'**
  String get navLibrary;

  /// No description provided for @navRadio.
  ///
  /// In en, this message translates to:
  /// **'Radio'**
  String get navRadio;

  /// No description provided for @navDuo.
  ///
  /// In en, this message translates to:
  /// **'Duo'**
  String get navDuo;

  /// No description provided for @navConverter.
  ///
  /// In en, this message translates to:
  /// **'Converter'**
  String get navConverter;

  /// Bottom navigation label; also the Settings page title
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get navSettings;

  /// Screen reader hint for bottom navigation tabs
  ///
  /// In en, this message translates to:
  /// **'Tab {index} of {total}'**
  String navTabSemantics(int index, int total);

  /// No description provided for @navSelected.
  ///
  /// In en, this message translates to:
  /// **'Selected'**
  String get navSelected;

  /// No description provided for @tabOverview.
  ///
  /// In en, this message translates to:
  /// **'Overview'**
  String get tabOverview;

  /// No description provided for @tabSongs.
  ///
  /// In en, this message translates to:
  /// **'Songs'**
  String get tabSongs;

  /// No description provided for @tipShuffleOn.
  ///
  /// In en, this message translates to:
  /// **'Shuffle: On'**
  String get tipShuffleOn;

  /// No description provided for @tipShuffleOff.
  ///
  /// In en, this message translates to:
  /// **'Shuffle: Off'**
  String get tipShuffleOff;

  /// No description provided for @tipSortSongs.
  ///
  /// In en, this message translates to:
  /// **'Sort songs'**
  String get tipSortSongs;

  /// No description provided for @tipRefreshSongs.
  ///
  /// In en, this message translates to:
  /// **'Refresh songs'**
  String get tipRefreshSongs;

  /// No description provided for @tipSearchEverywhere.
  ///
  /// In en, this message translates to:
  /// **'Search everywhere'**
  String get tipSearchEverywhere;

  /// No description provided for @tipSearch.
  ///
  /// In en, this message translates to:
  /// **'Search'**
  String get tipSearch;

  /// No description provided for @tipCloseSearch.
  ///
  /// In en, this message translates to:
  /// **'Close search'**
  String get tipCloseSearch;

  /// No description provided for @searchSongsHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs...'**
  String get searchSongsHint;

  /// No description provided for @shuffleAll.
  ///
  /// In en, this message translates to:
  /// **'Shuffle all'**
  String get shuffleAll;

  /// No description provided for @favorites.
  ///
  /// In en, this message translates to:
  /// **'Favorites'**
  String get favorites;

  /// No description provided for @playlists.
  ///
  /// In en, this message translates to:
  /// **'Playlists'**
  String get playlists;

  /// No description provided for @newPlaylist.
  ///
  /// In en, this message translates to:
  /// **'New playlist'**
  String get newPlaylist;

  /// No description provided for @folders.
  ///
  /// In en, this message translates to:
  /// **'Folders'**
  String get folders;

  /// No description provided for @recentlyAdded.
  ///
  /// In en, this message translates to:
  /// **'Recently added'**
  String get recentlyAdded;

  /// No description provided for @recentlyPlayed.
  ///
  /// In en, this message translates to:
  /// **'Recently played'**
  String get recentlyPlayed;

  /// No description provided for @mostPlayed.
  ///
  /// In en, this message translates to:
  /// **'Most played'**
  String get mostPlayed;

  /// No description provided for @browse.
  ///
  /// In en, this message translates to:
  /// **'Browse'**
  String get browse;

  /// No description provided for @seeAll.
  ///
  /// In en, this message translates to:
  /// **'See all'**
  String get seeAll;

  /// Screen reader label for a section's See all button
  ///
  /// In en, this message translates to:
  /// **'See all {section}'**
  String seeAllSection(String section);

  /// No description provided for @playSomething.
  ///
  /// In en, this message translates to:
  /// **'Play something'**
  String get playSomething;

  /// No description provided for @playSomethingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Start with a shuffle of your whole library'**
  String get playSomethingSubtitle;

  /// No description provided for @heroNowPlaying.
  ///
  /// In en, this message translates to:
  /// **'NOW PLAYING'**
  String get heroNowPlaying;

  /// No description provided for @heroContinueListening.
  ///
  /// In en, this message translates to:
  /// **'CONTINUE LISTENING'**
  String get heroContinueListening;

  /// No description provided for @heroPickUp.
  ///
  /// In en, this message translates to:
  /// **'PICK UP WHERE YOU LEFT OFF'**
  String get heroPickUp;

  /// No description provided for @heroSemanticsContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue listening'**
  String get heroSemanticsContinue;

  /// No description provided for @heroSemanticsLast.
  ///
  /// In en, this message translates to:
  /// **'Last played'**
  String get heroSemanticsLast;

  /// No description provided for @heroSemanticsBy.
  ///
  /// In en, this message translates to:
  /// **'{title} by {artist}'**
  String heroSemanticsBy(String title, String artist);

  /// No description provided for @play.
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get play;

  /// No description provided for @pause.
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get pause;

  /// No description provided for @songCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 song} other{{count} songs}}'**
  String songCount(int count);

  /// No description provided for @playCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 play} other{{count} plays}}'**
  String playCount(int count);

  /// No description provided for @browseArtists.
  ///
  /// In en, this message translates to:
  /// **'Artists'**
  String get browseArtists;

  /// No description provided for @browseArtistsSub.
  ///
  /// In en, this message translates to:
  /// **'Browse by artist'**
  String get browseArtistsSub;

  /// No description provided for @browseAlbums.
  ///
  /// In en, this message translates to:
  /// **'Albums'**
  String get browseAlbums;

  /// No description provided for @browseAlbumsSub.
  ///
  /// In en, this message translates to:
  /// **'Browse by album'**
  String get browseAlbumsSub;

  /// No description provided for @browseGenres.
  ///
  /// In en, this message translates to:
  /// **'Genres'**
  String get browseGenres;

  /// No description provided for @browseGenresSub.
  ///
  /// In en, this message translates to:
  /// **'Browse by genre'**
  String get browseGenresSub;

  /// No description provided for @browseSmartMix.
  ///
  /// In en, this message translates to:
  /// **'Smart Mix'**
  String get browseSmartMix;

  /// No description provided for @browseSmartMixSub.
  ///
  /// In en, this message translates to:
  /// **'Mood and tempo'**
  String get browseSmartMixSub;

  /// No description provided for @noMusicFound.
  ///
  /// In en, this message translates to:
  /// **'No music found'**
  String get noMusicFound;

  /// No description provided for @noMusicFoundSub.
  ///
  /// In en, this message translates to:
  /// **'Songs on your device will appear here.'**
  String get noMusicFoundSub;

  /// No description provided for @share.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get share;

  /// No description provided for @queue.
  ///
  /// In en, this message translates to:
  /// **'Queue'**
  String get queue;

  /// No description provided for @abLoop.
  ///
  /// In en, this message translates to:
  /// **'A-B'**
  String get abLoop;

  /// No description provided for @abSet.
  ///
  /// In en, this message translates to:
  /// **'A set'**
  String get abSet;

  /// No description provided for @visualizer.
  ///
  /// In en, this message translates to:
  /// **'Visualizer'**
  String get visualizer;

  /// No description provided for @more.
  ///
  /// In en, this message translates to:
  /// **'More'**
  String get more;

  /// No description provided for @lyrics.
  ///
  /// In en, this message translates to:
  /// **'Lyrics'**
  String get lyrics;

  /// No description provided for @cover.
  ///
  /// In en, this message translates to:
  /// **'Cover'**
  String get cover;

  /// No description provided for @playbackSpeed.
  ///
  /// In en, this message translates to:
  /// **'Playback Speed'**
  String get playbackSpeed;

  /// No description provided for @willPlayNext.
  ///
  /// In en, this message translates to:
  /// **'Will play next'**
  String get willPlayNext;

  /// No description provided for @songsWillPlayNext.
  ///
  /// In en, this message translates to:
  /// **'{count} songs will play next'**
  String songsWillPlayNext(int count);

  /// No description provided for @addedToQueue.
  ///
  /// In en, this message translates to:
  /// **'Added to queue'**
  String get addedToQueue;

  /// No description provided for @addedSongsToQueue.
  ///
  /// In en, this message translates to:
  /// **'Added {count} songs to queue'**
  String addedSongsToQueue(int count);

  /// No description provided for @alreadyInQueue.
  ///
  /// In en, this message translates to:
  /// **'Already in queue'**
  String get alreadyInQueue;

  /// No description provided for @alreadyPlaying.
  ///
  /// In en, this message translates to:
  /// **'Already playing'**
  String get alreadyPlaying;

  /// No description provided for @queueCleared.
  ///
  /// In en, this message translates to:
  /// **'Queue cleared'**
  String get queueCleared;

  /// No description provided for @queueAlreadyEmpty.
  ///
  /// In en, this message translates to:
  /// **'Queue already empty'**
  String get queueAlreadyEmpty;

  /// No description provided for @undo.
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get undo;

  /// A-B loop activated; a and b are m:ss times
  ///
  /// In en, this message translates to:
  /// **'Looping {a} - {b}'**
  String abLooping(String a, String b);

  /// No description provided for @abLoopCleared.
  ///
  /// In en, this message translates to:
  /// **'A-B loop cleared'**
  String get abLoopCleared;

  /// No description provided for @abSetAt.
  ///
  /// In en, this message translates to:
  /// **'A set at {time}'**
  String abSetAt(String time);

  /// No description provided for @abTooShort.
  ///
  /// In en, this message translates to:
  /// **'B must be at least 1s after A'**
  String get abTooShort;

  /// No description provided for @searchHint.
  ///
  /// In en, this message translates to:
  /// **'Search songs, albums, artists, playlists'**
  String get searchHint;

  /// No description provided for @searchClearText.
  ///
  /// In en, this message translates to:
  /// **'Clear search text'**
  String get searchClearText;

  /// No description provided for @searchNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found for \"{query}\"'**
  String searchNothingFound(String query);

  /// No description provided for @searchNothingFoundHint.
  ///
  /// In en, this message translates to:
  /// **'Check the spelling or try a shorter word, an artist or an album name.'**
  String get searchNothingFoundHint;

  /// No description provided for @searchLibraryTitle.
  ///
  /// In en, this message translates to:
  /// **'Search your whole library'**
  String get searchLibraryTitle;

  /// No description provided for @searchLibraryHint.
  ///
  /// In en, this message translates to:
  /// **'Songs, albums, artists and playlists, with or without accents.'**
  String get searchLibraryHint;

  /// No description provided for @searchRecent.
  ///
  /// In en, this message translates to:
  /// **'RECENT SEARCHES'**
  String get searchRecent;

  /// No description provided for @searchClearAll.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get searchClearAll;

  /// No description provided for @searchRemoveRecent.
  ///
  /// In en, this message translates to:
  /// **'Remove \"{query}\" from recent searches'**
  String searchRemoveRecent(String query);

  /// No description provided for @searchSongs.
  ///
  /// In en, this message translates to:
  /// **'SONGS'**
  String get searchSongs;

  /// No description provided for @searchAlbums.
  ///
  /// In en, this message translates to:
  /// **'ALBUMS'**
  String get searchAlbums;

  /// No description provided for @searchArtists.
  ///
  /// In en, this message translates to:
  /// **'ARTISTS'**
  String get searchArtists;

  /// No description provided for @searchPlaylists.
  ///
  /// In en, this message translates to:
  /// **'PLAYLISTS'**
  String get searchPlaylists;

  /// No description provided for @searchSongSemantics.
  ///
  /// In en, this message translates to:
  /// **'Song {title}{by}. Double tap to play.'**
  String searchSongSemantics(String title, String by);

  /// No description provided for @searchBy.
  ///
  /// In en, this message translates to:
  /// **' by {artist}'**
  String searchBy(String artist);

  /// No description provided for @searchAlbumSemantics.
  ///
  /// In en, this message translates to:
  /// **'Album {name}, {count, plural, =1{1 song} other{{count} songs}}. Double tap to open.'**
  String searchAlbumSemantics(String name, int count);

  /// No description provided for @searchArtistSemantics.
  ///
  /// In en, this message translates to:
  /// **'Artist {name}, {count, plural, =1{1 song} other{{count} songs}}. Double tap to open.'**
  String searchArtistSemantics(String name, int count);

  /// No description provided for @searchPlaylistSemantics.
  ///
  /// In en, this message translates to:
  /// **'Playlist {name}, {count, plural, =1{1 song} other{{count} songs}}. Double tap to open.'**
  String searchPlaylistSemantics(String name, int count);

  /// No description provided for @settingsEqualizer.
  ///
  /// In en, this message translates to:
  /// **'Equalizer'**
  String get settingsEqualizer;

  /// No description provided for @settingsEqualizerSub.
  ///
  /// In en, this message translates to:
  /// **'Adjust audio bands and apply presets'**
  String get settingsEqualizerSub;

  /// No description provided for @settingsSoundEffects.
  ///
  /// In en, this message translates to:
  /// **'Sound effects'**
  String get settingsSoundEffects;

  /// No description provided for @settingsSoundEffectsSub.
  ///
  /// In en, this message translates to:
  /// **'Bass boost, virtualizer, loudness, volume normalization'**
  String get settingsSoundEffectsSub;

  /// No description provided for @settingsLastfm.
  ///
  /// In en, this message translates to:
  /// **'Last.fm'**
  String get settingsLastfm;

  /// No description provided for @settingsLastfmSub.
  ///
  /// In en, this message translates to:
  /// **'Scrobble your listening history'**
  String get settingsLastfmSub;

  /// No description provided for @settingsMono.
  ///
  /// In en, this message translates to:
  /// **'Mono audio (Duo Mode)'**
  String get settingsMono;

  /// No description provided for @settingsRadio.
  ///
  /// In en, this message translates to:
  /// **'Internet Radio'**
  String get settingsRadio;

  /// No description provided for @settingsRadioSub.
  ///
  /// In en, this message translates to:
  /// **'Listen to live stations from around the world'**
  String get settingsRadioSub;

  /// No description provided for @settingsCheckVersion.
  ///
  /// In en, this message translates to:
  /// **'Check Latest Version'**
  String get settingsCheckVersion;

  /// No description provided for @settingsCheckVersionSub.
  ///
  /// In en, this message translates to:
  /// **'Open Play Store to update the app'**
  String get settingsCheckVersionSub;

  /// No description provided for @settingsOurApps.
  ///
  /// In en, this message translates to:
  /// **'Our Apps'**
  String get settingsOurApps;

  /// No description provided for @settingsOurAppsSub.
  ///
  /// In en, this message translates to:
  /// **'Discover more apps from Zenocta Solutions'**
  String get settingsOurAppsSub;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsAppearanceSub.
  ///
  /// In en, this message translates to:
  /// **'Accent color, pure black theme, start screen'**
  String get settingsAppearanceSub;

  /// No description provided for @settingsLibraryFilters.
  ///
  /// In en, this message translates to:
  /// **'Library filters'**
  String get settingsLibraryFilters;

  /// No description provided for @settingsLibraryFiltersSub.
  ///
  /// In en, this message translates to:
  /// **'Hide short clips and exclude folders'**
  String get settingsLibraryFiltersSub;

  /// No description provided for @settingsSleepTimer.
  ///
  /// In en, this message translates to:
  /// **'Sleep Timer'**
  String get settingsSleepTimer;

  /// No description provided for @settingsSleepTimerSub.
  ///
  /// In en, this message translates to:
  /// **'Stop after a set time or at the end of the song'**
  String get settingsSleepTimerSub;

  /// No description provided for @settingsAudiobooks.
  ///
  /// In en, this message translates to:
  /// **'Audiobooks & long files'**
  String get settingsAudiobooks;

  /// No description provided for @settingsAudiobooksSub.
  ///
  /// In en, this message translates to:
  /// **'Remember where you stopped and resume there'**
  String get settingsAudiobooksSub;

  /// No description provided for @settingsAudioCutter.
  ///
  /// In en, this message translates to:
  /// **'Audio Cutter'**
  String get settingsAudioCutter;

  /// No description provided for @settingsAudioCutterSub.
  ///
  /// In en, this message translates to:
  /// **'Trim local audio files'**
  String get settingsAudioCutterSub;

  /// No description provided for @settingsUrlDownloader.
  ///
  /// In en, this message translates to:
  /// **'URL Downloader'**
  String get settingsUrlDownloader;

  /// No description provided for @settingsUrlDownloaderSub.
  ///
  /// In en, this message translates to:
  /// **'Download MP3 audio files via links'**
  String get settingsUrlDownloaderSub;

  /// No description provided for @settingsBackup.
  ///
  /// In en, this message translates to:
  /// **'Backup & Restore'**
  String get settingsBackup;

  /// No description provided for @settingsBackupSub.
  ///
  /// In en, this message translates to:
  /// **'Save or restore playlists, lyrics and favorites'**
  String get settingsBackupSub;

  /// No description provided for @settingsVersionUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Version info not available'**
  String get settingsVersionUnavailable;

  /// No description provided for @settingsCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get settingsCancel;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String settingsVersion(String version);

  /// No description provided for @settingsMonoOnSub.
  ///
  /// In en, this message translates to:
  /// **'On — both ears get the same mix, so Duo Mode can\'t split songs. Tap to turn it off in Accessibility.'**
  String get settingsMonoOnSub;

  /// No description provided for @settingsMonoOffSub.
  ///
  /// In en, this message translates to:
  /// **'Must stay off so each ear gets its own song. Opens Accessibility settings.'**
  String get settingsMonoOffSub;

  /// No description provided for @previous.
  ///
  /// In en, this message translates to:
  /// **'Previous'**
  String get previous;

  /// No description provided for @next.
  ///
  /// In en, this message translates to:
  /// **'Next'**
  String get next;

  /// No description provided for @openPlayer.
  ///
  /// In en, this message translates to:
  /// **'Open player'**
  String get openPlayer;

  /// No description provided for @swipeNextSong.
  ///
  /// In en, this message translates to:
  /// **'Next song'**
  String get swipeNextSong;

  /// No description provided for @swipePreviousSong.
  ///
  /// In en, this message translates to:
  /// **'Previous song'**
  String get swipePreviousSong;

  /// No description provided for @back.
  ///
  /// In en, this message translates to:
  /// **'Back'**
  String get back;

  /// No description provided for @close.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get close;

  /// No description provided for @songInfo.
  ///
  /// In en, this message translates to:
  /// **'Song info'**
  String get songInfo;

  /// No description provided for @nowPlayingTitle.
  ///
  /// In en, this message translates to:
  /// **'Now Playing'**
  String get nowPlayingTitle;

  /// No description provided for @cast.
  ///
  /// In en, this message translates to:
  /// **'Cast'**
  String get cast;

  /// No description provided for @lyricsEditLocal.
  ///
  /// In en, this message translates to:
  /// **'Add / Edit Local Lyrics'**
  String get lyricsEditLocal;

  /// No description provided for @lyricsOnline.
  ///
  /// In en, this message translates to:
  /// **'Online Lyrics'**
  String get lyricsOnline;

  /// No description provided for @removeFromQueue.
  ///
  /// In en, this message translates to:
  /// **'Remove from queue'**
  String get removeFromQueue;

  /// No description provided for @repeatOff.
  ///
  /// In en, this message translates to:
  /// **'Repeat Off'**
  String get repeatOff;

  /// No description provided for @repeatOne.
  ///
  /// In en, this message translates to:
  /// **'Repeat One'**
  String get repeatOne;

  /// No description provided for @abLoopLabel.
  ///
  /// In en, this message translates to:
  /// **'A-B loop'**
  String get abLoopLabel;

  /// No description provided for @pageDotsLabel.
  ///
  /// In en, this message translates to:
  /// **'Art and lyrics pages'**
  String get pageDotsLabel;

  /// No description provided for @favoriteAdd.
  ///
  /// In en, this message translates to:
  /// **'Add to favorites'**
  String get favoriteAdd;

  /// No description provided for @favoriteRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove from favorites'**
  String get favoriteRemove;

  /// No description provided for @nowPlayingState.
  ///
  /// In en, this message translates to:
  /// **'now playing'**
  String get nowPlayingState;

  /// No description provided for @notPlayingState.
  ///
  /// In en, this message translates to:
  /// **'not playing'**
  String get notPlayingState;

  /// No description provided for @seekSlider.
  ///
  /// In en, this message translates to:
  /// **'Seek'**
  String get seekSlider;

  /// No description provided for @mini.
  ///
  /// In en, this message translates to:
  /// **'Mini player'**
  String get mini;

  /// No description provided for @castingTo.
  ///
  /// In en, this message translates to:
  /// **'Casting to {device}'**
  String castingTo(String device);

  /// No description provided for @seekBackBy.
  ///
  /// In en, this message translates to:
  /// **'Back {seconds} seconds'**
  String seekBackBy(int seconds);

  /// No description provided for @seekForwardBy.
  ///
  /// In en, this message translates to:
  /// **'Forward {seconds} seconds'**
  String seekForwardBy(int seconds);

  /// No description provided for @speedSemantics.
  ///
  /// In en, this message translates to:
  /// **'Playback speed {speed}x'**
  String speedSemantics(String speed);

  /// No description provided for @seekValue.
  ///
  /// In en, this message translates to:
  /// **'{position} of {total}'**
  String seekValue(String position, String total);

  /// No description provided for @moreOptionsFor.
  ///
  /// In en, this message translates to:
  /// **'More options for {title}'**
  String moreOptionsFor(String title);

  /// No description provided for @songRowSemantics.
  ///
  /// In en, this message translates to:
  /// **'{title}, {artist}, {state}'**
  String songRowSemantics(String title, String artist, String state);

  /// No description provided for @queueOptions.
  ///
  /// In en, this message translates to:
  /// **'Queue options'**
  String get queueOptions;

  /// No description provided for @playNext.
  ///
  /// In en, this message translates to:
  /// **'Play next'**
  String get playNext;

  /// No description provided for @addToQueue.
  ///
  /// In en, this message translates to:
  /// **'Add to queue'**
  String get addToQueue;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
