import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/feedback_page.dart';

class FeedbackEntryTile extends StatelessWidget {
  const FeedbackEntryTile({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.rate_review_outlined, color: scheme.onSurfaceVariant),
      title: Text(context.l10n.feedbackTitle),
      subtitle: Text(context.l10n.feedbackEntrySubtitle),
      trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      onTap: () => FeedbackPage.open(context),
    );
  }
}
