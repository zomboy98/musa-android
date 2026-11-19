import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/services/feedback/github_issues_transport.dart';

String feedbackKindLabel(BuildContext context, FeedbackKind kind) {
  final l10n = context.l10n;
  return switch (kind) {
    FeedbackKind.bug => l10n.feedbackKindBug,
    FeedbackKind.suggestion => l10n.feedbackKindSuggestion,
    FeedbackKind.design => l10n.feedbackKindDesign,
    FeedbackKind.other => l10n.feedbackKindOther,
  };
}

String feedbackStatusLabel(BuildContext context, FeedbackStatus status) {
  final l10n = context.l10n;
  return switch (status) {
    FeedbackStatus.sent => l10n.feedbackStatusSent,
    FeedbackStatus.reviewing => l10n.feedbackStatusReviewing,
    FeedbackStatus.fixed => l10n.feedbackStatusFixed,
    FeedbackStatus.dismissed => l10n.feedbackStatusDismissed,
  };
}

String feedbackDateLabel(BuildContext context, DateTime time) {
  final material = MaterialLocalizations.of(context);
  final local = time.toLocal();
  return '${material.formatShortDate(local)} '
      '${material.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
}

Color feedbackStatusColor(ColorScheme scheme, FeedbackStatus status) =>
    switch (status) {
      FeedbackStatus.sent => scheme.onSurfaceVariant,
      FeedbackStatus.reviewing => scheme.tertiary,
      FeedbackStatus.fixed => scheme.primary,
      FeedbackStatus.dismissed => scheme.outline,
    };

String feedbackRemoteErrorMessage(BuildContext context, Object error) {
  final l10n = context.l10n;
  if (error is! FeedbackRemoteException) return l10n.feedbackErrorServer;
  return switch (error.error) {
    FeedbackRemoteError.noToken => l10n.feedbackErrorNoToken,
    FeedbackRemoteError.noNetwork => l10n.feedbackErrorNoNetwork,
    FeedbackRemoteError.timeout => l10n.feedbackErrorTimeout,
    FeedbackRemoteError.unauthorized => l10n.feedbackErrorUnauthorized,
    FeedbackRemoteError.forbidden => l10n.feedbackErrorForbidden,
    FeedbackRemoteError.notFound => l10n.feedbackErrorNotFound,
    FeedbackRemoteError.rateLimited => l10n.feedbackErrorRateLimited,
    FeedbackRemoteError.invalid => l10n.feedbackErrorInvalid,
    FeedbackRemoteError.server => l10n.feedbackErrorServer,
  };
}
