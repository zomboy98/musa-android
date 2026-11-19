import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_coordinator.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/widgets/jam/jam_session_view.dart';

void main() {
  testWidgets('shows authoritative queue, permissions and errors', (
    tester,
  ) async {
    var queue = JamQueue(hostId: 'host', guestEditingEnabled: false);
    queue = queue
        .apply(const AddJamEntry('one', 'host', 0, 'occ', 'track-1'))
        .state;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: JamSessionView(
            snapshot: queue,
            role: JamRole.host,
            error: 'Connection failed',
          ),
        ),
      ),
    );
    expect(find.text('Host'), findsOneWidget);
    expect(find.text('Add tracks'), findsOneWidget);
    expect(find.text('track-1'), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);
    expect(find.text('Error: Connection failed'), findsOneWidget);
    expect(find.text('Local session'), findsOneWidget);
  });

  testWidgets('switching coordinators shows the new snapshot', (tester) async {
    final a = await JamCoordinator.startEphemeral(hostId: 'a');
    final b = await JamCoordinator.startEphemeral(hostId: 'b');
    addTearDown(a.close);
    addTearDown(b.close);
    a.submitHost(const AddJamEntry('a1', 'a', 0, 'a-occ', 'track-a'));
    b.submitHost(const AddJamEntry('b1', 'b', 0, 'b-occ', 'track-b'));
    Widget view(JamCoordinator coordinator) => MaterialApp(
      home: Scaffold(body: JamCoordinatorView(coordinator: coordinator)),
    );
    await tester.pumpWidget(view(a));
    expect(find.text('track-a'), findsOneWidget);
    await tester.pumpWidget(view(b));
    expect(find.text('track-b'), findsOneWidget);
    expect(find.text('track-a'), findsNothing);
    expect(find.textContaining('playback'), findsNothing);
  });
}
