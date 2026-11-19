import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/feedback_thread.dart';
import 'package:mornye/screens/feedback_labels.dart';
import 'package:mornye/screens/feedback_thread_page.dart';
import 'package:mornye/services/feedback/feedback_capture.dart';
import 'package:mornye/services/feedback/feedback_services.dart';
import 'package:mornye/services/feedback/feedback_store.dart';

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({
    super.key,
    this.services,
    this.initialText = '',
    this.initialScreen = '',
    this.initialKind = FeedbackKind.bug,
    this.previousScreenshot,
    this.pendingScreenshot,
  });

  final FeedbackServices? services;
  final String initialText;
  final String initialScreen;
  final FeedbackKind initialKind;
  final Uint8List? previousScreenshot;
  final Future<Uint8List?>? pendingScreenshot;

  static Future<void> open(
    BuildContext context, {
    String initialText = '',
    FeedbackKind initialKind = FeedbackKind.bug,
    String? screen,
    FeedbackServices? services,
  }) async {
    final routeName = ModalRoute.of(context)?.settings.name ?? '';
    final shot = (services?.captureScreen ?? FeedbackCapture.captureScreen)();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/feedback'),
        builder: (_) => FeedbackPage(
          services: services,
          initialText: initialText,
          initialKind: initialKind,
          initialScreen: screen ?? (routeName == '/' ? '' : routeName),
          pendingScreenshot: shot,
        ),
      ),
    );
  }

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  late final FeedbackServices _services = widget.services ?? FeedbackServices();
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  late final TextEditingController _screen = TextEditingController(
    text: widget.initialScreen,
  );
  late FeedbackKind _kind = widget.initialKind;
  final List<FeedbackImage> _images = [];
  bool _includeDiagnostics = true;
  bool _saving = false;
  bool _showTextError = false;
  FeedbackStatus? _filter;
  List<FeedbackThread> _threads = const [];
  int _shotCount = 0;
  bool _hasToken = false;
  bool _testing = false;
  final Set<FeedbackImage> _preparing = {};
  final TextEditingController _token = TextEditingController();

  FeedbackStore get _store => _services.store;

  @override
  void initState() {
    super.initState();
    final previous = widget.previousScreenshot;
    if (previous != null) {
      _images.add(_screenshot(previous));
    }
    final pending = widget.pendingScreenshot;
    if (pending != null) {
      unawaited(
        pending.then<void>((bytes) {
          if (mounted && bytes != null) {
            setState(() => _images.add(_screenshot(bytes)));
          }
        }, onError: (Object _, StackTrace _) {}),
      );
    }
    _store.addListener(_reload);
    _reload();
    _loadToken();
  }

  Future<void> _loadToken() async {
    final token = await _services.tokenStore.read();
    if (mounted) setState(() => _hasToken = token != null);
  }

  Future<void> _saveToken() async {
    final value = _token.text.trim();
    if (value.isEmpty) return;
    final saved = context.l10n.feedbackTokenSaved;
    await _services.tokenStore.write(value);
    _token.clear();
    await _loadToken();
    _message(saved);
  }

  Future<void> _removeToken() async {
    final removed = context.l10n.feedbackTokenRemoved;
    await _services.tokenStore.clear();
    await _loadToken();
    _message(removed);
  }

  Future<void> _testConnection() async {
    final ok = context.l10n.feedbackConnectionOk;
    setState(() => _testing = true);
    try {
      await _services.remote.testConnection();
      _message(ok);
    } catch (error) {
      if (mounted) _message(feedbackRemoteErrorMessage(context, error));
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  void dispose() {
    _store.removeListener(_reload);
    _text.dispose();
    _screen.dispose();
    _token.dispose();
    super.dispose();
  }

  FeedbackImage _screenshot(Uint8List bytes) {
    _shotCount++;
    return FeedbackImage(name: 'pantalla-$_shotCount.png', bytes: bytes);
  }

  Future<void> _reload() async {
    try {
      final threads = await _store.list();
      if (mounted) setState(() => _threads = threads);
    } catch (_) {
      if (mounted) setState(() => _threads = const []);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  static const _maxImages = 6;

  Future<void> _pick() async {
    try {
      final picked = await _services.pickImages();
      if (!mounted || picked.isEmpty) return;
      final room = _maxImages - _images.length;
      final accepted = picked.take(room < 0 ? 0 : room).toList();
      if (accepted.length < picked.length) {
        _message(context.l10n.feedbackImagesLimit);
      }
      setState(() {
        _images.addAll(accepted);
        _preparing.addAll(accepted.where((image) => image.path != null));
      });
      for (final image in accepted.where((image) => image.path != null)) {
        unawaited(_prepare(image));
      }
    } catch (_) {
      if (mounted) _message(context.l10n.feedbackSaveFailed);
    }
  }

  Future<void> _prepare(FeedbackImage image) async {
    FeedbackImage? ready;
    try {
      ready = await _services.prepareImage(image);
    } catch (_) {
      ready = null;
    }
    if (!mounted) return;
    final index = _images.indexWhere((item) => identical(item, image));
    setState(() {
      _preparing.remove(image);
      if (index < 0) return;
      if (ready == null) {
        _images.removeAt(index);
      } else {
        _images[index] = ready;
      }
    });
    if (ready == null && index >= 0) _message(context.l10n.feedbackImageFailed);
  }

  Future<void> _save() async {
    if (_text.text.trim().isEmpty) {
      setState(() => _showTextError = true);
      return;
    }
    final l10n = context.l10n;
    setState(() {
      _saving = true;
      _showTextError = false;
    });
    try {
      final diagnostics = _includeDiagnostics
          ? (await _services.loadDiagnostics(context)).toText()
          : null;
      final created = await _store.create(
        kind: _kind,
        text: _text.text,
        screen: _screen.text,
        diagnostics: diagnostics,
        images: List.of(_images),
      );
      if (!mounted) return;
      setState(() {
        _text.clear();
        _images.clear();
      });
      if (_hasToken) {
        try {
          await _services.sendRemote(created);
          _message(l10n.feedbackSentRemote);
        } catch (error) {
          if (mounted) {
            _message(
              '${l10n.feedbackSavedPending} '
              '${feedbackRemoteErrorMessage(context, error)}',
            );
          }
        }
      } else {
        _message(l10n.feedbackSaved);
      }
    } catch (_) {
      _message(l10n.feedbackSaveFailed);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openThread(FeedbackThread thread) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FeedbackThreadPage(thread: thread, services: _services),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final visible = _filter == null
        ? _threads
        : [
            for (final thread in _threads)
              if (thread.status == _filter) thread,
          ];
    return Scaffold(
      appBar: AppBar(title: Text(l10n.feedbackTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _SectionTitle(l10n.feedbackNewReport),
                const SizedBox(height: 12),
                Text(l10n.feedbackKindLabel, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final kind in FeedbackKind.values)
                      ChoiceChip(
                        label: Text(feedbackKindLabel(context, kind)),
                        selected: _kind == kind,
                        onSelected: (_) => setState(() => _kind = kind),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _text,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: 4000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: l10n.feedbackTextLabel,
                    hintText: l10n.feedbackTextHint,
                    alignLabelWithHint: true,
                    errorText: _showTextError
                        ? l10n.feedbackTextRequired
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_showTextError) setState(() => _showTextError = false);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _screen,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: l10n.feedbackScreenLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pick,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(l10n.feedbackAttachScreenshots),
                    ),
                  ],
                ),
                if (_images.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _images.length; i++)
                        _DraftThumb(
                          key: ValueKey('feedback-draft-$i'),
                          image: _images[i],
                          preparing: _preparing.contains(_images[i]),
                          onRemove: () => setState(() {
                            _preparing.remove(_images[i]);
                            _images.removeAt(i);
                          }),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _includeDiagnostics,
                  onChanged: (value) =>
                      setState(() => _includeDiagnostics = value ?? false),
                  title: Text(l10n.feedbackIncludeDiagnostics),
                  subtitle: Text(l10n.feedbackDiagnosticsHint),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.feedbackPrivacyNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                if (_saving) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    _hasToken
                        ? l10n.feedbackSendingReport
                        : l10n.feedbackSavingReport,
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  onPressed: _saving || _preparing.isNotEmpty ? null : _save,
                  child: Text(
                    _hasToken ? l10n.feedbackSaveAndSend : l10n.feedbackSave,
                  ),
                ),
                const SizedBox(height: 32),
                _SectionTitle(l10n.feedbackThreadsTitle),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    ChoiceChip(
                      label: Text(l10n.feedbackFilterAll),
                      selected: _filter == null,
                      onSelected: (_) => setState(() => _filter = null),
                    ),
                    for (final status in FeedbackStatus.values)
                      ChoiceChip(
                        label: Text(feedbackStatusLabel(context, status)),
                        selected: _filter == status,
                        onSelected: (_) => setState(() => _filter = status),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (visible.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l10n.feedbackEmpty,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                else
                  for (final thread in visible)
                    _ThreadCard(
                      key: ValueKey('feedback-thread-${thread.id}'),
                      thread: thread,
                      onTap: () => _openThread(thread),
                    ),
                const SizedBox(height: 24),
                ExpansionTile(
                  key: const ValueKey('feedback-settings'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  shape: const Border(),
                  collapsedShape: const Border(),
                  title: Text(l10n.feedbackSettingsTitle),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l10n.feedbackTokenHelp,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _token,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: l10n.feedbackTokenLabel,
                        helperText: _hasToken ? l10n.feedbackTokenActive : null,
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.tonal(
                            onPressed: _saveToken,
                            child: Text(l10n.feedbackTokenSave),
                          ),
                          OutlinedButton(
                            onPressed: _hasToken && !_testing
                                ? _testConnection
                                : null,
                            child: Text(l10n.feedbackTestConnection),
                          ),
                          TextButton(
                            onPressed: _hasToken ? _removeToken : null,
                            child: Text(l10n.feedbackTokenRemove),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}

class _DraftThumb extends StatelessWidget {
  const _DraftThumb({
    super.key,
    required this.image,
    required this.onRemove,
    this.preparing = false,
  });

  final FeedbackImage image;
  final VoidCallback onRemove;
  final bool preparing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bytes = image.bytes;
    final path = image.path;
    final broken = ColoredBox(
      color: scheme.surfaceContainerHighest,
      child: Icon(Icons.image_outlined, color: scheme.onSurfaceVariant),
    );
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: bytes != null
                ? Image.memory(
                    bytes,
                    cacheWidth: 252,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => broken,
                  )
                : path != null
                ? Image.file(
                    File(path),
                    cacheWidth: 252,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => broken,
                  )
                : broken,
          ),
          if (preparing)
            Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  semanticsLabel: context.l10n.feedbackImagePreparing,
                ),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              tooltip: context.l10n.feedbackRemoveAttachment,
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              style: IconButton.styleFrom(
                backgroundColor: scheme.surface.withValues(alpha: 0.8),
              ),
              onPressed: onRemove,
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadCard extends StatelessWidget {
  const _ThreadCard({super.key, required this.thread, required this.onTap});

  final FeedbackThread thread;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    Text(
                      feedbackKindLabel(context, thread.kind),
                      style: theme.textTheme.labelLarge,
                    ),
                    if (thread.pendingSend)
                      Text(
                        context.l10n.feedbackPendingSend,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    Text(
                      feedbackStatusLabel(context, thread.status),
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: feedbackStatusColor(scheme, thread.status),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  thread.text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 6),
                Text(
                  feedbackDateLabel(context, thread.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
