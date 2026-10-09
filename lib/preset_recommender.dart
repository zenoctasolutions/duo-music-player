// lib/preset_recommender.dart
//
// Maps a song's DSP analysis (tempo, energy, brightness — from
// AudioAnalysisService) to a suggested 4D/8D preset. A rules layer over
// existing feature extraction, not a new model or cloud call, surfaced as a
// one-tap suggestion in the Audio Conversion sheet.
import 'audio_analysis_service.dart';
import 'audio_conversion_service.dart';

enum RecommendedPreset { fourD, eightD, none }

class PresetRecommendation {
  final RecommendedPreset preset;
  final String reason;
  const PresetRecommendation(this.preset, this.reason);
}

class PresetRecommender {
  static PresetRecommendation recommend(AudioAnalysis a) {
    if (a.bpm <= 0) {
      return const PresetRecommendation(RecommendedPreset.none, '');
    }

    final highEnergy = a.energy > 0.5;
    final steadyTempo = a.bpm >= 90;
    final bright = a.brightness > 0.4;

    if (highEnergy && bright && steadyTempo) {
      return const PresetRecommendation(
        RecommendedPreset.eightD,
        "Strong energy and a steady tempo — a good candidate for 8D's wider circular movement.",
      );
    }
    if (a.energy < 0.4 && a.bpm < 100) {
      return const PresetRecommendation(
        RecommendedPreset.fourD,
        "Calmer and slower — 4D's gentler stereo widening tends to suit this better.",
      );
    }
    if (highEnergy || bright) {
      return const PresetRecommendation(
        RecommendedPreset.eightD,
        'Good stereo separation potential — 8D usually stands out here.',
      );
    }
    return const PresetRecommendation(
      RecommendedPreset.fourD,
      'A subtler effect like 4D should complement this track without overpowering it.',
    );
  }

  static ConversionType toConversionType(RecommendedPreset preset) =>
      preset == RecommendedPreset.eightD ? ConversionType.eightD : ConversionType.fourD;
}
