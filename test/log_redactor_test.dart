import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/diagnostics/log_redactor.dart';

void main() {
  String line(String value) => LogRedactor.redactLine(value);

  test('keeps ordinary lines untouched', () {
    const text = '[12:00:01.123] [ERROR] [Download] Failed to fetch item 12345';
    expect(line(text), text);
  });

  group('credentials', () {
    test('Authorization, Bearer and Cookie headers', () {
      expect(
        line('Authorization: Bearer abc.def-ghi_jkl123'),
        'Authorization: [redactado]',
      );
      expect(
        line('sent Bearer FAKE_TOKEN_VALUE_1 ok'),
        'sent Bearer [redactado] ok',
      );
      expect(line('Cookie: sp_dc=AQFAKEVALUE; other=1'), 'Cookie: [redactado]');
      expect(line('Set-Cookie: sid=FAKE123'), 'Set-Cookie: [redactado]');
      expect(line('x-api-key: FAKEKEY999'), 'x-api-key: [redactado]');
    });

    test('key=value pairs and JSON fields', () {
      expect(line('ADMIN_KEY=fake-admin-key-1'), 'ADMIN_KEY=[redactado]');
      expect(line('sp_dc=AQDfakecookie'), 'sp_dc=[redactado]');
      expect(
        line('{"access_token": "fake-access", "name": "ok"}'),
        '{"access_token": "[redactado]", "name": "ok"}',
      );
      expect(line("password: 'hunter2'"), "password: '[redactado]'");
      expect(
        line('refresh_token=fake-refresh&x=1'),
        'refresh_token=[redactado]&x=1',
      );
    });

    test('JWT shaped values', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmYWtlIn0.c2lnbmF0dXJl';
      final out = line('value $jwt end');
      expect(out, isNot(contains('eyJ')));
      expect(out, contains('[redactado]'));
    });

    test('long secret looking words, with digits and letters', () {
      const secret = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8';
      expect(line('id $secret fin'), 'id [redactado] fin');
      expect(
        line('ClassNameWithoutDigitsButVeryDescriptiveIndeed'),
        'ClassNameWithoutDigitsButVeryDescriptiveIndeed',
      );
    });
  });

  group('addresses and paths', () {
    test('URLs lose query, fragment and credentials', () {
      expect(
        line(
          'GET https://cdn.example.com/a/b.flac?X-Amz-Signature=abc123&Expires=9#frag failed',
        ),
        'GET https://cdn.example.com/a/b.flac?[redactado] failed',
      );
      expect(
        line('open https://user:pass@host.example/path now'),
        'open https://host.example/path now',
      );
      expect(
        line('see https://example.org/page.'),
        'see https://example.org/page.',
      );
    });

    test('plugin codes', () {
      expect(
        line('GET https://musa-api.heyshin.app/v1/code/ABC-XYZ'),
        'GET https://musa-api.heyshin.app/v1/code/[redactado]',
      );
      expect(line('code=ABCDEF1'), 'code=[redactado]');
      expect(line('codigo: ABC-D3F'), 'codigo: [redactado]');
      expect(line('pegaste QWE-RT7 ayer'), 'pegaste [codigo] ayer');
    });

    test('emails and user paths', () {
      expect(line('user alex.perez@example.com wrote'), 'user [correo] wrote');
      expect(
        line(r'read C:\Users\Alex Perez\Music\a.flac'),
        r'read C:\Users\[usuario]\Music\a.flac',
      );
      expect(
        line(r'read C:\Users\alex\Music\a.flac'),
        r'read C:\Users\[usuario]\Music\a.flac',
      );
      expect(line('open /home/alex/x.txt'), 'open /home/[usuario]/x.txt');
      expect(line('open /Users/alex/x.txt'), 'open /Users/[usuario]/x.txt');
      expect(
        line('file /storage/emulated/0/Music/Artista - Cancion.flac gone'),
        'file [ruta] gone',
      );
    });
  });

  group('limits', () {
    test('keeps only the latest 300 lines', () {
      final text = [for (var i = 0; i < 500; i++) 'linea $i'].join('\n');
      final lines = LogRedactor.redact(text).split('\n');
      expect(lines.length, 300);
      expect(lines.first, 'linea 200');
      expect(lines.last, 'linea 499');
    });

    test('caps the size at 20 KB keeping the newest lines', () {
      final text = [
        for (var i = 0; i < 300; i++) 'n$i ${'palabra ' * 25}',
      ].join('\n');
      final out = LogRedactor.redact(text);
      expect(utf8.encode(out).length, lessThanOrEqualTo(LogRedactor.maxBytes));
      expect(out.split('\n').last.startsWith('n299 '), isTrue);
      expect(out.split('\n').any((l) => l.startsWith('n0 ')), isFalse);
    });

    test('long lines are shortened and multibyte text is counted in bytes', () {
      final out = LogRedactor.redact('é' * 2000, bytes: 500);
      expect(utf8.encode(out).length, lessThanOrEqualTo(500));
      expect(
        LogRedactor.redactLine('y' * 1000).length,
        lessThanOrEqualTo(LogRedactor.maxLineLength + 3),
      );
    });

    test('control characters are dropped', () {
      expect(line('a\u0000b\u0007c'), 'abc');
    });
  });
}
