// Shared ⋮ button offering "Play next" / "Add to queue" for one or many songs.
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'queue_actions.dart';

class QueueMenuButton extends StatelessWidget {
  /// Songs to act on (one for a row, many for a bulk action).
  final List<String> paths;
  final Color? color;
  final double size;

  /// Accessible name, e.g. 'More options for <title>'. Defaults to 'Queue options'.
  final String? tooltip;
  const QueueMenuButton({super.key, required this.paths, this.color, this.size = 22, this.tooltip});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: tooltip ?? context.l10n.queueOptions,
      padding: EdgeInsets.zero,
      icon: Icon(Icons.more_vert, color: color, size: size),
      onSelected: (v) {
        if (v == 1) {
          QueueActions.playNextWithFeedback(context, paths);
        } else {
          QueueActions.addToQueueWithFeedback(context, paths);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 1, child: Text(context.l10n.playNext)),
        PopupMenuItem(value: 2, child: Text(context.l10n.addToQueue)),
      ],
    );
  }
}
