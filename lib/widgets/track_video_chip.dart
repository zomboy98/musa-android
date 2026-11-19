import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';

/// Height of the video pill; its hit area is [trackVideoChipTouchHeight].
const double trackVideoChipHeight = 40;
const double trackVideoChipTouchHeight = 44;

/// A translucent dark pill with a play box and the video label. It keeps the
/// same size in every state: loading and active only change its look.
class TrackVideoChip extends StatelessWidget {
  const TrackVideoChip({
    super.key,
    required this.onPressed,
    this.active = false,
    this.loading = false,
    this.colorScheme,
  });

  final VoidCallback? onPressed;
  final bool active;
  final bool loading;
  final ColorScheme? colorScheme;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label = l10n.qualityVideoLabel;
    final semantic = active ? l10n.qualityVideoBackToAudio : label;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.2);
    final shape = StadiumBorder(
      side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
    );
    return Semantics(
      button: true,
      selected: active,
      label: semantic,
      value: loading ? l10n.qualityPickerSwitching : null,
      excludeSemantics: true,
      child: Tooltip(
        message: semantic,
        excludeFromSemantics: true,
        child: Opacity(
          opacity: loading ? 0.7 : 1,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: onPressed,
              child: SizedBox(
                height: trackVideoChipTouchHeight,
                child: Center(
                  widthFactor: 1,
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      color: Colors.black.withValues(alpha: 0.58),
                      shape: shape,
                    ),
                    child: SizedBox(
                      height: trackVideoChipHeight,
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(
                          start: 8,
                          end: 14,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DecoratedBox(
                              decoration: BoxDecoration(
                                color: active
                                    ? Colors.white
                                    : Colors.white.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: SizedBox.square(
                                dimension: 26,
                                child: Icon(
                                  active
                                      ? Icons.graphic_eq_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 20,
                                  color: active ? Colors.black : Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              label,
                              maxLines: 1,
                              softWrap: false,
                              textScaler: scaler,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
