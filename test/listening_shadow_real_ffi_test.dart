import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/listening_shadow.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
      false;

  test(
    'recorder shadow crosses the real desktop ABI and matches SQLite',
    () async {
      final root = await Directory.systemTemp.createTemp('listening-real-ffi-');
      debugDesktopPlatformOverride = true;
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: root.path,
          documentsDir: root.path,
          tempDir: root.path,
        ),
      );
      addTearDown(() async {
        RustFfiBackend.debugShared = null;
        debugDesktopPlatformOverride = null;
        await root.delete(recursive: true);
      });
      sqfliteFfiInit();
      var calls = 0;
      final errors = <Object>[];
      final shadow = ListeningShadow(
        run: (request) async {
          calls++;
          expect(request['operation'], 'musa_listening_step_v2');
          try {
            return await PlatformBridge.runNativeDataJob(request);
          } catch (error) {
            errors.add(error);
            rethrow;
          }
        },
      );

      Future<List<Map<String, Object?>>> scenario(
        String name,
        ListeningShadow? replay,
      ) async {
        final db = await ListeningStatisticsStore.openWithFactory(
          databaseFactoryFfi,
          '${root.path}/$name.db',
        );
        try {
          var clock = Duration.zero;
          final recorder = ListeningRecorder(
            write: (deltas) => writeListeningDeltas(db, deltas),
            elapsed: () => clock,
            now: () => DateTime(2026, 1, 1).add(clock),
            shadow: replay,
          );
          const track = ListeningTrack(
            key: 'song',
            title: 'Song',
            artist: 'A',
            album: 'B',
          );
          recorder.update(track, playing: true, playbackInstance: 1);
          clock += const Duration(seconds: 10);
          recorder.update(track, playing: false, playbackInstance: 1);
          clock += const Duration(seconds: 10);
          recorder.update(track, playing: true, playbackInstance: 1);
          clock += const Duration(seconds: 20);
          recorder.update(track, playing: true, playbackInstance: 2);
          clock += const Duration(seconds: 31);
          recorder.update(null, playing: false);
          await recorder.flush();
          expect(recorder.idle, isTrue);
          return await db.query('listening', orderBy: 'day, track_key');
        } finally {
          await db.close();
        }
      }

      final reference = await scenario('reference', null);
      final actual = await scenario('shadow', shadow);
      await shadow.drain();
      expect(errors, isEmpty);
      expect(shadow.active, isTrue);
      expect(calls, 11);
      expect(actual, reference);
      expect(actual, hasLength(1));
      expect(actual.single['milliseconds'], 61000);
      expect(actual.single['plays'], 2);
    },
    skip: !enabled,
  );
}
