import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_pairing.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';

void main() {
  test('grants are single use, guests independent and revocable', () {
    final pairing = JamPairing();
    final firstGrant = pairing.issue();
    final first = pairing.redeem(firstGrant)!;
    final second = pairing.redeem(pairing.issue())!;
    expect(pairing.redeem(firstGrant), isNull);
    expect(pairing.authenticateGuest(first), isNotNull);
    expect(
      pairing.authenticateGuest(first),
      isNot(pairing.authenticateGuest(second)),
    );
    expect(pairing.revoke(first), isTrue);
    expect(pairing.authenticateGuest(first), isNull);
    expect(pairing.authenticateGuest(second), isNotNull);
    pairing.close();
    expect(pairing.authenticateGuest(second), isNull);
  });

  test('expiry is inclusive at boundary and lifetime is bounded', () {
    var now = DateTime.utc(2026);
    final pairing = JamPairing(now: () => now);
    final grant = pairing.issue(lifetime: const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    expect(pairing.redeem(grant), isNull);
    expect(() => pairing.issue(lifetime: Duration.zero), throwsArgumentError);
    expect(
      () => pairing.issue(lifetime: const Duration(minutes: 6)),
      throwsArgumentError,
    );
  });

  test('active guest capacity is bounded and reclaimed on revoke', () {
    final pairing = JamPairing();
    final guests = List.generate(32, (_) => pairing.redeem(pairing.issue())!);
    final rejectedGrant = pairing.issue();
    expect(pairing.redeem(rejectedGrant), isNull);
    expect(pairing.revoke(guests.first), isTrue);
    expect(pairing.redeem(rejectedGrant), isNull);
    expect(pairing.redeem(pairing.issue()), isNotNull);
  });

  test('pinned client rejects invalid endpoint and fingerprint', () async {
    expect(
      () => JamPinnedClient(Uri.parse('http://127.0.0.1:1234'), 'a' * 64),
      throwsArgumentError,
    );
    expect(
      () => JamPinnedClient(Uri.parse('https://127.0.0.1:1234'), 'bad'),
      throwsArgumentError,
    );
    final client = JamPinnedClient(
      Uri.parse('https://127.0.0.1:1234'),
      'a' * 64,
    );
    await expectLater(client.send('GET', '//attacker'), throwsArgumentError);
    client.close();
  });
}
