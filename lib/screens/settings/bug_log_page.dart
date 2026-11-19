import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/report/report_page.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:share_plus/share_plus.dart';

class BugLogPage extends StatefulWidget {
  const BugLogPage({super.key, this.bugLog});
  final BugLog? bugLog;
  @override
  State<BugLogPage> createState() => _BugLogPageState();
}

class _BugLogPageState extends State<BugLogPage> {
  late final BugLog log = widget.bugLog ?? BugLog.instance;
  @override
  void initState() {
    super.initState();
    log.addListener(_refresh);
  }

  @override
  void dispose() {
    log.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _addNote() async {
    var draft = '';
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(context.l10n.bugLogDescribeAProblem),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(context.l10n.bugLogOptionalDoNotIncludeSensitiveInformation),
            TextField(
              onChanged: (value) => draft = value,
              maxLength: BugLog.maxNoteLength,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: context.l10n.bugLogWhatDidYouDoAndWhat,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.dialogCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, draft),
            child: Text(context.l10n.dialogSave),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    try {
      await log.addNote(text);
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.l10n.bugLogCouldNotSaveTheNote)),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.bugLogBugLog)),
      body: FutureBuilder<List<Map<String, String>>>(
        future: log.entries(),
        builder: (context, snapshot) {
          final entries = snapshot.data ?? [];
          final report = const JsonEncoder.withIndent('  ').convert(entries);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(context.l10n.bugLogStoredOnThisDeviceUpTo),
              if (log.persistenceFailed)
                Text(context.l10n.bugLogCouldNotSaveTheLogEvents),
              Wrap(
                spacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: () => _addNote(),
                    icon: const Icon(Icons.note_add_outlined),
                    label: Text(context.l10n.bugLogAddNote),
                  ),
                  TextButton.icon(
                    onPressed: () => ReportPage.open(
                      context,
                      initialText: entries.isEmpty
                          ? ''
                          : '${entries.last['category']} · ${entries.last['type']}',
                    ),
                    icon: const Icon(Icons.rate_review_outlined),
                    label: Text(context.l10n.feedbackReportThisError),
                  ),
                  TextButton.icon(
                    onPressed: entries.isEmpty
                        ? null
                        : () async {
                            try {
                              await Clipboard.setData(
                                ClipboardData(text: report),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(context.l10n.bugLogCopied),
                                  ),
                                );
                              }
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      context.l10n.bugLogCouldNotCopyTheLog,
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.copy),
                    label: Text(context.l10n.bugLogCopy),
                  ),
                  TextButton.icon(
                    onPressed: entries.isEmpty
                        ? null
                        : () async {
                            try {
                              await SharePlus.instance.share(
                                ShareParams(text: report),
                              );
                            } catch (_) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      context.l10n.bugLogCouldNotShareTheLog,
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                    icon: const Icon(Icons.share),
                    label: Text(context.l10n.bugLogShare),
                  ),
                  TextButton.icon(
                    onPressed:
                        entries.isEmpty && snapshot.error is! FormatException
                        ? null
                        : () async {
                            final confirm = await showAppConfirmDialog(
                              context,
                              title: context.l10n.bugLogClearBugLog,
                              message: snapshot.error is FormatException
                                  ? context
                                        .l10n
                                        .bugLogTheLogIsUnreadableItsStored
                                  : null,
                              confirmLabel: context.l10n.dialogClear,
                              cancelIsDefault: true,
                              destructive: true,
                            );
                            if (confirm) {
                              try {
                                await log.clear();
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        context.l10n.bugLogCouldNotClearTheLog,
                                      ),
                                    ),
                                  );
                                }
                              }
                            }
                          },
                    icon: const Icon(Icons.delete_outline),
                    label: Text(context.l10n.dialogClear),
                  ),
                ],
              ),
              if (snapshot.connectionState != ConnectionState.done)
                const Center(child: CircularProgressIndicator())
              else if (snapshot.hasError)
                Text(context.l10n.bugLogCouldNotLoadTheLogExisting)
              else if (entries.isEmpty)
                Text(context.l10n.bugLogNoErrorsRecordedYet)
              else
                for (final entry in entries.reversed)
                  ListTile(
                    title: Text(
                      '${entry['category']} · ${entry['type']}${entry['tag'] != null ? ' · ${entry['tag']}' : ''}',
                    ),
                    subtitle: Text(
                      '${entry['time'] ?? ''}${entry['frames']?.isNotEmpty == true ? '\n${entry['frames']}' : ''}${entry['count'] != null ? '\n${entry['count']} events omitted' : ''}${entry['note']?.isNotEmpty == true ? '\n${entry['note']}' : ''}',
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}
