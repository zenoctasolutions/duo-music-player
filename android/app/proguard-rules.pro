# Duo Music Player — R8 / ProGuard rules for release builds.
#
# Most Flutter plugin AARs (just_audio, audio_service, google_mobile_ads,
# photo_manager, dio, etc.) ship their own consumer-rules.pro that R8 merges in
# automatically, so this file only adds the rules that experience shows are not
# always covered: classes started by the OS via reflection (manifest components),
# and Parcelable/enum patterns R8's default optimizations can otherwise break.

# audio_service starts its MediaBrowserService / MediaButtonReceiver by class name
# from AndroidManifest.xml, and just_audio bridges playback events to ExoPlayer/
# Media3 via reflection-friendly listener classes. Keep both intact.
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# AndroidX Media / Media3 back the media session, notification and playback state
# used by the two plugins above.
-keep class androidx.media3.** { *; }
-keep class androidx.media.** { *; }

# Parcelable CREATOR fields (MediaMetadataCompat, PlaybackStateCompat, etc.) are
# read reflectively by the platform and must keep their original name.
-keepclassmembers class * implements android.os.Parcelable {
    public static final ** CREATOR;
}

# Enum values()/valueOf() are used reflectively by several plugins (and by
# just_audio_background's isolate messaging).
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}


# ffmpeg_kit_flutter_new_audio (4D/8D audio conversion) bridges to native ffmpeg
# via JNI/reflection-friendly session classes.
-keep class com.antonkarpenko.ffmpegkit.** { *; }

# App entry point referenced from AndroidManifest.xml.
-keep class com.zenocta.duomusicplayer.MainActivity { *; }

# Chromecast options provider is instantiated by class name from the manifest.
-keep class com.zenocta.duomusicplayer.CastOptionsProvider { *; }
