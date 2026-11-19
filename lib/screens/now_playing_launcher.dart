import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_commands.dart';

bool _nowPlayingOpening = false;

void openNowPlayingScreen() {
  if (isDesktopPlatform) {
    openDesktopNowPlaying();
    return;
  }
  final navigator = AppNavigationService.rootNavigatorKey.currentState;
  if (navigator == null || _nowPlayingOpening) return;
  _nowPlayingOpening = true;
  navigator
      .push<void>(NowPlayingRoute(child: const NowPlayingScreen()))
      .whenComplete(() => _nowPlayingOpening = false);
}
