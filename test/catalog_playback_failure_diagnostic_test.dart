import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;

const _leaky =
    r'C:\Users\someone\Music\song.m4a https://cdn.example.com/a/b.flac?token=SECRET123 /data/user/0/app/files/x';

void expectClean(String line) {
  for (final forbidden in [
    r'\',
    '/',
    '://',
    'http',
    'secret123',
    'someone',
    'cdn.example',
    '.m4a',
    '.flac',
    'token=',
  ]) {
    expect(
      line.toLowerCase().contains(forbidden.toLowerCase()),
      isFalse,
      reason: 'log line leaks "$forbidden": $line',
    );
  }
}

void main() {
  test('token helper keeps only [a-z_0-9] and at most 60 characters', () {
    final token = sanitizeDiagnosticToken('A-b.C/d ${'x' * 100}');
    expect(RegExp(r'^[a-z_0-9]+$').hasMatch(token), isTrue);
    expect(token.length, 60);
    expect(sanitizeDiagnosticToken(null), '');
  });

  test('platform failures log the code and safe structured fields only', () {
    final line = describeCatalogFailure(
      PlatformException(
        code: 'download_failed',
        message: _leaky,
        details: {
          'error_type': 'quality_unavailable',
          'message': _leaky,
          'provider_attempts': [
            {
              'provider': 'amazon',
              'stage': 'download',
              'error_type': 'quality_unavailable',
              'url': _leaky,
            },
            {'provider': _leaky, 'stage': _leaky, 'error_type': _leaky},
          ],
        },
      ),
      service: 'amazon',
      quality: 'opus',
      progressive: true,
    );
    expectClean(line);
    expect(line, contains('exception=platformexception'));
    expect(line, contains('code=download_failed'));
    expect(line, contains('error_type=quality_unavailable'));
    expect(line, contains('attempts=amazon:download:quality_unavailable;'));
    expect(line, contains('service=amazon'));
    expect(line, contains('quality=opus'));
    expect(line, contains('mode=progressive'));
  });

  test('free-text exceptions never reach the log', () {
    for (final error in <Object>[
      StateError(_leaky),
      FileSystemException(_leaky, r'C:\secret\path'),
      Exception(_leaky),
      TemporaryTrackException(_leaky),
    ]) {
      final line = describeCatalogFailure(
        error,
        service: _leaky,
        quality: _leaky,
      );
      expectClean(line);
      expect(line, contains('mode=full_download'));
    }
    expect(
      describeCatalogFailure(const TemporaryTrackException('invalid AAC output')),
      contains('reason=invalid_aac_output'),
    );
  });

  test('acquire logs the classified cause and keeps the public contract', () async {
    const track = Track(
      id: 'one',
      source: 'spotify',
      name: 'One',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 2,
    );
    final root = await Directory.systemTemp.createTemp('catalog-diag-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await store.initialize();
    final lines = <String>[];
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    )
      ..defaultService = 'amazon'
      ..quality = 'opus'
      ..resolveDownloadService = ((_, _) async => 'amazon')
      ..failureDiagnostic = lines.add;
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'preparation failed',
        ),
      ),
    );
    expect(lines, hasLength(1));
    expectClean(lines.single);
    expect(lines.single, contains('category=preparation_failed'));
    expect(lines.single, contains('exception='));
    expect(lines.single, contains('service=amazon'));
    expect(lines.single, contains('quality=opus'));
    expect(lines.single, contains('mode=full_download'));
  });
}
