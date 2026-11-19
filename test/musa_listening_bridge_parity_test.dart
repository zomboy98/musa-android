import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

// Test-only, single-flight protocol. A lost response is fatal: never retry an
// advance on the same engine, since its state may already have changed.
class _Bridge {
  _Bridge(this.process)
    : lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
  final Process process;
  final Stream<String> lines;
  Future<List<String>> call(String command) async {
    final response = lines.first;
    process.stdin.writeln(command);
    final parts = (await response.timeout(
      const Duration(seconds: 30),
    )).split('\t');
    if (parts.first != 'ok') throw StateError(parts.join(':'));
    return parts.skip(1).toList();
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode;
  }
}

String _hex(String s) =>
    utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
String _unhex(String s) => utf8.decode([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

void main() {
  test(
    'bridge rejects an invalid batch without changing the Rust session',
    () async {
      final process = await Process.start('cargo', [
        'run',
        '--quiet',
        '--manifest-path',
        'rust_backend/crates/musa-listening/Cargo.toml',
        '--bin',
        'test_bridge',
      ], runInShell: Platform.isWindows);
      final bridge = _Bridge(process);
      final stderr = process.stderr.transform(utf8.decoder).join();
      try {
        await bridge.call('update\t${_hex('canción/🎵')}\t1\t0');
        await expectLater(
          bridge.call(
            'advance\t${_hex('2026-10-02')}:29999\t${_hex('2026-10-02')}:0',
          ),
          throwsStateError,
        );
        final delta = (await bridge.call(
          'advance\t${_hex('2026-10-02')}:1',
        )).single.split(':');
        expect(_unhex(delta[1]), 'canción/🎵');
        expect(delta.sublist(2), ['1', '0']);
      } finally {
        await bridge.close();
        expect(await process.exitCode, 0, reason: await stderr);
      }
    },
  );

  test(
    'Dart recorder and actual Rust process agree on shared event sequences',
    () async {
      final vectors = File(
        'rust_backend/crates/musa-listening/tests/vectors.txt',
      ).readAsLinesSync().where((s) => s.isNotEmpty && !s.startsWith('#'));
      for (final vector in vectors) {
        final fields = vector.split('|');
        final process = await Process.start('cargo', [
          'run',
          '--quiet',
          '--manifest-path',
          'rust_backend/crates/musa-listening/Cargo.toml',
          '--bin',
          'test_bridge',
        ], runInShell: Platform.isWindows);
        final bridge = _Bridge(process);
        // Drain stderr so compilation errors cannot block the process.
        final stderr = process.stderr.transform(utf8.decoder).join();
        var elapsed = Duration.zero;
        final writes = <ListeningDelta>[];
        final recorder = ListeningRecorder(
          write: (batch) async => writes.addAll(batch),
          elapsed: () => elapsed,
          now: () => DateTime(2026, 10, 2).add(elapsed),
        );
        final rust = <String, List<int>>{};
        try {
          for (final event in fields[1].split(',')) {
            final p = event.split(':');
            switch (p[0]) {
              case 'u':
              case 'x':
                final ended = p[0] == 'x';
                final playing = !ended && p[2] == '1';
                final track = p[1] == '-'
                    ? null
                    : ListeningTrack(
                        key: p[1],
                        title: p[1],
                        artist: '',
                        album: '',
                      );
                recorder.update(track, playing: playing, ended: ended);
                await bridge.call(
                  'update\t${track == null ? '-' : _hex(track.key)}\t${playing ? 1 : 0}\t${ended ? 1 : 0}',
                );
              case 'e':
                recorder.setEnabled(p[1] == '1');
                await bridge.call('enabled\t${p[1]}');
              case 't':
                final ms = int.parse(p[1]);
                elapsed += Duration(milliseconds: ms);
                final results = await bridge.call(
                  'advance\t${_hex('2026-10-02')}:$ms',
                );
                for (final item in results) {
                  final d = item.split(':');
                  final key = _unhex(d[1]);
                  final totals = rust.putIfAbsent(key, () => [0, 0]);
                  totals[0] += int.parse(d[2]);
                  totals[1] += int.parse(d[3]);
                }
              default:
                throw StateError('Unknown event $event');
            }
          }
          await recorder.flush();
          final dart = {
            for (final d in writes) d.track.key: [d.milliseconds, d.plays],
          };
          expect(rust, dart, reason: fields[0]);
        } finally {
          await bridge.close();
          final errors = await stderr;
          expect(await process.exitCode, 0, reason: errors);
        }
      }
    },
  );
}
