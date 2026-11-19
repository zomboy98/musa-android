import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/music_player_provider.dart';
import '../../providers/settings_provider.dart';
import '../../services/jam/jam_app_controller.dart';
import '../../services/jam/jam_library_inventory.dart';

final jamControllerFactoryProvider = Provider<JamAppController Function()>(
  (ref) => JamAppController.new,
);

final jamHostPlaybackInitializerProvider =
    Provider<Future<void> Function(JamAppController)>((ref) {
      return (controller) => initializeJamLibraryPlayback(
        controller: controller,
        runtime: ref.read(musicPlayerRuntimeProvider),
        includeLocalLibrary: () =>
            ref.read(settingsProvider).localLibraryEnabled,
      );
    });

/// Owns the ephemeral session only while this settings page is visible.
class JamSettingsPage extends ConsumerStatefulWidget {
  const JamSettingsPage({super.key, required this.tabActive});

  final ValueListenable<bool> tabActive;

  @override
  ConsumerState<JamSettingsPage> createState() => _JamSettingsPageState();
}

class _JamSettingsPageState extends ConsumerState<JamSettingsPage> {
  late final JamAppController _controller = ref.read(
    jamControllerFactoryProvider,
  )();
  String? _connectionError;
  int? _connectionErrorGeneration;

  void _setConnectionError(String? message) {
    setState(() {
      _connectionError = message;
      _connectionErrorGeneration = _controller.sessionGeneration;
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.prepareHostPlayback = ref.read(
      jamHostPlaybackInitializerProvider,
    );
    widget.tabActive.addListener(_onTabChange);
  }

  void _onTabChange() {
    if (!widget.tabActive.value && _controller.phase != JamAppPhase.idle) {
      _controller.close();
    }
  }

  @override
  void dispose() {
    widget.tabActive.removeListener(_onTabChange);
    _controller.dispose();
    super.dispose();
  }

  void _connectPlayer() {
    final runtime = ref.read(musicPlayerRuntimeProvider);
    if (runtime.handler == null) {
      _setConnectionError(context.l10n.jamPlayerNotInitialized);
      return;
    }
    try {
      final includeLocalLibrary = ref
          .read(settingsProvider)
          .localLibraryEnabled;
      attachJamLibraryPlayback(
        controller: _controller,
        runtime: runtime,
        includeLocalLibrary: () => includeLocalLibrary,
      );
      _setConnectionError(null);
    } catch (_) {
      _setConnectionError(context.l10n.jamPlayerConnectFailed);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.jamExperimentalTitle)),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(context.l10n.jamExperimentalNotice),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  if (_controller.phase != JamAppPhase.hosting) {
                    return const SizedBox.shrink();
                  }
                  final state = _controller.playbackState;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: switch (state) {
                          JamPlaybackState.idle => _connectPlayer,
                          JamPlaybackState.error ||
                          JamPlaybackState.partial => () {
                            if (!_controller.retryHostPlayback()) {
                              _setConnectionError(
                                context.l10n.jamRetrySyncFailed,
                              );
                            } else {
                              _setConnectionError(null);
                            }
                          },
                          _ => null,
                        },
                        icon: const Icon(Icons.link),
                        label: Text(switch (state) {
                          JamPlaybackState.idle => context.l10n.jamConnectQueue,
                          JamPlaybackState.pending => context.l10n.jamSyncing,
                          JamPlaybackState.synchronized =>
                            context.l10n.jamPlayerConnected,
                          JamPlaybackState.partial =>
                            context.l10n.jamMissingSongsRetry,
                          JamPlaybackState.error => context.l10n.jamRetrySync,
                        }),
                      ),
                      if (_connectionError != null &&
                          _connectionErrorGeneration ==
                              _controller.sessionGeneration)
                        Text(
                          _connectionError!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              context.l10n.jamDisabledNotice,
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    ),
  );
}
