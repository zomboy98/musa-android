part of '../platform_bridge.dart';

class ExtensionSessionGrantEvent {
  final String extensionId;
  final bool success;
  final String? verificationId;

  const ExtensionSessionGrantEvent({
    required this.extensionId,
    required this.success,
    this.verificationId,
  });
}
