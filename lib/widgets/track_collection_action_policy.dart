enum QualityVariantMenuAction { downloadAnotherQuality, playLocal }

/// Resolves the quality-variant entry shown in a remote track's options menu.
///
/// When tapping an already-local track is repurposed to download another
/// quality, the menu becomes the escape hatch for playing that local copy.
QualityVariantMenuAction? resolveQualityVariantMenuAction({
  required bool allowQualityVariants,
  required bool hasLocalPlaybackCandidate,
}) {
  if (hasLocalPlaybackCandidate) return QualityVariantMenuAction.playLocal;
  return allowQualityVariants
      ? QualityVariantMenuAction.downloadAnotherQuality
      : null;
}
