import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/services/download_queue_pacing.dart';

void main() {
  late DateTime now;
  late DownloadQueuePacing pacing;
  setUp(() {
    now = DateTime.utc(2026, 11, 16, 12);
    pacing = DownloadQueuePacing(clock: () => now);
  });

  test('no espera antes del primer item', () {
    expect(pacing.remainingGap('tidal-web'), Duration.zero);
  });

  test('Deezer espera 2 s y el resto 4 s tras terminar un item', () {
    pacing.markFinished();
    expect(pacing.remainingGap('deezer'), const Duration(seconds: 2));
    expect(pacing.remainingGap('tidal-web'), const Duration(seconds: 4));
    now = now.add(const Duration(seconds: 3));
    expect(pacing.remainingGap('deezer'), Duration.zero);
    expect(pacing.remainingGap('tidal-web'), const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    expect(pacing.remainingGap('tidal-web'), Duration.zero);
  });

  test('tres fallos seguidos del mismo proveedor piden pausa', () {
    expect(pacing.recordFailure('tidal-web', DownloadErrorType.timeout), false);
    expect(
      pacing.recordFailure('tidal-web', DownloadErrorType.providerError),
      false,
    );
    expect(
      pacing.recordFailure('tidal-web', DownloadErrorType.rateLimit),
      true,
    );
    expect(pacing.recordFailure('tidal-web', DownloadErrorType.timeout), false);
  });

  test('un exito o un fallo ajeno reinicia la racha', () {
    pacing.recordFailure('a', DownloadErrorType.timeout);
    pacing.recordFailure('a', DownloadErrorType.timeout);
    pacing.recordSuccess();
    expect(pacing.recordFailure('a', DownloadErrorType.timeout), false);
    pacing.recordFailure('a', DownloadErrorType.timeout);
    pacing.recordFailure('a', DownloadErrorType.notFound);
    expect(pacing.recordFailure('a', DownloadErrorType.timeout), false);
  });

  test('cambiar de proveedor reinicia la racha', () {
    pacing.recordFailure('a', DownloadErrorType.timeout);
    pacing.recordFailure('a', DownloadErrorType.timeout);
    expect(pacing.recordFailure('b', DownloadErrorType.timeout), false);
  });
}
