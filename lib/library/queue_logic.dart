import 'package:flutter/foundation.dart';

// Pure, dependency-free queue-edit rules (unit-tested). See queue_actions.dart.
/// Result of a pure queue edit.
class QueueEdit {
  final List<String> queue;
  final int added; // newly inserted
  final int moved; // existing entries relocated (play next only)
  final int skipped; // already queued / currently playing
  const QueueEdit(this.queue, {this.added = 0, this.moved = 0, this.skipped = 0});
  bool get changed => added > 0 || moved > 0;
}

class QueueLogic {
  QueueLogic._();

  /// Tracks inserted by playNext that haven't started yet (pruned as they play).
  static final Set<String> pending = <String>{};

  /// Shuffle hook: the oldest pending play-next track still in [playlist].
  static String? pendingNextFor(List<String> playlist, String? current) {
    for (final p in playlist) {
      if (p != current && pending.contains(p)) return p;
    }
    return null;
  }

  // ---------------------------------------------------------------- pure

  /// Index just after [current] and after the already-pending play-next block.
  @visibleForTesting
  static int nextSlot(List<String> queue, String? current, Set<String> pending) {
    final cur = current == null ? -1 : queue.indexOf(current);
    var i = cur + 1;
    while (i < queue.length && pending.contains(queue[i])) {
      i++;
    }
    return i;
  }

  static QueueEdit applyPlayNext(List<String> queue, String? current, Set<String> pending, List<String> paths) {
    final q = List<String>.of(queue);
    var added = 0, moved = 0, skipped = 0;
    final seen = <String>{};
    for (final path in paths) {
      if (!seen.add(path)) continue; // duplicate within the request
      if (path == current) {
        skipped++;
        continue;
      }
      final existing = q.indexOf(path);
      if (existing != -1) {
        q.removeAt(existing);
        moved++;
      } else {
        added++;
      }
      // Recompute slot with the entry removed (a moved pending item must not
      // count in the block it is being re-appended to).
      final pend = Set<String>.of(pending)..remove(path);
      final slot = nextSlot(q, current, pend);
      q.insert(slot, path);
      pending.add(path);
    }
    return QueueEdit(q, added: added, moved: moved, skipped: skipped);
  }

  static QueueEdit applyAddToQueue(List<String> queue, List<String> paths) {
    final q = List<String>.of(queue);
    var added = 0, skipped = 0;
    for (final path in paths) {
      if (q.contains(path)) {
        skipped++;
      } else {
        q.add(path);
        added++;
      }
    }
    return QueueEdit(q, added: added, skipped: skipped);
  }

  static List<String> applyClearKeepPlaying(List<String> queue, String? current) =>
      (current != null && queue.contains(current)) ? [current] : <String>[];
}
