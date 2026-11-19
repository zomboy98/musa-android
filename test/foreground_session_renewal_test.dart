import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/foreground_session_renewal.dart';

void main() {
  test(
    'does not report a result after its extension becomes disabled',
    () async {
      final pending = Completer<SessionRenewalResult?>();
      var eligible = true;
      var reports = 0;
      final runner = ForegroundSessionRenewal(
        (_) => pending.future,
        onResult: (_) => reports++,
      );
      final run = runner.run(
        enabled: true,
        providerIds: ['first'],
        canContinue: (_) => eligible,
      );
      eligible = false;
      pending.complete(
        const SessionRenewalResult(
          status: SessionRenewalStatus.refreshed,
          expiresAt: '2099-01-01T00:00:00Z',
        ),
      );
      await run;
      expect(reports, 0);
    },
  );
  test(
    'diagnostic treats malformed or expired successful responses as unknown',
    () {
      final now = DateTime.utc(2026);
      var diagnostic = const ForegroundSessionDiagnostic(checking: true);
      diagnostic = diagnostic.record(
        const SessionRenewalResult(
          status: SessionRenewalStatus.refreshed,
          expiresAt: 'bad secret-like data',
        ),
        now,
      );
      diagnostic = diagnostic.record(
        const SessionRenewalResult(
          status: SessionRenewalStatus.validUntil,
          expiresAt: '2020-01-01T00:00:00Z',
        ),
        now,
      );
      expect(diagnostic.unknown, 2);
      expect(diagnostic.counts, isEmpty);
      expect(diagnostic.earliestExpiry, isNull);
      diagnostic = diagnostic.record(
        const SessionRenewalResult(
          status: SessionRenewalStatus.refreshed,
          expiresAt: '2099-01-01T00:00:00Z',
        ),
        now,
      );
      diagnostic = diagnostic.record(
        const SessionRenewalResult(
          status: SessionRenewalStatus.validUntil,
          expiresAt: '2098-01-01T00:00:00Z',
        ),
        now,
      );
      expect(diagnostic.counts[SessionRenewalStatus.refreshed], 1);
      expect(diagnostic.counts[SessionRenewalStatus.validUntil], 1);
      expect(diagnostic.earliestExpiry, DateTime.utc(2098));
    },
  );
  test('diagnostics report only results and generic failures', () async {
    final events = <String>[];
    final runner = ForegroundSessionRenewal(
      (id) async {
        if (id == 'second') throw StateError('secret detail must not escape');
        return const SessionRenewalResult(
          status: SessionRenewalStatus.refreshed,
          expiresAt: '2099-01-01T00:00:00Z',
        );
      },
      onBegin: () => events.add('begin'),
      onResult: (result) => events.add(result?.status.name ?? 'unknown'),
      onEnd: () => events.add('end'),
    );
    await runner.run(enabled: true, providerIds: ['first', 'second']);
    expect(events, ['begin', 'refreshed', 'unknown', 'end']);
    expect(events.join(' '), isNot(contains('secret')));
  });
  test('stopping suppresses a late diagnostic response', () async {
    final pending = Completer<SessionRenewalResult?>();
    var results = 0;
    final runner = ForegroundSessionRenewal(
      (_) => pending.future,
      onResult: (_) => results++,
    );
    final run = runner.run(enabled: true, providerIds: ['first']);
    runner.stop();
    pending.complete(
      const SessionRenewalResult(
        status: SessionRenewalStatus.refreshed,
        expiresAt: '2099-01-01T00:00:00Z',
      ),
    );
    await run;
    expect(results, 0);
  });
  test(
    'disabled performs no requests; enabled checks supplied providers',
    () async {
      final calls = <String>[];
      final runner = ForegroundSessionRenewal((id) async {
        calls.add(id);
        return null;
      });
      await runner.run(enabled: false, providerIds: ['a']);
      expect(calls, isEmpty);
      await runner.run(enabled: true, providerIds: ['a', 'b']);
      expect(calls, ['a', 'b']);
    },
  );
  test(
    'overlapping runs share work and an error does not block other providers',
    () async {
      final gate = Completer<void>();
      final calls = <String>[];
      final runner = ForegroundSessionRenewal((id) async {
        calls.add(id);
        if (id == 'a') {
          await gate.future;
          throw StateError('offline');
        }
        return null;
      });
      final first = runner.run(enabled: true, providerIds: ['a', 'b']);
      final second = runner.run(enabled: true, providerIds: ['a', 'b']);
      gate.complete();
      await Future.wait([first, second]);
      expect(calls, ['a', 'b']);
    },
  );
  test('stopping during a request prevents subsequent renewals', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    var active = true;
    final runner = ForegroundSessionRenewal((id) async {
      calls.add(id);
      await gate.future;
      return null;
    });
    final future = runner.run(
      enabled: true,
      providerIds: ['a', 'b'],
      canContinue: (_) => active,
    );
    active = false;
    gate.complete();
    await future;
    expect(calls, ['a']);
  });
  test('schedules from expiry and cancels on stop without overdue loops', () {
    fakeAsync((clock) {
      final origin = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final runner = ForegroundSessionRenewal((id) async {
        calls++;
        return SessionRenewalResult(
          status: SessionRenewalStatus.validUntil,
          expiresAt: origin.add(const Duration(hours: 1)).toIso8601String(),
        );
      }, now: () => origin.add(clock.elapsed));
      runner.run(enabled: true, providerIds: ['a']);
      clock.flushMicrotasks();
      expect(calls, 1);
      clock.elapse(const Duration(minutes: 29));
      expect(calls, 1);
      clock.elapse(const Duration(minutes: 1));
      expect(calls, 2);
      clock.elapse(const Duration(hours: 2));
      expect(calls, 2);
      runner.stop();
    });
  });
  test('stop cancels scheduled check', () {
    fakeAsync((clock) {
      final origin = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final runner = ForegroundSessionRenewal((id) async {
        calls++;
        return SessionRenewalResult(
          status: SessionRenewalStatus.refreshed,
          expiresAt: origin.add(const Duration(hours: 1)).toIso8601String(),
        );
      }, now: () => origin.add(clock.elapsed));
      runner.run(enabled: true, providerIds: ['a']);
      clock.flushMicrotasks();
      runner.stop();
      clock.elapse(const Duration(hours: 1));
      expect(calls, 1);
    });
  });
  test('resume during an earlier cancelled run starts a fresh check', () async {
    final gate = Completer<void>();
    var calls = 0;
    final runner = ForegroundSessionRenewal((id) async {
      calls++;
      if (calls == 1) await gate.future;
      return null;
    });
    final first = runner.run(enabled: true, providerIds: ['a']);
    runner.stop();
    final resumed = runner.run(enabled: true, providerIds: ['a']);
    gate.complete();
    await Future.wait([first, resumed]);
    expect(calls, 2);
  });
  test('refresh reschedules and unavailable does not spin', () {
    fakeAsync((clock) {
      final origin = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final runner = ForegroundSessionRenewal((id) async {
        calls++;
        if (calls == 1) {
          return SessionRenewalResult(
            status: SessionRenewalStatus.validUntil,
            expiresAt: origin.add(const Duration(hours: 1)).toIso8601String(),
          );
        }
        if (calls == 2) {
          return SessionRenewalResult(
            status: SessionRenewalStatus.refreshed,
            expiresAt: origin.add(const Duration(hours: 2)).toIso8601String(),
          );
        }
        return const SessionRenewalResult(
          status: SessionRenewalStatus.unavailable,
        );
      }, now: () => origin.add(clock.elapsed));
      runner.run(enabled: true, providerIds: ['a']);
      clock.flushMicrotasks();
      clock.elapse(const Duration(minutes: 30));
      expect(calls, 2);
      clock.elapse(const Duration(hours: 1));
      expect(calls, 3);
      clock.elapse(const Duration(hours: 3));
      expect(calls, 3);
    });
  });
  test('checks immediately when a future deadline passes during the batch', () {
    fakeAsync((clock) {
      final origin = DateTime.utc(2026, 1, 1);
      final calls = <String>[];
      final runner = ForegroundSessionRenewal((id) async {
        calls.add(id);
        if (id == 'b' && calls.where((id) => id == 'b').length == 1) {
          await Future<void>.delayed(const Duration(seconds: 20));
        }
        if (id == 'a') {
          return SessionRenewalResult(
            status: SessionRenewalStatus.validUntil,
            expiresAt: origin
                .add(const Duration(minutes: 30, seconds: 10))
                .toIso8601String(),
          );
        }
        return const SessionRenewalResult(
          status: SessionRenewalStatus.unavailable,
        );
      }, now: () => origin.add(clock.elapsed));
      runner.run(enabled: true, providerIds: ['a', 'b']);
      clock.flushMicrotasks();
      expect(calls, ['a', 'b']);
      clock.elapse(const Duration(seconds: 20));
      expect(calls, ['a', 'b', 'a', 'b']);
      clock.elapse(const Duration(hours: 1));
      expect(calls, ['a', 'b', 'a', 'b']);
    });
  });
}
