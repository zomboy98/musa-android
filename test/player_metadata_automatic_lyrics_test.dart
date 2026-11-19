import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/source_metadata_events.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/desktop_platform.dart';

MediaItem catalogItem(
  String id, {
  String provider = 'spotify',
  int duration = 183,
  String? resolvedSource,
}) => playableFromCatalogTrack(
  Track(
    id: id,
    source: provider,
    name: 'Song $id',
    artistName: 'Artist',
    albumName: 'Album',
    duration: duration,
  ),
).toMediaItem(resolvedSource: resolvedSource);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('catalog badge uses only current measured audio quality', () async {
    final controller = PlayerMetadataController(automaticOnlineSearch: false);
    addTearDown(controller.dispose);
    final item = catalogItem('quality').copyWith(
      extras: {
        ...catalogItem('quality').extras!,
        'format': 'flac',
        'bit_depth': 24,
        'sample_rate': 192000,
        'bitrate': 320,
      },
    );
    await controller.load(item);
    expect(controller.qualityLabel, isNull);
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.load(
      item.copyWith(
        extras: {
          ...item.extras!,
          'verifiedAudioCodec': 'aac',
          'verifiedAudioSampleRate': 44100,
        },
      ),
    );
    expect(controller.qualityLabel, 'AAC  ·  44.1 kHz');
    expect(notifications, greaterThan(0));
    await controller.load(item);
    expect(controller.qualityLabel, isNull);
    await controller.load(
      item.copyWith(
        extras: {
          ...item.extras!,
          'verifiedAudioCodec': '/private/file',
          'verifiedAudioSampleRate': -1,
        },
      ),
    );
    expect(controller.qualityLabel, isNull);
    await controller.load(
      MediaItem(
        id: 'local',
        title: 'Local',
        artist: 'Artist',
        extras: const {'source': 'https://example.test/a', 'format': 'mp3'},
      ),
    );
    expect(controller.qualityLabel, 'MP3');
  });

  test(
    'local tags enrich the request without changing the queue item',
    () async {
      final requests = <MediaItem>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => {
          'title': 'Real song',
          'artist': 'Real artist',
          'duration': 217,
        },
        fetchOnlineLyrics: (item) async {
          requests.add(item);
          return '[00:01]Found';
        },
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        saveOnlineLyrics: (_, _) async =>
            fail('Automatic search must not write'),
      );
      addTearDown(controller.dispose);
      final item = MediaItem(
        id: 'a',
        title: 'Unknown title',
        artist: '',
        extras: const {'source': '/music/a.flac'},
      );
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      expect(requests.single.title, 'Real song');
      expect(requests.single.artist, 'Real artist');
      expect(requests.single.duration, const Duration(seconds: 217));
      expect(requests.single.id, item.id);
      expect(requests.single.extras, item.extras);
      expect(controller.item, same(item));
      expect(controller.lyrics.lines.single.text, 'Found');
    },
  );

  test('valid queue identity wins over conflicting local tags', () async {
    MediaItem? request;
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => {
        'title': 'Other song',
        'artist': 'Other artist',
        'duration': 150,
      },
      fetchOnlineLyrics: (item) async {
        request = item;
        return '';
      },
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'a',
        title: 'Queue song',
        artist: 'Queue artist',
        duration: const Duration(seconds: 210),
        extras: const {'source': '/music/a.flac'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(request?.title, 'Queue song');
    expect(request?.artist, 'Queue artist');
    expect(request?.duration, const Duration(seconds: 210));
  });

  test('placeholder local tags do not enable online lookup', () async {
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => {
        'title': 'Unknown title',
        'artist': 'Unknown artist',
      },
      fetchOnlineLyrics: (_) async =>
          fail('Placeholder cannot identify a song'),
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'a',
        title: 'Unknown title',
        artist: '',
        extras: const {'source': '/music/a.flac'},
      ),
    );
    expect(controller.canSearchOnline, isFalse);
  });

  test('changed local identity discards an in-flight lookup', () async {
    final events = SourceMetadataEvents();
    final first = Completer<String>();
    var title = 'First song';
    final requests = <String>[];
    final controller = PlayerMetadataController(
      metadataEvents: events,
      onlineAvailable: () async => true,
      readMetadata: (_) async => {
        'title': title,
        'artist': 'Artist',
        'duration': 200,
      },
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (item) {
        requests.add(item.title);
        return requests.length == 1
            ? first.future
            : Future.value('[00:01]Correct');
      },
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'a',
        title: 'Unknown title',
        artist: '',
        extras: const {'source': '/music/a.flac'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    title = 'Second song';
    await events.publish('/music/a.flac');
    first.complete('[00:01]Wrong');
    await Future<void>.delayed(Duration.zero);
    expect(requests, ['First song', 'Second song']);
    expect(controller.lyrics.lines.single.text, 'Correct');
  });

  test(
    'completed local lookup is replaced only when identity changes',
    () async {
      final events = SourceMetadataEvents();
      var title = 'First song';
      final second = Completer<String>();
      final requests = <String>[];
      final controller = PlayerMetadataController(
        metadataEvents: events,
        onlineAvailable: () async => true,
        readMetadata: (_) async => {
          'title': title,
          'artist': 'Artist',
          'duration': 200,
        },
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) {
          requests.add(item.title);
          return requests.length == 1
              ? Future.value('[00:01]First')
              : second.future;
        },
      );
      addTearDown(controller.dispose);
      await controller.load(
        MediaItem(
          id: 'a',
          title: 'Unknown title',
          artist: '',
          extras: const {'source': '/music/a.flac'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'First');
      title = 'FIRST SONG';
      await events.publish('/music/a.flac');
      expect(requests, hasLength(1));
      expect(controller.lyrics.lines.single.text, 'First');
      title = 'Second song';
      await events.publish('/music/a.flac');
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.isEmpty, isTrue);
      expect(requests, ['First song', 'Second song']);
      second.complete('[00:01]Second');
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'Second');
    },
  );

  for (final mode in ['offline', 'embedded', 'edited']) {
    test('identity change preserves $mode behavior', () async {
      final events = SourceMetadataEvents();
      final changes = StreamController<bool>.broadcast();
      addTearDown(changes.close);
      var title = 'First';
      var embedded = '';
      var online = true;
      final requests = <String>[];
      final controller = PlayerMetadataController(
        metadataEvents: events,
        onlineAvailable: () async => online,
        onlineChanges: changes.stream,
        readMetadata: (_) async => {
          'title': title,
          'artist': 'Artist',
          'duration': 200,
          'lyrics': embedded,
        },
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) async {
          requests.add(item.title);
          return '[00:01]Online';
        },
        saveOnlineLyrics: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await controller.load(
        MediaItem(
          id: 'a',
          title: 'Unknown title',
          artist: '',
          extras: const {'source': '/music/a.flac'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      if (mode == 'edited') await controller.saveEditedLyrics('[00:01]Manual');
      if (mode == 'embedded') embedded = '[00:01]Embedded';
      if (mode == 'offline') online = false;
      title = 'Second';
      await events.publish('/music/a.flac');
      await Future<void>.delayed(Duration.zero);
      if (mode == 'offline') {
        expect(controller.lyrics.isEmpty, isTrue);
        expect(controller.onlineDeferredOffline, isTrue);
        changes.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(requests, ['First', 'Second']);
      } else {
        expect(requests, ['First']);
        expect(
          controller.lyrics.lines.single.text,
          mode == 'edited' ? 'Manual' : 'Embedded',
        );
      }
    });
  }

  for (final source in ['/music/a.flac', 'https://example.test/a.mp3']) {
    test(
      'same source updates lyrics when queue identity changes: $source',
      () async {
        final second = Completer<String>();
        final requests = <String>[];
        final controller = PlayerMetadataController(
          onlineAvailable: () async => true,
          readMetadata: (_) async => const {},
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (item) {
            requests.add(item.title);
            return requests.length == 1
                ? Future.value('[00:01]First')
                : second.future;
          },
        );
        addTearDown(controller.dispose);
        final item = MediaItem(
          id: 'a',
          title: 'First',
          artist: 'Artist',
          duration: const Duration(seconds: 200),
          extras: {'source': source},
        );
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        await controller.load(item.copyWith(title: 'FIRST'));
        expect(requests, ['First']);
        expect(controller.lyrics.lines.single.text, 'First');
        await controller.load(item.copyWith(title: 'Second'));
        await Future<void>.delayed(Duration.zero);
        expect(controller.lyrics.isEmpty, isTrue);
        expect(requests, ['First', 'Second']);
        second.complete('[00:01]Second');
        await Future<void>.delayed(Duration.zero);
        expect(controller.lyrics.lines.single.text, 'Second');
      },
    );
  }

  for (final source in [
    '/music/partial.flac',
    'https://example.test/partial',
  ]) {
    for (final changedField in ['title', 'artist']) {
      test(
        'partial $changedField contradiction invalidates lyrics: $source',
        () async {
          final requests = <MediaItem>[];
          final controller = PlayerMetadataController(
            onlineAvailable: () async => true,
            readMetadata: (_) async => const {},
            parseLyrics: (raw) async => LyricsParser.parse(raw),
            fetchOnlineLyrics: (item) async {
              requests.add(item);
              return '[00:01]Words';
            },
          );
          addTearDown(controller.dispose);
          final initial = MediaItem(
            id: 'a',
            title: 'First',
            artist: 'Artist',
            duration: const Duration(seconds: 200),
            extras: {'source': source},
          );
          await controller.load(initial);
          await Future<void>.delayed(Duration.zero);
          await controller.load(initial.copyWith(title: '', artist: ''));
          expect(controller.lyrics.lines.single.text, 'Words');
          await controller.load(
            initial.copyWith(title: 'FIRST', artist: 'ARTIST'),
          );
          expect(requests, hasLength(1));
          final partial = changedField == 'title'
              ? initial.copyWith(title: 'Second', artist: '')
              : initial.copyWith(title: '', artist: 'Other');
          await controller.load(partial);
          await Future<void>.delayed(Duration.zero);
          expect(controller.lyrics.isEmpty, isTrue);
          expect(requests, hasLength(1));
          await controller.load(
            changedField == 'title'
                ? partial.copyWith(artist: 'Artist')
                : partial.copyWith(title: 'First'),
          );
          await Future<void>.delayed(Duration.zero);
          expect(requests, hasLength(2));
        },
      );
    }
  }

  for (final source in [
    '/music/offline.flac',
    'https://example.test/offline',
  ]) {
    test(
      'online during partial identity retries when complete: $source',
      () async {
        final changes = StreamController<bool>.broadcast();
        addTearDown(changes.close);
        var available = false;
        final requests = <MediaItem>[];
        final controller = PlayerMetadataController(
          onlineAvailable: () async => available,
          onlineChanges: changes.stream,
          readMetadata: (_) async => const {},
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (item) async {
            requests.add(item);
            return '[00:01]Words';
          },
        );
        addTearDown(controller.dispose);
        final item = MediaItem(
          id: 'a',
          title: 'Song',
          artist: 'Artist',
          duration: const Duration(seconds: 200),
          extras: {'source': source},
        );
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        expect(controller.onlineDeferredOffline, isTrue);
        await controller.load(item.copyWith(artist: ''));
        available = true;
        changes.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(controller.onlineDeferredOffline, isFalse);
        expect(requests, isEmpty);
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));
        expect(controller.lyrics.lines.single.text, 'Words');
        changes.add(true);
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        expect(requests, hasLength(1));
      },
    );
  }

  for (final success in [true, false]) {
    test(
      'reconnect while edit pending resolves after save: $success',
      () async {
        final changes = StreamController<bool>.broadcast();
        addTearDown(changes.close);
        final save = Completer<void>();
        var available = false;
        var requests = 0;
        final controller = PlayerMetadataController(
          onlineAvailable: () async => available,
          onlineChanges: changes.stream,
          readMetadata: (_) async => const {},
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (_) async {
            requests++;
            return '[00:01]Online';
          },
          saveOnlineLyrics: (_, _) => save.future,
        );
        addTearDown(controller.dispose);
        final item = MediaItem(
          id: 'a',
          title: 'Song',
          artist: 'Artist',
          duration: const Duration(seconds: 200),
          extras: const {'source': '/music/save.flac'},
        );
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        expect(controller.onlineDeferredOffline, isTrue);
        final edit = controller.saveEditedLyrics('[00:01]Manual');
        final failure = success ? null : expectLater(edit, throwsStateError);
        await Future<void>.delayed(Duration.zero);
        available = true;
        changes.add(true);
        await Future<void>.delayed(Duration.zero);
        expect(requests, 0);
        if (success) {
          save.complete();
          await edit;
        } else {
          save.completeError(StateError('Read only'));
          await failure;
        }
        await Future<void>.delayed(Duration.zero);
        expect(requests, success ? 0 : 1);
        expect(
          controller.lyrics.lines.single.text,
          success ? 'Manual' : 'Online',
        );
        changes.add(true);
        await controller.load(item);
        await Future<void>.delayed(Duration.zero);
        expect(requests, success ? 0 : 1);
      },
    );
  }

  for (final (payload, instrumental, text) in [
    ('[00:01]Words', false, 'Words'),
    ('', true, ''),
    ('[ti:Header]\n[00:01]', true, ''),
  ]) {
    test(
      'bridge resolves contradictory or empty instrumental payload: $payload',
      () async {
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {'instrumental': true, 'lyrics': payload},
        );
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final controller = PlayerMetadataController(
          onlineAvailable: () async => true,
          parseLyrics: (raw) async => LyricsParser.parse(raw),
        );
        addTearDown(controller.dispose);
        await controller.load(catalogItem('bridge'));
        for (var i = 0; i < 10 && controller.searchingOnline; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(controller.onlineInstrumental, instrumental);
        if (text.isNotEmpty) expect(controller.lyrics.lines.single.text, text);
        if (text.isEmpty) expect(controller.lyrics.isEmpty, isTrue);
      },
    );
  }

  test(
    'instrumental replaces prior online text and revalidates unknown duration',
    () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        automaticOnlineSearch: false,
        fetchOnlineLyrics: (_) async =>
            ++calls == 1 ? 'Prior words' : '[instrumental:true]',
        parseLyrics: (raw) async => LyricsParser.parse(raw),
      );
      addTearDown(controller.dispose);
      final item = catalogItem('transition');
      await controller.load(item);
      await controller.searchOnline();
      expect(controller.lyrics.plainText, contains('Prior words'));
      await controller.searchOnline();
      expect(controller.onlineInstrumental, isTrue);
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.metadata?['lyrics'], isNull);

      var retryCalls = 0;
      final retry = PlayerMetadataController(
        onlineAvailable: () async => true,
        fetchOnlineLyrics: (_) async {
          retryCalls++;
          return '[instrumental:true]';
        },
      );
      addTearDown(retry.dispose);
      final unknown = catalogItem('unknown', duration: 0);
      await retry.load(unknown);
      await Future<void>.delayed(Duration.zero);
      expect(retry.onlineInstrumental, isTrue);
      expect(retry.onlineLyricsProvisional, isTrue);
      await retry.load(
        unknown.copyWith(duration: const Duration(seconds: 183)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(retryCalls, 2);
      expect(retry.onlineInstrumental, isTrue);
      expect(retry.onlineLyricsProvisional, isFalse);
    },
  );

  test('late instrumental result cannot replace a new track', () async {
    final pending = Completer<String>();
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      fetchOnlineLyrics: (item) =>
          item.title == 'Song old' ? pending.future : Future.value('New words'),
      parseLyrics: (raw) async => LyricsParser.parse(raw),
    );
    addTearDown(controller.dispose);
    await controller.load(catalogItem('old'));
    await Future<void>.delayed(Duration.zero);
    await controller.load(catalogItem('new'));
    await Future<void>.delayed(Duration.zero);
    pending.complete('[instrumental:true]');
    await Future<void>.delayed(Duration.zero);
    expect(controller.onlineInstrumental, isFalse);
    expect(controller.lyrics.plainText, contains('New words'));
  });

  test(
    'instrumental result is retained without invented lyrics or repeated lookup',
    () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        fetchOnlineLyrics: (_) async {
          calls++;
          return '[instrumental:true]';
        },
        saveOnlineLyrics: (_, _) async =>
            fail('Instrumental must not be embedded'),
      );
      addTearDown(controller.dispose);
      final item = catalogItem('instrumental');
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(controller.onlineInstrumental, isTrue);
      expect(controller.onlineSearchMissed, isFalse);
      expect(controller.lyrics.isEmpty, isTrue);
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );

  for (final authoritative in ['embedded', 'edited']) {
    test(
      '$authoritative lyrics replace provisional and are never duration-revalidated',
      () async {
        var stored = '';
        var calls = 0;
        final events = SourceMetadataEvents();
        final controller = PlayerMetadataController(
          onlineAvailable: () async => true,
          metadataEvents: events,
          readMetadata: (_) async => {'lyrics': stored},
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (_) async {
            calls++;
            return '[00:01]Provisional';
          },
          saveOnlineLyrics: (_, raw) async {
            stored = raw;
          },
        );
        addTearDown(controller.dispose);
        final initial = MediaItem(
          id: 'local',
          title: 'Song',
          artist: 'Artist',
          extras: const {'source': '/music/song.flac'},
        );
        await controller.load(initial);
        await Future<void>.delayed(Duration.zero);
        expect(controller.onlineLyricsProvisional, isTrue);
        if (authoritative == 'embedded') {
          stored = '[00:01]Authoritative';
          await events.publish('/music/song.flac');
        } else {
          await controller.saveEditedLyrics('[00:01]Authoritative');
        }
        await controller.load(
          initial.copyWith(duration: const Duration(seconds: 240)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(controller.onlineLyricsProvisional, isFalse);
        expect(controller.lyrics.lines.single.text, 'Authoritative');
        expect(calls, 1);
      },
    );
  }

  test(
    'edit during provisional revalidation survives the provider response',
    () async {
      final revalidation = Completer<String>();
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) => ++calls == 1
            ? Future.value('[00:01]Provisional')
            : revalidation.future,
        saveOnlineLyrics: (_, _) async {},
      );
      addTearDown(controller.dispose);
      final initial = MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      );
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 240)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.isEmpty, isTrue);
      await controller.saveEditedLyrics('[00:01]My correction');
      revalidation.complete('[00:01]Provider version');
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'My correction');
      expect(controller.onlineLyricsProvisional, isFalse);
      expect(calls, 2);
    },
  );

  test(
    'failed revalidation removes provisional text and reports provider error',
    () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async {
          if (++calls == 1) return '[00:01]Provisional';
          throw StateError('Unavailable');
        },
      );
      addTearDown(controller.dispose);
      final initial = catalogItem('a', duration: 0);
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 240)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.isEmpty, isTrue);
      expect(controller.onlineSearchFailed, isTrue);
      expect(controller.onlineSearchMissed, isFalse);
      expect(controller.onlineLyricsProvisional, isFalse);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 241)),
      );
      expect(calls, 2);
    },
  );

  test(
    'explicit no-duration provisional lookup never persists local audio',
    () async {
      final controller = PlayerMetadataController(
        automaticOnlineSearch: false,
        readMetadata: (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async => '[00:01]Provisional',
        saveOnlineLyrics: (_, _) async =>
            fail('Unverified text must not be embedded'),
      );
      addTearDown(controller.dispose);
      await controller.load(
        MediaItem(
          id: 'local',
          title: 'Song',
          artist: 'Artist',
          extras: const {'source': '/music/song.flac'},
        ),
      );
      await controller.searchOnline();
      expect(controller.onlineLyricsProvisional, isTrue);
      expect(controller.onlineLyricsSaveFailed, isFalse);
    },
  );

  for (final verified in [true, false]) {
    test(
      'published no-duration lyrics revalidate once when duration arrives ($verified)',
      () async {
        final durations = <int>[];
        final controller = PlayerMetadataController(
          onlineAvailable: () async => true,
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (item) async {
            durations.add(item.duration?.inMilliseconds ?? 0);
            return durations.length == 1
                ? '[00:01]Provisional recording'
                : verified
                ? '[00:01]Verified recording'
                : '';
          },
          saveOnlineLyrics: (_, _) async =>
              fail('Provisional/automatic must not write'),
        );
        addTearDown(controller.dispose);
        final initial = catalogItem('a', duration: 0);
        await controller.load(initial);
        await Future<void>.delayed(Duration.zero);
        expect(controller.lyrics.lines.single.text, 'Provisional recording');
        await controller.load(
          initial.copyWith(duration: const Duration(seconds: 240)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(durations, [0, 240000]);
        if (verified) {
          expect(controller.lyrics.lines.single.text, 'Verified recording');
        } else {
          expect(controller.lyrics.isEmpty, isTrue);
          expect(controller.onlineSearchMissed, isTrue);
        }
        await controller.load(
          initial.copyWith(duration: const Duration(seconds: 241)),
        );
        await Future<void>.delayed(Duration.zero);
        expect(durations, [0, 240000]);
      },
    );
  }

  test(
    'edit starting during retry availability does not spend the retry',
    () async {
      final saving = Completer<void>();
      final availability = Completer<bool>();
      var checks = 0;
      final durations = <int>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () =>
            ++checks == 2 ? availability.future : Future.value(true),
        readMetadata: (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) async {
          durations.add(item.duration?.inMilliseconds ?? 0);
          return durations.length == 1 ? '' : '[00:01]Known recording';
        },
        saveOnlineLyrics: (_, _) => saving.future,
      );
      addTearDown(controller.dispose);
      final initial = MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      );
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 240)),
      );
      expect(checks, 2);
      final edit = controller.saveEditedLyrics('[00:01]Correction');
      final failedEdit = expectLater(edit, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      availability.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0]);
      saving.completeError(StateError('Read only'));
      await failedEdit;
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0, 240000]);
      expect(controller.lyrics.lines.single.text, 'Known recording');
    },
  );

  test(
    'unknown-duration success is discarded when real duration arrived meanwhile',
    () async {
      final first = Completer<String>();
      final durations = <int>[];
      final shown = <String>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) {
          durations.add(item.duration?.inMilliseconds ?? 0);
          return durations.length == 1
              ? first.future
              : Future.value('[00:01]240 second recording');
        },
      );
      controller.addListener(() => shown.add(controller.rawLyrics));
      addTearDown(controller.dispose);
      final initial = catalogItem('a', duration: 0);
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 240)),
      );
      first.complete('[00:01]Wrong 180 second recording');
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0, 240000]);
      expect(shown.any((raw) => raw.contains('Wrong')), isFalse);
      expect(controller.lyrics.lines.single.text, '240 second recording');
    },
  );

  test('failed pending edit cannot consume the known-duration retry', () async {
    final saving = Completer<void>();
    final durations = <int>[];
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => const {},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (item) async {
        durations.add(item.duration?.inMilliseconds ?? 0);
        return durations.length == 1 ? '' : '[00:01]Known recording';
      },
      saveOnlineLyrics: (_, _) => saving.future,
    );
    addTearDown(controller.dispose);
    final initial = MediaItem(
      id: 'local',
      title: 'Song',
      artist: 'Artist',
      extras: const {'source': '/music/song.flac'},
    );
    await controller.load(initial);
    await Future<void>.delayed(Duration.zero);
    final edit = controller.saveEditedLyrics('[00:01]Correction');
    final failedEdit = expectLater(edit, throwsStateError);
    await Future<void>.delayed(Duration.zero);
    await controller.load(
      initial.copyWith(duration: const Duration(seconds: 240)),
    );
    await Future<void>.delayed(Duration.zero);
    saving.completeError(StateError('Read only'));
    await failedEdit;
    await Future<void>.delayed(Duration.zero);
    expect(durations, [0, 240000]);
    expect(controller.lyrics.lines.single.text, 'Known recording');
  });

  test('native duration recovery sends exact milliseconds only once', () async {
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    const channel = MethodChannel('com.zarz.mornye/backend');
    final requests = <Map<dynamic, dynamic>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      requests.add(args);
      return {
        'lyrics': args['duration_ms'] == 221355
            ? '[00:01]Correct recording'
            : '',
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      parseLyrics: (raw) async => LyricsParser.parse(raw),
    );
    addTearDown(controller.dispose);
    final initial = catalogItem('recording', duration: 0);
    await controller.load(initial);
    for (var i = 0; i < 10 && !controller.onlineSearchMissed; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final known = initial.copyWith(
      duration: const Duration(milliseconds: 221355),
    );
    await controller.load(known);
    for (var i = 0; i < 10 && controller.lyrics.isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    await controller.load(known);
    expect(requests.map((r) => r['duration_ms']), [0, 221355]);
    expect(requests.map((r) => r['spotify_id']), ['recording', 'recording']);
    expect(controller.lyrics.lines.single.text, 'Correct recording');
  });

  test(
    'initially known duration is never automatically retried after a miss',
    () async {
      final durations = <int>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        fetchOnlineLyrics: (item) async {
          durations.add(item.duration!.inMilliseconds);
          return '';
        },
      );
      addTearDown(controller.dispose);
      await controller.load(catalogItem('a', duration: 221));
      await Future<void>.delayed(Duration.zero);
      await controller.load(catalogItem('a', duration: 222));
      await Future<void>.delayed(Duration.zero);
      expect(durations, [221000]);
      expect(controller.onlineSearchMissed, isTrue);
    },
  );

  for (final source in ['catalog', 'http', 'local']) {
    test('late known duration retries a miss exactly once ($source)', () async {
      final durations = <int>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) async {
          final duration = item.duration?.inMilliseconds ?? 0;
          durations.add(duration);
          return duration > 0 ? '[00:01]Matched recording' : '';
        },
        saveOnlineLyrics: (_, _) async => fail('Automatic retry never writes'),
      );
      addTearDown(controller.dispose);
      final initial = source == 'catalog'
          ? catalogItem('a', duration: 0)
          : MediaItem(
              id: 'a',
              title: 'Song',
              artist: 'Artist',
              extras: {
                'source': source == 'http'
                    ? 'https://example.test/a.mp3'
                    : '/music/a.flac',
              },
            );
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0]);
      final known = initial.copyWith(duration: const Duration(seconds: 221));
      await controller.load(known);
      await controller.load(known);
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0, 221000]);
      expect(controller.lyrics.lines.single.text, 'Matched recording');
      await controller.load(
        known.copyWith(duration: const Duration(seconds: 222)),
      );
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0, 221000]);
    });
  }

  test(
    'duration received during an unknown-duration search retries after its miss',
    () async {
      final first = Completer<String>();
      final durations = <int>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) {
          durations.add(item.duration?.inMilliseconds ?? 0);
          return durations.length == 1
              ? first.future
              : Future.value('[00:01]Known');
        },
      );
      addTearDown(controller.dispose);
      final initial = catalogItem('a', duration: 0);
      await controller.load(initial);
      await Future<void>.delayed(Duration.zero);
      await controller.load(
        initial.copyWith(duration: const Duration(seconds: 221)),
      );
      expect(durations, [0]);
      first.complete('');
      await Future<void>.delayed(Duration.zero);
      expect(durations, [0, 221000]);
      expect(controller.lyrics.lines.single.text, 'Known');
    },
  );

  test(
    'duration retry failure and rebuilt catalog metadata cannot create a loop',
    () async {
      final durations = <int>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        fetchOnlineLyrics: (item) async {
          durations.add(item.duration?.inMilliseconds ?? 0);
          throw StateError('Provider unavailable');
        },
      );
      addTearDown(controller.dispose);
      await controller.load(catalogItem('a', duration: 0));
      await Future<void>.delayed(Duration.zero);
      await controller.load(catalogItem('a', duration: 221));
      await Future<void>.delayed(Duration.zero);
      for (final duration in [222, 223, 221]) {
        await controller.load(catalogItem('a', duration: duration));
        await Future<void>.delayed(Duration.zero);
      }
      expect(durations, [0, 221000]);
      expect(controller.onlineSearchFailed, isTrue);
    },
  );

  test('clearing lyrics manually supersedes an outstanding lookup', () async {
    final online = Completer<String>();
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => const {},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (_) => online.future,
      saveOnlineLyrics: (_, _) async {},
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await controller.saveEditedLyrics('');
    online.complete('[00:01]Provider version');
    await Future<void>.delayed(Duration.zero);
    expect(controller.lyrics.isEmpty, isTrue);
    expect(controller.searchingOnline, isFalse);
  });

  test('failed manual save leaves pending online result usable', () async {
    final online = Completer<String>();
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => const {},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (_) => online.future,
      saveOnlineLyrics: (_, _) async => throw StateError('Read only'),
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      controller.saveEditedLyrics('[00:01]Correction'),
      throwsStateError,
    );
    online.complete('[00:01]Provider version');
    await Future<void>.delayed(Duration.zero);
    expect(controller.lyrics.lines.single.text, 'Provider version');
    expect(controller.searchingOnline, isFalse);
  });

  for (final missing in [
    (title: '', artist: 'Artist'),
    (title: 'Song', artist: ''),
    (title: 'Unknown title', artist: 'Artist'),
    (title: 'Song', artist: 'Unknown artist'),
    (title: 'Song', artist: 'Artista desconocido'),
  ]) {
    test('placeholder identity never searches $missing', () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        fetchOnlineLyrics: (_) async {
          calls++;
          return '';
        },
      );
      addTearDown(controller.dispose);
      await controller.load(
        MediaItem(
          id: 'http',
          title: missing.title,
          artist: missing.artist,
          extras: const {'source': 'https://example.test/song.mp3'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.searchOnline();
      expect(controller.canSearchOnline, isFalse);
      expect(calls, 0);
    });
  }

  test(
    'successful manual edit supersedes an outstanding automatic lookup',
    () async {
      final online = Completer<String>();
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => const {},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) => online.future,
        saveOnlineLyrics: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await controller.load(
        MediaItem(
          id: 'local',
          title: 'Song',
          artist: 'Artist',
          extras: const {'source': '/music/song.flac'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await controller.saveEditedLyrics('[00:01]My correction');
      online.complete('[00:01]Provider version');
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'My correction');
      expect(controller.searchingOnline, isFalse);
    },
  );

  for (final available in [true, false]) {
    test(
      'manual retry wins while availability check waits ($available)',
      () async {
        final availability = Completer<bool>();
        var calls = 0;
        final controller = PlayerMetadataController(
          onlineAvailable: () => availability.future,
          parseLyrics: (raw) async => LyricsParser.parse(raw),
          fetchOnlineLyrics: (_) async {
            calls++;
            return '';
          },
        );
        addTearDown(controller.dispose);
        await controller.load(catalogItem('a'));
        await controller.searchOnline();
        availability.complete(available);
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        expect(controller.onlineDeferredOffline, isFalse);
        expect(controller.onlineSearchMissed, isTrue);
      },
    );
  }

  for (final unavailable in [false, true]) {
    test(
      'native lyrics lookup reports the correct state (unavailable: $unavailable)',
      () async {
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getLyricsLRCWithSource');
          calls++;
          if (unavailable) throw PlatformException(code: 'NATIVE_ERROR');
          return '{"lyrics":"","source":"","sync_type":"","instrumental":false}';
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final controller = PlayerMetadataController(
          automaticOnlineSearch: false,
        );
        addTearDown(controller.dispose);
        await controller.load(catalogItem('missing'));
        await controller.searchOnline();

        expect(calls, 1);
        expect(controller.lyrics.isEmpty, isTrue);
        expect(controller.onlineSearchMissed, !unavailable);
        expect(controller.onlineSearchFailed, unavailable);
      },
    );
  }

  const spotifyId = '0123456789abcdefghijkl';
  for (final (provider, id, expectedId) in [
    ('spotify', spotifyId, spotifyId),
    ('spotify', 'spotify:$spotifyId', spotifyId),
    ('deezer', '42', 'deezer:42'),
    ('deezer', 'deezer:42', 'deezer:42'),
    ('Deezer', ' DEEZER:42 ', 'deezer:42'),
    ('unknown', 'deezer:42', 'deezer:42'),
    ('unknown', '42', ''),
    ('deezer', 'deezer:invalid', ''),
  ]) {
    test(
      'native online request preserves duration and $provider identity ($id)',
      () async {
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        const channel = MethodChannel('com.zarz.mornye/backend');
        final requests = <Map<dynamic, dynamic>>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getLyricsLRCWithSource');
          requests.add(call.arguments as Map);
          return {
            'lyrics': requests.last['spotify_id'] == expectedId
                ? '[00:01]Native'
                : '',
          };
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final controller = PlayerMetadataController(
          onlineAvailable: () async => true,
          parseLyrics: (raw) async => LyricsParser.parse(raw),
        );
        addTearDown(controller.dispose);
        await controller.load(
          catalogItem(id, provider: provider, resolvedSource: '/tmp/audio.m4a'),
        );
        for (var i = 0; i < 10 && controller.lyrics.isEmpty; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(requests, hasLength(1));
        expect(requests.single['spotify_id'], expectedId);
        expect(requests.single['duration_ms'], 183000);
        expect(requests.single['file_path'], '');
        expect(controller.lyrics.lines.single.text, 'Native');
      },
    );
  }

  test(
    'provider error is not a miss and only manual retry searches again',
    () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async {
          if (++calls == 1) throw StateError('Provider unavailable');
          return '[00:01]Recovered';
        },
        saveOnlineLyrics: (_, _) async => fail('Catalog must never be written'),
      );
      addTearDown(controller.dispose);
      final item = catalogItem('a');
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(controller.onlineSearchFailed, isTrue);
      expect(controller.onlineSearchMissed, isFalse);
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      await controller.searchOnline();
      expect(calls, 2);
      expect(controller.onlineSearchFailed, isFalse);
      expect(controller.lyrics.lines.single.text, 'Recovered');
    },
  );

  test(
    'offline defers until connectivity returns once and stops on disposal',
    () async {
      final changes = StreamController<bool>.broadcast();
      addTearDown(changes.close);
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => false,
        onlineChanges: changes.stream,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async {
          calls++;
          return '';
        },
      );
      await controller.load(catalogItem('a'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
      expect(controller.onlineDeferredOffline, isTrue);
      changes.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      expect(controller.onlineDeferredOffline, isFalse);
      changes.add(false);
      changes.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      controller.dispose();
      changes.add(true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );

  test('disposal during automatic parsing never publishes or writes', () async {
    final parse = Completer<ParsedLyrics>();
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      parseLyrics: (_) => parse.future,
      fetchOnlineLyrics: (_) async => '[00:01]Stale',
      saveOnlineLyrics: (_, _) async => fail('Must never write'),
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    await controller.load(catalogItem('a'));
    await Future<void>.delayed(Duration.zero);
    controller.dispose();
    final before = notifications;
    parse.complete(LyricsParser.parse('[00:01]Stale'));
    await Future<void>.delayed(Duration.zero);
    expect(notifications, before);
    expect(controller.lyrics.isEmpty, isTrue);
  });

  test(
    'catalog automatically fetches once without probing or writing audio',
    () async {
      final requests = <MediaItem>[];
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => fail('Catalog identity is not a file'),
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (item) async {
          requests.add(item);
          return '[00:01]Found';
        },
        saveOnlineLyrics: (_, _) async =>
            fail('Temporary audio must not be written'),
      );
      addTearDown(controller.dispose);
      final item = catalogItem('recording');
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'Found');
      await controller.load(item);
      await controller.load(
        item.copyWith(
          extras: {...item.extras!, 'resolvedSource': '/tmp/temporary.m4a'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(requests, hasLength(1));
      expect(requests.single.duration, const Duration(seconds: 183));
      expect(controller.onlineLyricsSaveFailed, isFalse);
    },
  );

  test('embedded lyrics win without an online request', () async {
    final controller = PlayerMetadataController(
      onlineAvailable: () async => true,
      readMetadata: (_) async => {'lyrics': '[00:01]Embedded'},
      parseLyrics: (raw) async => LyricsParser.parse(raw),
      fetchOnlineLyrics: (_) async => fail('Embedded lyrics must win'),
    );
    addTearDown(controller.dispose);
    await controller.load(
      MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      ),
    );
    expect(controller.lyrics.lines.single.text, 'Embedded');
  });

  test(
    'local absence fetches once without writing or repeating on metadata events',
    () async {
      var calls = 0;
      final events = SourceMetadataEvents();
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        metadataEvents: events,
        readMetadata: (_) async => const {'format': 'FLAC'},
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async {
          calls++;
          return '[00:01]Fetched';
        },
        saveOnlineLyrics: (_, _) async =>
            fail('Automatic display must not write tags'),
      );
      addTearDown(controller.dispose);
      final item = MediaItem(
        id: 'local',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': '/music/song.flac'},
      );
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      expect(controller.lyrics.lines.single.text, 'Fetched');
      expect(controller.metadata!['format'], 'FLAC');
      await events.publish('/music/song.flac');
      await controller.load(item);
      expect(controller.lyrics.lines.single.text, 'Fetched');
      expect(calls, 1);
    },
  );

  test(
    'HTTP automatic lyrics survive repeated load without writing stream',
    () async {
      var calls = 0;
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        readMetadata: (_) async => fail('HTTP is not a local file'),
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        fetchOnlineLyrics: (_) async {
          calls++;
          return '[00:01]Stream';
        },
        saveOnlineLyrics: (_, _) async => fail('Streams are not writable'),
      );
      addTearDown(controller.dispose);
      final item = MediaItem(
        id: 'http',
        title: 'Song',
        artist: 'Artist',
        extras: const {'source': 'https://example.test/song.mp3'},
      );
      await controller.load(item);
      await Future<void>.delayed(Duration.zero);
      await controller.load(item);
      expect(controller.lyrics.lines.single.text, 'Stream');
      expect(calls, 1);
      expect(controller.onlineLyricsSaveFailed, isFalse);
    },
  );

  test(
    'late native Deezer result cannot overwrite a later catalog item',
    () async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final first = Completer<Map<String, String>>();
      final requests = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getLyricsLRCWithSource');
        final id = (call.arguments as Map)['spotify_id'] as String;
        requests.add(id);
        return id == 'deezer:42' ? first.future : {'lyrics': '[00:01]Second'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final controller = PlayerMetadataController(
        onlineAvailable: () async => true,
        parseLyrics: (raw) async => LyricsParser.parse(raw),
        saveOnlineLyrics: (_, _) async => fail('Catalog is not writable'),
      );
      addTearDown(controller.dispose);
      await controller.load(catalogItem('42', provider: 'deezer'));
      await Future<void>.delayed(Duration.zero);
      await controller.load(catalogItem('43', provider: 'deezer'));
      await Future<void>.delayed(Duration.zero);
      first.complete({'lyrics': '[00:01]Stale'});
      await Future<void>.delayed(Duration.zero);
      expect(requests, ['deezer:42', 'deezer:43']);
      expect(controller.lyrics.lines.single.text, 'Second');
    },
  );
}
