// lib/library/queue_actions.dart
//
// The single "Play next" / "Add to queue" / "Clear queue" API.
//
// Rules (the queue is keyed by file PATH across the whole app: native index
// lookup, highlight, shuffle, resume — so a path appears at most once):
//  * playNext: inserts right after the playing track, after any tracks that
//    were previously "play next"-ed (FIFO among them). A song already in the
//    queue is MOVED to that slot (never duplicated); the playing track itself
//    is skipped ("already playing").
//  * addToQueue: appends at the end. A song already in the queue is left
//    alone and reported as "already in queue" (no duplicates).
//  * With no queue yet, the paths simply become the queue (nothing starts).
//  * clearKeepPlaying: queue becomes just the playing track.
// Every edit goes through PlaylistContext.setCurrentPlaylist, which the Songs
// page already mirrors into the live native queue (single insert is patched
// in place; moves/bulk adds do a position-preserving rebuild) and persists via
// PlaylistService.saveQueue. Shuffle mode honours play-next via
// PlaylistContext.pickShuffleCandidate; repeat-one keeps repeating the song.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'queue_logic.dart';
import '../player_screen.dart' show PlaylistContext, PlaylistService;

class QueueActions {
  QueueActions._();

  static Set<String> get _pendingNext => QueueLogic.pending;
  static Set<String> get pendingNext => QueueLogic.pending;

  static bool _listening = false;
  static void _ensureListening() {
    if (_listening) return;
    _listening = true;
    PlaylistContext.currentPathNotifier.addListener(() {
      final cur = PlaylistContext.currentPathNotifier.value;
      if (cur != null) _pendingNext.remove(cur);
    });
  }

  static String? pendingNextFor(List<String> l, String? c) => QueueLogic.pendingNextFor(l, c);
  static QueueEdit applyPlayNext(List<String> q, String? c, Set<String> p, List<String> x) => QueueLogic.applyPlayNext(q, c, p, x);

  // ------------------------------------------------------------- stateful

  static void _commit(List<String> list) {
    PlaylistContext.setCurrentPlaylist(
      list,
      pageId: PlaylistContext.getCurrentPageId() ?? 'queue',
      folderPath: PlaylistContext.getCurrentFolder(),
    );
    PlaylistService.saveQueue(list);
  }

  static List<String> _snapshot() => List<String>.of(PlaylistContext.getCurrentPlaylist() ?? const <String>[]);

  static QueueResult playNext(List<String> paths) {
    _ensureListening();
    final before = _snapshot();
    _pendingNext.retainWhere(before.contains);
    final pendingBefore = Set<String>.of(_pendingNext);
    final edit = applyPlayNext(before, PlaylistContext.currentPathNotifier.value, _pendingNext, paths);
    if (edit.changed) _commit(edit.queue);
    return QueueResult._(edit, before, pendingBefore, next: true);
  }

  static QueueResult addToQueue(List<String> paths) {
    _ensureListening();
    final before = _snapshot();
    final edit = QueueLogic.applyAddToQueue(before, paths);
    if (edit.changed) _commit(edit.queue);
    return QueueResult._(edit, before, Set<String>.of(_pendingNext), next: false);
  }

  /// Keeps the playing track, drops everything else.
  static QueueResult clearKeepPlaying() {
    final before = _snapshot();
    final cleared = QueueLogic.applyClearKeepPlaying(before, PlaylistContext.currentPathNotifier.value);
    final pendingBefore = Set<String>.of(_pendingNext);
    _pendingNext.clear();
    final edit = QueueEdit(cleared, moved: (before.length - cleared.length).clamp(0, 1 << 30).toInt());
    if (before.length != cleared.length) _commit(cleared);
    return QueueResult._(edit, before, pendingBefore, next: false, cleared: true);
  }

  /// Shows the standard snackbar (with Undo) for [r]. Safe if context is gone.
  static void showFeedback(BuildContext context, QueueResult r) {
    if (!context.mounted) return;
    final m = ScaffoldMessenger.maybeOf(context);
    if (m == null) return;
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(
      content: Text(r.localizedMessage(context.l10n)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
      action: r.edit.changed ? SnackBarAction(label: context.l10n.undo, onPressed: r.undo) : null,
    ));
  }

  /// Convenience for menus: do it and show feedback.
  static void playNextWithFeedback(BuildContext context, List<String> paths) =>
      showFeedback(context, playNext(paths));
  static void addToQueueWithFeedback(BuildContext context, List<String> paths) =>
      showFeedback(context, addToQueue(paths));
}

class QueueResult {
  final QueueEdit edit;
  final List<String> _before;
  final Set<String> _pendingBefore;
  final bool next;
  final bool cleared;
  QueueResult._(this.edit, this._before, this._pendingBefore, {required this.next, this.cleared = false});

  /// Localized equivalent of [message] (which stays English for logs/tests).
  String localizedMessage(AppLocalizations l) {
    if (cleared) return edit.changed ? l.queueCleared : l.queueAlreadyEmpty;
    final n = edit.added + edit.moved;
    if (n == 0) return edit.skipped > 0 && next ? l.alreadyPlaying : l.alreadyInQueue;
    if (next) return n == 1 ? l.willPlayNext : l.songsWillPlayNext(n);
    return n == 1 ? l.addedToQueue : l.addedSongsToQueue(n);
  }

  String get message {
    if (cleared) return edit.changed ? 'Queue cleared' : 'Queue already empty';
    final n = edit.added + edit.moved;
    if (n == 0) return edit.skipped > 0 && next ? 'Already playing' : 'Already in queue';
    if (next) return n == 1 ? 'Will play next' : '$n songs will play next';
    return n == 1 ? 'Added to queue' : 'Added $n songs to queue';
  }

  /// Restores the queue as it was, unless it has been edited since.
  void undo() {
    if (!edit.changed) return;
    if (!listEquals(PlaylistContext.getCurrentPlaylist(), edit.queue)) return;
    QueueActions.pendingNext
      ..clear()
      ..addAll(_pendingBefore);
    QueueActions._commit(List<String>.of(_before));
  }
}
