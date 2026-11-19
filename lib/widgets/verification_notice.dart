import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/verification_contract.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/widgets/app_content_card.dart';
import 'package:mornye/widgets/app_icon.dart';

enum _VerificationNoticeStage { idle, verifying, resumed, expired, failed }

class VerificationNotice extends ConsumerStatefulWidget {
  const VerificationNotice({
    super.key,
    required this.verification,
    required this.onRetry,
  });

  final VerificationRequired verification;
  final VoidCallback onRetry;

  @override
  ConsumerState<VerificationNotice> createState() => _VerificationNoticeState();
}

class _VerificationNoticeState extends ConsumerState<VerificationNotice> {
  _VerificationNoticeStage _stage = _VerificationNoticeStage.idle;
  Future<VerificationOutcome>? _pending;

  Future<void> _start() async {
    if (_pending != null) return;
    setState(() => _stage = _VerificationNoticeStage.verifying);
    final pending = _verify();
    _pending = pending;
    final outcome = await pending;
    _pending = null;
    if (!mounted) return;
    setState(() {
      _stage = switch (outcome) {
        VerificationOutcome.resumed => _VerificationNoticeStage.resumed,
        VerificationOutcome.cancelled => _VerificationNoticeStage.idle,
        VerificationOutcome.expired => _VerificationNoticeStage.expired,
        VerificationOutcome.failed => _VerificationNoticeStage.failed,
      };
    });
  }

  Future<VerificationOutcome> _verify() async {
    try {
      return await ref
          .read(verificationFacadeProvider)
          .verifyAndResume(widget.verification.operationId);
    } catch (_) {
      return VerificationOutcome.failed;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final working =
        _stage == _VerificationNoticeStage.verifying ||
        _stage == _VerificationNoticeStage.resumed;
    final expired = _stage == _VerificationNoticeStage.expired;
    final failed = _stage == _VerificationNoticeStage.failed;
    final foreground = colors.onSecondaryContainer;
    return AppContentCard(
      elevation: 0,
      color: colors.secondaryContainer,
      mornyeSurface: false,
      shape: RoundedRectangleBorder(borderRadius: tokens.borderRadiusCard),
      child: Padding(
        padding: EdgeInsets.all(tokens.gapLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon.adaptive(
                  Icons.verified_user_outlined,
                  color: foreground,
                ),
                SizedBox(width: tokens.gapMd),
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      expired
                          ? l10n.verificationNoticeExpired
                          : failed
                          ? l10n.verificationNoticeFailed
                          : l10n.verificationNoticeMessage(
                              widget.verification.providerName,
                            ),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: foreground),
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: tokens.gapMd),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: expired
                  ? FilledButton(
                      onPressed: widget.onRetry,
                      child: Text(l10n.dialogRetry),
                    )
                  : FilledButton(
                      onPressed: working ? null : _start,
                      child: working
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                if (_stage ==
                                    _VerificationNoticeStage.verifying) ...[
                                  const SizedBox(width: 8),
                                  Text(l10n.verificationNoticeInProgress),
                                ],
                              ],
                            )
                          : Text(l10n.verificationNoticeAction),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
