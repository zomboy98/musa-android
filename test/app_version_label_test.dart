import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/constants/app_version.dart';

void main() {
  test('public labels read as MUSA numbering', () {
    expect(musaPublicLabel, 'v0.9 beta 3');
    expect(formatPublicLabel('0.9.0-beta.1'), 'v0.9 beta 1');
    expect(formatPublicLabel('0.9.0-beta.2'), 'v0.9 beta 2');
    expect(formatPublicLabel('0.9.1'), 'v0.9.1');
    expect(formatPublicLabel('1.0.0'), 'v1.0');
    expect(formatPublicLabel('Internal'), 'Internal');
  });
}
