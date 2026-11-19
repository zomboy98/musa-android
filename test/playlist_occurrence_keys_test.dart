import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/playlist_screen.dart';

const a = Track(
  id: 'a',
  name: 'A',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 1,
);
const b = Track(
  id: 'b',
  name: 'B',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 1,
);

void main() {
  test('snapshot context changes on removal but survives reorder', () {
    final original = playlistMultiplicitySignature([a, b, a]);
    expect(playlistMultiplicitySignature([b, a, a]), original);
    expect(playlistMultiplicitySignature([b, a]), isNot(original));
  });
  test(
    'filtering retains the occurrence key assigned on the complete list',
    () {
      final all = [a, b, a];
      final keys = playlistOccurrenceKeys(all);
      final filtered = [
        for (var i = 0; i < all.length; i++)
          if (i != 0) keys[i],
      ];
      expect(filtered.last, keys[2]);
      expect(filtered.last, isNot(keys[0]));
    },
  );
  testWidgets(
    'duplicate occurrences remain distinct and retain state after reorder',
    (tester) async {
      var tracks = [a, b, a];
      final activations = <String>[];
      Widget page() {
        final keys = playlistOccurrenceKeys(tracks);
        final indexes = {for (var i = 0; i < keys.length; i++) keys[i]: i};
        return MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, i) => _Row(
                      key: keys[i],
                      title: tracks[i].name,
                      onTap: () => activations.add('$i'),
                    ),
                    childCount: tracks.length,
                    findChildIndexCallback: (key) => indexes[key],
                  ),
                ),
              ],
            ),
          ),
        );
      }

      await tester.pumpWidget(page());
      await tester.tap(find.text('A:0').first);
      await tester.tap(find.text('A:0').last);
      await tester.pump();
      expect(activations, ['0', '2']);
      expect(find.text('A:1'), findsNWidgets(2));
      tracks = [b, a, a];
      await tester.pumpWidget(page());
      expect(tester.takeException(), isNull);
      expect(find.text('A:1'), findsNWidgets(2));
      await tester.tap(find.text('A:1').last);
      expect(activations.last, '2');
    },
  );
}

class _Row extends StatefulWidget {
  const _Row({super.key, required this.title, required this.onTap});
  final String title;
  final VoidCallback onTap;
  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  var taps = 0;
  @override
  Widget build(BuildContext context) => ListTile(
    title: Text('${widget.title}:$taps'),
    onTap: () {
      setState(() => taps++);
      widget.onTap();
    },
  );
}
