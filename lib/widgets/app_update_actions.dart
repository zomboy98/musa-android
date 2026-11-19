import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/widgets/app_update_dialog.dart';

/// Opens the download, verification and install flow for the known offer.
Future<void> startAppUpdateFlow(BuildContext context, WidgetRef ref) async {
  final state = ref.read(appUpdateProvider);
  final offer = state.offer;
  if (offer == null || !state.hasOffer || state.busy) return;
  await showAppUpdateDialog(
    context,
    service: ref.read(appUpdateServiceProvider),
    offer: offer,
    onStage: ref.read(appUpdateProvider.notifier).reportFlow,
  );
}
