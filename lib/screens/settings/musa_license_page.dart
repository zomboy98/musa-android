import 'package:flutter/material.dart';
import 'package:mornye/constants/app_info.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:url_launcher/url_launcher.dart';

Future<String> musaLicenseText(
  Future<String> Function(String key) load,
) async {
  return '${AppInfo.copyright}\n${AppInfo.originalCopyright}\n\n'
      '${AppInfo.license}\n\n'
      '${await load('LICENSE')}\n\n'
      '${await load('COPYING')}';
}

String musaLicenseLegalese(BuildContext context) {
  final l10n = context.l10n;
  return '${AppInfo.copyright}\n${AppInfo.originalCopyright}\n\n'
      '${l10n.licenseMusaAttribution}\n\n'
      '${l10n.licenseSourceCodeRight}\n'
      '${l10n.licenseSourceCodeTitle}: ${AppInfo.sourceCodeUrl}';
}

class MusaSourceCodeLink extends StatelessWidget {
  const MusaSourceCodeLink({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      icon: const Icon(Icons.code),
      label: Text(context.l10n.licenseSourceCodeTitle),
      onPressed: () => launchUrl(
        Uri.parse(AppInfo.sourceCodeUrl),
        mode: LaunchMode.externalApplication,
      ),
    );
  }
}

void showMusaLicensePage(BuildContext context) {
  showLicensePage(
    context: context,
    applicationName: AppInfo.appName,
    applicationVersion: AppInfo.displayVersion,
    applicationIcon: const MusaSourceCodeLink(),
    applicationLegalese: musaLicenseLegalese(context),
  );
}
