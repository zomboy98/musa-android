import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/bluetooth_start_guard.dart';
import 'package:mornye/services/music_playback_deck.dart';
import 'package:mornye/services/playback_ramp.dart';

class _RoutePlatform implements BluetoothStartPlatform {
  _RoutePlatform(this.bluetooth);

  final bool bluetooth;

  @override
  Future<bool> routedToBluetooth() async => bluetooth;

  @override
  Future<bool> playSilence(Duration length) async => true;

  @override
  Future<bool> setKeepAlive(bool enabled, Duration limit) async => true;
}

BluetoothStartGuard _guard({required bool bluetooth, bool enabled = true}) =>
    BluetoothStartGuard(
      platform: _RoutePlatform(bluetooth),
      silence: const Duration(milliseconds: 5),
      keepAliveDelay: const Duration(seconds: 30),
    )..enabled = enabled;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('rampa', () {
    test(
      'la entrada de arranque dura 25 ms en 5 pasos y es monotona',
      () async {
        expect(PlaybackRamp.startFadeIn, const Duration(milliseconds: 25));
        expect(PlaybackRamp.startFadeSteps, 5);
        expect(PlaybackRamp.startPoll, const Duration(milliseconds: 5));
        expect(PlaybackRamp.startLimit, const Duration(milliseconds: 1500));
        final gains = <double>[];
        final ramp = PlaybackRamp(apply: (gain) async => gains.add(gain));
        await ramp.rampInAfter(() async => true, () => 1);
        expect(gains.length, PlaybackRamp.startFadeSteps);
        expect(gains.first, greaterThan(0));
        expect(gains.last, closeTo(1, 1e-9));
        for (var i = 1; i < gains.length; i++) {
          expect(gains[i], greaterThan(gains[i - 1]));
        }
      },
    );

    test(
      'cada arranque reinicia la rampa desde cero sin heredar el nivel',
      () async {
        final gains = <double>[];
        final ramp = PlaybackRamp(apply: (gain) async => gains.add(gain));
        await ramp.rampInAfter(() async => true, () => 0.9);
        expect(gains.last, closeTo(0.9, 1e-9));
        gains.clear();
        final second = ramp.rampInAfter(() async => true, () => 0.6);
        expect(ramp.level, 0);
        await second;
        expect(gains.first, lessThan(0.6));
        expect(gains.last, closeTo(0.6, 1e-9));
      },
    );

    test(
      'en Bluetooth el fundido es largo, escalonado y espera a asentarse',
      () async {
        expect(PlaybackRamp.bluetoothFadeIn, const Duration(milliseconds: 140));
        expect(PlaybackRamp.bluetoothFadeSteps, greaterThanOrEqualTo(12));
        expect(PlaybackRamp.bluetoothSettle, const Duration(milliseconds: 80));
        expect(
          PlaybackRamp.bluetoothSettle +
              PlaybackRamp.bluetoothFadeIn -
              PlaybackRamp.startFadeIn,
          lessThanOrEqualTo(const Duration(milliseconds: 250)),
        );
        final gains = <double>[];
        final events = <String>[];
        final ramp = PlaybackRamp(
          apply: (gain) async => gains.add(gain),
          trace: events.add,
        );
        await ramp.rampInAfter(
          () async => true,
          () => 1,
          fade: const Duration(milliseconds: 28),
          fadeSteps: PlaybackRamp.bluetoothFadeSteps,
          settle: const Duration(milliseconds: 10),
        );
        expect(gains.length, PlaybackRamp.bluetoothFadeSteps);
        expect(gains.last, closeTo(1, 1e-9));
        for (var i = 1; i < gains.length; i++) {
          expect(gains[i], greaterThan(gains[i - 1]));
          expect(gains[i] - gains[i - 1], lessThan(0.2));
        }
        expect(events.any((e) => e.startsWith('ramp settled')), isTrue);
        expect(events.any((e) => e.startsWith('ramp in long start')), isTrue);
      },
    );

    test('la salida es el espejo de la entrada y no salta', () async {
      final gains = <double>[];
      final ramp = PlaybackRamp(
        apply: (gain) async => gains.add(gain),
        fadeOut: const Duration(milliseconds: 12),
      );
      await ramp.rampOut(1);
      expect(gains.last, closeTo(0, 1e-9));
      for (var i = 1; i < gains.length; i++) {
        expect(gains[i], lessThanOrEqualTo(gains[i - 1]));
        expect(gains[i - 1] - gains[i], lessThan(0.25));
      }
    });

    test('la rampa no aplica nada hasta que la posicion avanza', () async {
      final gains = <double>[];
      var polls = 0;
      final events = <String>[];
      final ramp = PlaybackRamp(
        apply: (gain) async => gains.add(gain),
        trace: events.add,
      );
      await ramp.rampInAfter(
        () async {
          polls++;
          if (polls < 4) expect(gains, isEmpty);
          return polls >= 4;
        },
        () => 0.8,
        poll: const Duration(milliseconds: 1),
      );
      expect(polls, 4);
      expect(gains.length, PlaybackRamp.startFadeSteps);
      expect(gains.last, closeTo(0.8, 1e-9));
      expect(events.any((e) => e.startsWith('first position advance')), isTrue);
      expect(ramp.active, isFalse);
    });

    test('sin avance la rampa arranca al agotar el limite', () async {
      final gains = <double>[];
      final events = <String>[];
      final ramp = PlaybackRamp(
        apply: (gain) async => gains.add(gain),
        trace: events.add,
      );
      await ramp.rampInAfter(
        () async => false,
        () => 1,
        poll: const Duration(milliseconds: 2),
        limit: const Duration(milliseconds: 20),
      );
      expect(gains.last, closeTo(1, 1e-9));
      expect(events.any((e) => e.startsWith('no position advance')), isTrue);
    });
  });

  group('deck', () {
    final calls = <String>[];
    var positionCalls = 0;
    var advanceAfter = 3;

    setUp(() {
      calls.clear();
      positionCalls = 0;
      advanceAfter = 3;
      for (final name in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(name),
          (_) async => null,
        );
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          final args = call.arguments as Map<Object?, Object?>;
          final id = args['playerId']! as String;
          if (call.method == 'create') {
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          } else if (call.method == 'setSourceUrl') {
            unawaited(
              messenger.handlePlatformMessage(
                'xyz.luan/audioplayers/events/$id',
                const StandardMethodCodec().encodeSuccessEnvelope({
                  'event': 'audio.onPrepared',
                  'value': true,
                }),
                (_) {},
              ),
            );
          } else if (call.method == 'getCurrentPosition') {
            positionCalls++;
            return positionCalls > advanceAfter ? 40 + positionCalls : 0;
          } else if (call.method == 'getDuration') {
            return 60000;
          }
          if (call.method == 'seek') {
            unawaited(
              messenger.handlePlatformMessage(
                'xyz.luan/audioplayers/events/$id',
                const StandardMethodCodec().encodeSuccessEnvelope({
                  'event': 'audio.onSeekComplete',
                  'value': true,
                }),
                (_) {},
              ),
            );
          }
          if (call.method == 'setVolume') {
            final volume = (args['volume'] as num).toStringAsFixed(2);
            calls.add('setVolume $volume');
          } else if (call.method == 'resume' ||
              call.method == 'pause' ||
              call.method == 'seek' ||
              call.method == 'stop') {
            calls.add(call.method);
          }
          return null;
        },
      );
    });

    test('el arranque es monotono y el volumen sube tras avanzar', () async {
      final deck = AudioplayersPlaybackDeck(playerId: 'start-guard');
      await deck.setFileSource('/song.flac');
      calls.clear();
      await deck.resume();
      expect(calls, ['setVolume 0.00', 'resume']);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final volumes = [
        for (final c in calls.skip(2)) double.parse(c.split(' ').last),
      ];
      expect(volumes.length, greaterThanOrEqualTo(PlaybackRamp.startFadeSteps));
      expect(positionCalls, greaterThan(advanceAfter));
      for (var i = 1; i < volumes.length; i++) {
        expect(volumes[i], greaterThanOrEqualTo(volumes[i - 1]));
      }
      expect(volumes.last, closeTo(1, 1e-9));
      expect(calls.where((c) => c == 'resume'), hasLength(1));
      expect(calls.where((c) => c == 'pause' || c == 'seek'), isEmpty);
      await deck.dispose();
    });

    test(
      'un segundo resume con el deck sonando no repite la llamada',
      () async {
        final deck = AudioplayersPlaybackDeck(playerId: 'start-twice');
        await deck.setFileSource('/song.flac');
        await deck.resume();
        calls.clear();
        await deck.resume();
        expect(calls, isEmpty);
        await deck.dispose();
      },
    );

    test('un setVolume durante la rampa no la corta a medias', () async {
      final deck = AudioplayersPlaybackDeck(playerId: 'start-race');
      await deck.setFileSource('/song.flac');
      await deck.resume();
      calls.clear();
      await deck.setVolume(0.5);
      expect(calls, isEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(calls, isNotEmpty);
      expect(calls.last, 'setVolume 0.50');
      final volumes = [for (final c in calls) double.parse(c.split(' ').last)];
      for (var i = 1; i < volumes.length; i++) {
        expect(volumes[i], greaterThanOrEqualTo(volumes[i - 1]));
      }
      await deck.dispose();
    });

    test('pausar durante la espera no sube el volumen de golpe', () async {
      advanceAfter = 1000;
      final deck = AudioplayersPlaybackDeck(playerId: 'start-pause');
      await deck.setFileSource('/song.flac');
      await deck.resume();
      calls.clear();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await deck.pause();
      final volumes = [
        for (final c in calls)
          if (c.startsWith('setVolume')) double.parse(c.split(' ').last),
      ];
      expect(volumes.where((v) => v > 0.05 && v < 0.95), isEmpty);
      expect(calls.where((c) => c == 'pause'), hasLength(1));
      await deck.dispose();
    });

    test(
      'en Bluetooth se omite el seek a 0 de una pista sin arrancar',
      () async {
        final deck = AudioplayersPlaybackDeck(
          playerId: 'bt-seek',
          bluetoothGuard: _guard(bluetooth: true),
        );
        await deck.setFileSource('/song.flac');
        calls.clear();
        await deck.seek(Duration.zero);
        expect(calls.where((c) => c == 'seek'), isEmpty);
        await deck.seek(const Duration(seconds: 5));
        expect(calls.where((c) => c == 'seek'), hasLength(1));
        await deck.seek(Duration.zero);
        expect(calls.where((c) => c == 'seek'), hasLength(2));
        await deck.dispose();
      },
    );

    test('tras sonar, el seek a 0 se emite aunque sea Bluetooth', () async {
      final deck = AudioplayersPlaybackDeck(
        playerId: 'bt-seek-played',
        bluetoothGuard: _guard(bluetooth: true),
      );
      await deck.setFileSource('/song.flac');
      await deck.resume();
      calls.clear();
      await deck.seek(Duration.zero);
      expect(calls.where((c) => c == 'seek'), hasLength(1));
      await deck.dispose();
    });

    test(
      'fuera de Bluetooth o con el ajuste apagado el seek a 0 se emite',
      () async {
        for (final guard in [
          _guard(bluetooth: false),
          _guard(bluetooth: true, enabled: false),
        ]) {
          final deck = AudioplayersPlaybackDeck(
            playerId: 'seek-${identityHashCode(guard)}',
            bluetoothGuard: guard,
          );
          await deck.setFileSource('/song.flac');
          calls.clear();
          await deck.seek(Duration.zero);
          expect(calls.where((c) => c == 'seek'), hasLength(1));
          await deck.dispose();
        }
      },
    );

    test('el fundido largo solo se usa en Bluetooth', () async {
      Future<int> steps(BluetoothStartGuard guard, String id) async {
        final deck = AudioplayersPlaybackDeck(
          playerId: id,
          bluetoothGuard: guard,
        );
        await deck.setFileSource('/song.flac');
        calls.clear();
        positionCalls = 0;
        await deck.resume();
        await Future<void>.delayed(const Duration(milliseconds: 700));
        final count = calls
            .where((c) => c.startsWith('setVolume') && c != 'setVolume 0.00')
            .length;
        await deck.dispose();
        return count;
      }

      final bluetooth = await steps(_guard(bluetooth: true), 'fade-bt');
      expect(bluetooth, greaterThanOrEqualTo(PlaybackRamp.bluetoothFadeSteps));
      final speaker = await steps(_guard(bluetooth: false), 'fade-speaker');
      expect(speaker, PlaybackRamp.startFadeSteps);
    });
  });
}
