import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/artist_screen.dart';

Track _t(int n) => Track(
  id: 't$n',
  name: 'n$n',
  artistName: 'a',
  albumName: 'b',
  duration: 100,
);

void main() {
  final popular = [for (var i = 0; i < 12; i++) _t(i)];

  test('tapping the second popular row queues every track from index 1', () {
    final plan = popularTrackQueue(popular, popular[1], 1);
    expect(plan.queue.map((t) => t.id), popular.map((t) => t.id));
    expect(plan.start, 1);
    expect(plan.queue[plan.start].id, 't1');
  });

  test('next from the second row lands on the third and previous on first', () {
    final plan = popularTrackQueue(popular, popular[1], 1);
    expect(plan.queue[plan.start + 1].id, 't2');
    expect(plan.queue[plan.start - 1].id, 't0');
    expect(plan.queue.length - plan.start - 1, 10);
  });

  test('a row on a later page keeps its place in the whole list', () {
    final plan = popularTrackQueue(popular, popular[7], 7);
    expect(plan.queue, hasLength(12));
    expect(plan.start, 7);
  });

  test('a stale index falls back to the track id, then to playing alone', () {
    expect(popularTrackQueue(popular, popular[4], 0).start, 4);
    final gone = _t(99);
    final alone = popularTrackQueue(popular, gone, 3);
    expect(alone.queue.map((t) => t.id), ['t99']);
    expect(alone.start, 0);
    expect(popularTrackQueue(null, gone, 0).queue, hasLength(1));
  });

  test('the queue is a copy: later changes to the list do not alter it', () {
    final list = [...popular];
    final plan = popularTrackQueue(list, list[0], 0);
    list.removeLast();
    expect(plan.queue, hasLength(12));
  });
}
