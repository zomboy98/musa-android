import 'package:flutter/foundation.dart';

class AppInfo {
  static const String version = '5.3.1';
  static const String buildNumber = '167';
  static const String engineVersion = String.fromEnvironment(
    'MUSA_ENGINE_VERSION',
    defaultValue: version,
  );

  /// The release whose What's New tour people see once after updating. Change
  /// it together with the tour's pages when a release earns a new one.
  static const String whatsNewRelease = '5.3';

  static const String gitCommit = String.fromEnvironment('GIT_COMMIT');
  static String get shortGitCommit =>
      gitCommit.length > 8 ? gitCommit.substring(0, 8) : gitCommit;

  /// The version shown to people; debug builds stay internal.
  static String get displayVersion => versionLabel();

  @visibleForTesting
  static String versionLabel({bool debug = kDebugMode}) =>
      debug ? 'Internal' : version;

  static const String appName = 'MUSA';

  /// Android checks MUSA's own channel ([AppUpdateEndpoints.latestUrl]).
  static const bool selfUpdatesEnabled = true;

  /// Releases of the original project are never offered to people.
  static const bool upstreamReleaseUpdatesEnabled = false;

  /// Upstream announcements are not part of MUSA's provider services.
  static const bool remoteAnnouncementsEnabled = false;
  static const String license = 'LGPL-3.0-only';
  static const String copyrightHolder = 'MUSA';
  static const String copyright = '© 2026 $copyrightHolder';

  /// Notice of the original work, kept as the license requires. It appears
  /// only in NOTICE and on the licenses screen.
  static const String originalCopyright = 'Copyright 2026 zarzet';

  static const String sourceCodeUrl =
      'https://musa.heyshin.app/codigo-fuente.html';

  static const String githubRepo = 'mornyeapp/Mornye';
  static const String githubUrl = 'https://github.com/$githubRepo';
  static const String feedbackRepo = 'zomboy98/MUSA';

  /// Desktop packages are published here; the source stays in [githubRepo].
  static const String desktopGithubRepo = 'mornyeapp/Mornye-Desktop';
  // The server keeps the endpoint name from before the rename.
  static const String remoteConfigApiUrl =
      'https://api.zarz.moe/v1/spotiflac-mobile/config';
}
