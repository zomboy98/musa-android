import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/logger.dart';

void main() {
  test('an extension tag suffix decides the native severity', () {
    expect(nativeLogLevel('ERROR', 'Extension:amazon:INFO'), 'INFO');
    expect(nativeLogLevel('ERROR', 'Extension:amazon:debug'), 'DEBUG');
    expect(nativeLogLevel('ERROR', 'Extension:amazon:WARNING'), 'WARN');
    expect(nativeLogLevel('ERROR', 'Extension:amazon:ERROR'), 'ERROR');
    expect(nativeLogLevel('ERROR', 'Native'), 'ERROR');
    expect(nativeLogLevel('INFO', 'Extension:amazon'), 'INFO');
  });
}
