import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/update_checker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final os in ['android', 'windows', 'macos', 'linux']) {
    test('MUSA never offers upstream updates on $os by default', () async {
      SharedPreferences.setMockInitialValues({
        'update_checker_releases_json': jsonEncode([
          {'tag_name': 'v999.0.0', 'prerelease': false},
        ]),
      });
      var requests = 0;
      final checker = UpdateChecker(
        installedVersion: '1.0.0',
        host: UpdateHost(os: os),
        client: MockClient((_) async {
          requests++;
          return http.Response('[{"tag_name":"v999.0.0"}]', 200);
        }),
      );

      expect(await checker.checkForUpdate(), isNull);
      expect(await checker.checkForUpdate(channel: 'preview'), isNull);
      expect(requests, 0);
    });
  }
}
