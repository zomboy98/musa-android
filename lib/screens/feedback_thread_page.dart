import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/screens/feedback_labels.dart';
import 'package:mornye/services/feedback/feedback_services.dart';
import 'package:mornye/services/feedback/feedback_transport.dart';

class FeedbackThreadPage extends StatefulWidget {
  const FeedbackThreadPage({
    super.key,
    required this.thread,
    required this.services,
  });

  final FeedbackThread thread;
  final FeedbackServices services;

  @override
  State<FeedbackThreadPage> createState() => _FeedbackThreadPageState();
}

class _FeedbackThreadPageState extends State<FeedbackThreadPage> {
  late FeedbackThread _thread = widget.thread;
  late final TextEditingController _version = TextEditingController(
    text: widget.thread.fixedInVersion,
  );
  final TextEditingController _comment = TextEditingController();
  bool _hasToken = false;
  bool _busy = false;

  FeedbackServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    _services.tokenStore.read().then((token) {
      if (mounted) setState(() => _hasToken = token != null);
    });
  }

  @override
  void dispose() {
    _version.dispose();
    _comment.dispose();
    super.dispose();
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _setStatus(FeedbackStatus status) async {
    final updated = await _services.store.setStatus(
      _thread,
      status,
      fixedInVersion: _version.text,
    );
    if (mounted) setState(() => _thread = updated);
  }

  Future<void> _saveVersion() async {
    if (_thread.status != FeedbackStatus.fixed) return;
    await _setStatus(FeedbackStatus.fixed);
  }

  Future<void> _addComment() async {
    if (_comment.text.trim().isEmpty) return;
    final updated = await _services.store.addComment(_thread, _comment.text);
    _comment.clear();
    if (mounted) setState(() => _thread = updated);
  }

  Future<void> _run(
    Future<FeedbackThread?> Function() action,
    String done,
  ) async {
    setState(() => _busy = true);
    try {
      final updated = await action();
      if (!mounted) return;
      if (updated != null) {
        setState(() {
          _thread = updated;
          _version.text = updated.fixedInVersion;
        });
      }
      _message(done);
    } catch (error) {
      if (!mounted) return;
      final fresh = (await _services.store.list())
          .where((item) => item.id == _thread.id)
          .firstOrNull;
      if (!mounted) return;
      if (fresh != null) setState(() => _thread = fresh);
      _message(feedbackRemoteErrorMessage(context, error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deliver(FeedbackTransport transport, String failure) async {
    setState(() => _busy = true);
    try {
      final delivery = await transport.send(_thread);
      if (!mounted) return;
      if (transport == _services.folderTransport) {
        _message(context.l10n.feedbackExported(delivery.path ?? ''));
      }
    } catch (_) {
      _message(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final diagnostics = _thread.diagnostics;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.feedbackDetailTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    Text(
                      feedbackKindLabel(context, _thread.kind),
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      feedbackDateLabel(context, _thread.createdAt),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (_thread.pendingSend)
                      Text(
                        l10n.feedbackPendingSend,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                  ],
                ),
                if (_thread.screen.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _thread.screen,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                SelectableText(_thread.text, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 24),
                Text(
                  l10n.feedbackStatusLabel,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final status in FeedbackStatus.values)
                      ChoiceChip(
                        label: Text(feedbackStatusLabel(context, status)),
                        selected: _thread.status == status,
                        onSelected: (_) => _setStatus(status),
                      ),
                  ],
                ),
                if (_thread.status == FeedbackStatus.fixed) ...[
                  const SizedBox(height: 12),
                  Focus(
                    onFocusChange: (focused) {
                      if (!focused) _saveVersion();
                    },
                    child: TextField(
                      controller: _version,
                      maxLength: 40,
                      onSubmitted: (_) => _saveVersion(),
                      decoration: InputDecoration(
                        labelText: l10n.feedbackFixedVersionLabel,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
                if (_thread.attachments.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  Text(
                    l10n.feedbackAttachmentsTitle,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final name in _thread.attachments)
                        _AttachmentThumb(
                          key: ValueKey('attachment-${_thread.id}-$name'),
                          load: () =>
                              _services.store.attachmentFile(_thread, name),
                        ),
                    ],
                  ),
                ],
                if (diagnostics != null && diagnostics.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(l10n.feedbackDiagnosticsTitle),
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          diagnostics,
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  l10n.feedbackCommentsTitle,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                for (final comment in _thread.comments)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          feedbackDateLabel(context, comment.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        SelectableText(comment.text),
                      ],
                    ),
                  ),
                TextField(
                  controller: _comment,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                    hintText: l10n.feedbackCommentHint,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _addComment,
                    child: Text(l10n.feedbackCommentAdd),
                  ),
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_hasToken && _thread.issueNumber == null)
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _services.sendRemote(_thread),
                                l10n.feedbackSentRemote,
                              ),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: Text(
                          _thread.pendingSend
                              ? l10n.feedbackRetrySend
                              : l10n.feedbackSendRemote,
                        ),
                      ),
                    if (_hasToken && _thread.issueNumber != null)
                      FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(
                                () => _services.syncRemote(_thread),
                                l10n.feedbackRefreshed,
                              ),
                        icon: const Icon(Icons.sync),
                        label: Text(l10n.feedbackRefresh),
                      ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _deliver(
                              _services.shareTransport,
                              l10n.feedbackShareFailed,
                            ),
                      icon: const Icon(Icons.ios_share),
                      label: Text(l10n.feedbackShare),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _deliver(
                              _services.folderTransport,
                              l10n.feedbackExportFailed,
                            ),
                      icon: const Icon(Icons.folder_outlined),
                      label: Text(l10n.feedbackExportFolder),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttachmentThumb extends StatefulWidget {
  const _AttachmentThumb({super.key, required this.load});

  final Future<File> Function() load;

  @override
  State<_AttachmentThumb> createState() => _AttachmentThumbState();
}

class _AttachmentThumbState extends State<_AttachmentThumb> {
  late final Future<File> _file = widget.load();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final broken = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
    );
    return SizedBox(
      width: 96,
      height: 96,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: FutureBuilder<File>(
          future: _file,
          builder: (context, snapshot) {
            final data = snapshot.data;
            if (data == null) return broken;
            return Image.file(
              data,
              cacheWidth: (96 * MediaQuery.devicePixelRatioOf(context)).ceil(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => broken,
            );
          },
        ),
      ),
    );
  }
}
