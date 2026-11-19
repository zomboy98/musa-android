import 'dart:async';

import 'package:mornye/widgets/cover_mimic_backdrop.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  CoverMimicScope.debugAmbientDrift = false;
  await testMain();
}
