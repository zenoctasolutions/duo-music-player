import 'package:flutter/widgets.dart';

/// Duo Music Player has no ads. The banner slots that used to sit at the
/// bottom of screens are kept as zero-size placeholders so layouts and call
/// sites are unchanged.
class BannerAdWidget extends StatelessWidget {
  final bool useSafeArea;
  const BannerAdWidget({super.key, this.useSafeArea = true});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
