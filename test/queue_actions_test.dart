import 'package:flutter_test/flutter_test.dart';
import 'package:music/library/queue_logic.dart';

void main() {
  group('playNext', () {
    test('inserts after current', () {
      final e = QueueLogic.applyPlayNext(['a', 'b', 'c'], 'a', <String>{}, ['x']);
      expect(e.queue, ['a', 'x', 'b', 'c']);
      expect(e.added, 1);
    });
    test('FIFO among play-next items', () {
      final pend = <String>{};
      var q = QueueLogic.applyPlayNext(['a', 'b', 'c'], 'a', pend, ['x']).queue;
      q = QueueLogic.applyPlayNext(q, 'a', pend, ['y', 'z']).queue;
      expect(q, ['a', 'x', 'y', 'z', 'b', 'c']);
    });
    test('existing song is moved, not duplicated', () {
      final e = QueueLogic.applyPlayNext(['a', 'b', 'c', 'd'], 'a', <String>{}, ['d']);
      expect(e.queue, ['a', 'd', 'b', 'c']);
      expect(e.moved, 1);
      expect(e.added, 0);
    });
    test('re-adding a pending item sends it to the end of the block', () {
      final pend = <String>{};
      var q = QueueLogic.applyPlayNext(['a', 'b'], 'a', pend, ['x', 'y']).queue;
      q = QueueLogic.applyPlayNext(q, 'a', pend, ['x']).queue;
      expect(q, ['a', 'y', 'x', 'b']);
    });
    test('current track is skipped', () {
      final e = QueueLogic.applyPlayNext(['a', 'b'], 'a', <String>{}, ['a']);
      expect(e.changed, false);
      expect(e.skipped, 1);
      expect(e.queue, ['a', 'b']);
    });
    test('no current: goes to the front', () {
      expect(QueueLogic.applyPlayNext(['a', 'b'], null, <String>{}, ['x']).queue, ['x', 'a', 'b']);
    });
    test('duplicates in one request collapse', () {
      expect(QueueLogic.applyPlayNext(['a'], 'a', <String>{}, ['x', 'x']).queue, ['a', 'x']);
    });
  });
  group('addToQueue', () {
    test('appends in order, skips existing', () {
      final e = QueueLogic.applyAddToQueue(['a', 'b'], ['c', 'a', 'd']);
      expect(e.queue, ['a', 'b', 'c', 'd']);
      expect(e.added, 2);
      expect(e.skipped, 1);
    });
  });
  group('clear', () {
    test('keeps only the playing track', () {
      expect(QueueLogic.applyClearKeepPlaying(['a', 'b', 'c'], 'b'), ['b']);
      expect(QueueLogic.applyClearKeepPlaying(['a', 'b'], null), isEmpty);
    });
  });
  test('pendingNextFor picks oldest pending still queued', () {
    QueueLogic.pending
      ..clear()
      ..addAll({'y', 'z'});
    expect(QueueLogic.pendingNextFor(['a', 'z', 'y'], 'a'), 'z');
    expect(QueueLogic.pendingNextFor(['a', 'z', 'y'], 'z'), 'y');
    QueueLogic.pending.clear();
  });
}
