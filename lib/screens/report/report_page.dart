import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/feedback_page.dart';
import 'package:mornye/services/diagnostics/report_image_codec.dart';
import 'package:mornye/services/diagnostics/report_models.dart';
import 'package:mornye/services/diagnostics/report_service.dart';
import 'package:mornye/services/feedback/feedback_capture.dart';
import 'package:mornye/services/feedback/feedback_services.dart';

typedef ReportGalleryPicker = Future<List<Uint8List>> Function();
typedef ReportScreenCapture = Future<Uint8List?> Function();
typedef ReportImageCompressor = Future<Uint8List?> Function(Uint8List bytes);

Future<List<Uint8List>> pickReportGalleryImages() async {
  final picked = await FeedbackServices.pickGalleryImages();
  return [
    for (final image in picked)
      if (image.path != null) await File(image.path!).readAsBytes(),
  ];
}

class ReportPage extends StatefulWidget {
  const ReportPage({
    super.key,
    this.service,
    this.initialKind = ReportKind.error,
    this.initialText = '',
    this.pickImages,
    this.captureScreen,
    this.compressImage,
    this.previousScreen,
  });

  final ReportService? service;
  final ReportKind initialKind;
  final String initialText;
  final ReportGalleryPicker? pickImages;
  final ReportScreenCapture? captureScreen;
  final ReportImageCompressor? compressImage;
  final Future<Uint8List?>? previousScreen;

  /// Opens the report form from Settings, About, the BETA notice or the
  /// error log. The screen behind is captured first so it can be offered as
  /// an attachment; nothing is attached or sent without the person's choice.
  static Future<void> open(
    BuildContext context, {
    ReportKind kind = ReportKind.error,
    String initialText = '',
    ReportService? service,
  }) {
    final previous = FeedbackCapture.captureScreen();
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/report'),
        builder: (_) => ReportPage(
          service: service,
          initialKind: kind,
          initialText: initialText,
          previousScreen: previous,
        ),
      ),
    );
  }

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  late final ReportService _service = widget.service ?? ReportService();
  late final TextEditingController _text = TextEditingController(
    text: widget.initialText,
  );
  final TextEditingController _contact = TextEditingController();
  late ReportKind _kind = widget.initialKind;
  late bool _includeLog = widget.initialKind == ReportKind.error;
  bool _logTouched = false;
  bool _includeDevice = false;
  bool _consent = false;
  bool _showTextError = false;
  bool _showConsentError = false;
  bool _sending = false;
  int _preparing = 0;
  int _pending = 0;
  String? _rawLog;
  Uint8List? _previous;
  final List<ReportImage> _images = [];

  @override
  void initState() {
    super.initState();
    if (_includeLog) unawaited(_loadLog());
    unawaited(_loadPending());
    widget.previousScreen?.then<void>((bytes) {
      if (mounted) setState(() => _previous = bytes);
    }, onError: (Object _, StackTrace _) {});
  }

  @override
  void dispose() {
    _text.dispose();
    _contact.dispose();
    super.dispose();
  }

  Future<void> _loadLog() async {
    final raw = await _service.readLog();
    if (mounted) setState(() => _rawLog = raw);
  }

  Future<void> _loadPending() async {
    try {
      await _service.flushPending();
      final count = await _service.pendingCount();
      if (mounted) setState(() => _pending = count);
    } catch (_) {}
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _setKind(ReportKind kind) {
    setState(() {
      _kind = kind;
      if (!_logTouched) _includeLog = kind == ReportKind.error;
    });
    if (_includeLog && _rawLog == null) unawaited(_loadLog());
  }

  Future<void> _addRaw(Uint8List raw) async {
    if (_images.length + _preparing >= ReportPackage.maxImages) {
      _message(context.l10n.reportImagesLimit);
      return;
    }
    setState(() => _preparing++);
    Uint8List? jpeg;
    try {
      jpeg = await (widget.compressImage ?? ReportImageCodec.compress)(raw);
    } catch (_) {
      jpeg = null;
    }
    if (!mounted) return;
    setState(() {
      _preparing--;
      if (jpeg != null) _images.add(ReportImage(jpeg));
    });
    if (jpeg == null) _message(context.l10n.reportImageFailed);
  }

  Future<void> _capture() async {
    Uint8List? shot;
    try {
      shot = await (widget.captureScreen ?? FeedbackCapture.captureScreen)();
    } catch (_) {
      shot = null;
    }
    if (shot == null) {
      if (mounted) _message(context.l10n.reportImageFailed);
      return;
    }
    await _addRaw(shot);
  }

  Future<void> _pick() async {
    try {
      final picked = await (widget.pickImages ?? pickReportGalleryImages)();
      for (final raw in picked) {
        if (!mounted) return;
        await _addRaw(raw);
      }
    } catch (_) {
      if (mounted) _message(context.l10n.reportImageFailed);
    }
  }

  ReportDraft _draft() => ReportDraft(
    kind: _kind,
    text: _text.text,
    contact: _contact.text,
    includeLog: _includeLog,
    includeDevice: _includeDevice,
    images: List.of(_images),
  );

  Future<ReportPackage> _package() => _service.build(
    _draft(),
    locale: Localizations.localeOf(context).toLanguageTag(),
    rawLog: _includeLog ? (_rawLog ?? '') : null,
  );

  Future<void> _preview() async {
    final l10n = context.l10n;
    if (_includeLog && _rawLog == null) await _loadLog();
    final package = await _package();
    if (!mounted) return;
    final body = package.logField;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(l10n.reportPreviewTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              '${l10n.reportKindLabel}: ${package.kind.wire}\n'
              '${l10n.reportDescriptionLabel}:\n${package.text}',
              key: const ValueKey('report-preview-text'),
            ),
            if (package.contact.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText('${l10n.reportContactLabel}: ${package.contact}'),
            ],
            const SizedBox(height: 8),
            SelectableText('${package.version} / Android ${package.os}'),
            const SizedBox(height: 12),
            SelectableText(
              body.isNotEmpty
                  ? body
                  : (_includeLog
                        ? l10n.reportPreviewLogEmpty
                        : l10n.reportPreviewNothing),
              key: const ValueKey('report-preview-log'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
            if (package.images.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(l10n.reportPreviewImages(package.images.length)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.reportPreviewClose),
          ),
        ],
      ),
    );
  }

  bool _validate({required bool needConsent}) {
    final textOk = _text.text.trim().isNotEmpty;
    final consentOk = !needConsent || _consent;
    setState(() {
      _showTextError = !textOk;
      _showConsentError = !consentOk;
    });
    return textOk && consentOk;
  }

  Future<void> _send() async {
    if (_sending || !_validate(needConsent: true)) return;
    final l10n = context.l10n;
    setState(() => _sending = true);
    try {
      final package = await _package();
      final outcome = await _service.submit(package);
      if (!mounted) return;
      switch (outcome) {
        case ReportSent(:final ref):
          _reset();
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(l10n.reportSentTitle),
              content: Text(
                l10n.reportSentBody(ref),
                key: const ValueKey('report-sent-body'),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.reportSentDone),
                ),
              ],
            ),
          );
        case ReportQueued():
          _reset();
          final count = await _service.pendingCount();
          if (mounted) setState(() => _pending = count);
          _message(l10n.reportQueued);
        case ReportRateLimited():
          _message(l10n.reportRateLimited);
        case ReportRejected():
          _message(l10n.reportRejected);
      }
    } catch (_) {
      _message(l10n.reportRejected);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _reset() {
    setState(() {
      _text.clear();
      _contact.clear();
      _images.clear();
      _consent = false;
    });
  }

  Future<void> _shareFile() async {
    if (_sending || !_validate(needConsent: false)) return;
    final l10n = context.l10n;
    try {
      if (_includeLog && _rawLog == null) await _loadLog();
      await _service.shareAsFile(await _package());
    } catch (_) {
      _message(l10n.reportShareFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final full = _images.length + _preparing >= ReportPackage.maxImages;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.reportTitle)),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(l10n.reportBetaNote, style: muted),
                const SizedBox(height: 16),
                if (_pending > 0) ...[
                  Card(
                    child: ListTile(
                      key: const ValueKey('report-pending'),
                      leading: const Icon(Icons.schedule_send_outlined),
                      title: Text(l10n.reportPending(_pending)),
                      trailing: TextButton(
                        onPressed: _loadPending,
                        child: Text(l10n.reportPendingRetry),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                Text(l10n.reportKindLabel, style: theme.textTheme.labelLarge),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final kind in ReportKind.values)
                      ChoiceChip(
                        key: ValueKey('report-kind-${kind.name}'),
                        label: Text(switch (kind) {
                          ReportKind.error => l10n.reportKindError,
                          ReportKind.idea => l10n.reportKindIdea,
                          ReportKind.other => l10n.reportKindOther,
                        }),
                        selected: _kind == kind,
                        onSelected: (_) => _setKind(kind),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('report-text'),
                  controller: _text,
                  minLines: 4,
                  maxLines: 8,
                  maxLength: ReportPackage.maxText,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: l10n.reportDescriptionLabel,
                    hintText: l10n.reportDescriptionHint,
                    alignLabelWithHint: true,
                    errorText: _showTextError
                        ? l10n.reportDescriptionRequired
                        : null,
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_showTextError) setState(() => _showTextError = false);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const ValueKey('report-contact'),
                  controller: _contact,
                  maxLength: ReportPackage.maxContact,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: l10n.reportContactLabel,
                    helperText: l10n.reportContactHelper,
                    helperMaxLines: 2,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  key: const ValueKey('report-attach-log'),
                  contentPadding: EdgeInsets.zero,
                  value: _includeLog,
                  title: Text(l10n.reportAttachLog),
                  subtitle: Text(l10n.reportAttachLogSubtitle),
                  onChanged: (value) {
                    setState(() {
                      _includeLog = value;
                      _logTouched = true;
                    });
                    if (value && _rawLog == null) unawaited(_loadLog());
                  },
                ),
                SwitchListTile(
                  key: const ValueKey('report-attach-device'),
                  contentPadding: EdgeInsets.zero,
                  value: _includeDevice,
                  title: Text(l10n.reportAttachDevice),
                  subtitle: Text(l10n.reportAttachDeviceSubtitle),
                  onChanged: (value) => setState(() => _includeDevice = value),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('report-preview'),
                    onPressed: _preview,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text(l10n.reportViewWhatIsSent),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  l10n.reportScreenshotsTitle,
                  style: theme.textTheme.labelLarge,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      key: const ValueKey('report-capture'),
                      onPressed: full ? null : _capture,
                      icon: const Icon(Icons.screenshot_outlined),
                      label: Text(l10n.reportCaptureScreen),
                    ),
                    if (_previous != null)
                      OutlinedButton.icon(
                        key: const ValueKey('report-previous'),
                        onPressed: full ? null : () => _addRaw(_previous!),
                        icon: const Icon(Icons.history),
                        label: Text(l10n.reportUsePreviousScreen),
                      ),
                    OutlinedButton.icon(
                      key: const ValueKey('report-gallery'),
                      onPressed: full ? null : _pick,
                      icon: const Icon(Icons.add_photo_alternate_outlined),
                      label: Text(l10n.reportPickGallery),
                    ),
                  ],
                ),
                if (_images.isNotEmpty || _preparing > 0) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (var i = 0; i < _images.length; i++)
                        _Thumb(
                          key: ValueKey('report-thumb-$i'),
                          bytes: _images[i].bytes,
                          tooltip: l10n.reportRemoveImage,
                          onRemove: () => setState(() => _images.removeAt(i)),
                        ),
                      for (var i = 0; i < _preparing; i++)
                        const SizedBox(
                          width: 84,
                          height: 84,
                          child: Center(child: CircularProgressIndicator()),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.reportConsentText,
                          key: const ValueKey('report-consent-text'),
                          style: theme.textTheme.bodySmall,
                        ),
                        CheckboxListTile(
                          key: const ValueKey('report-consent'),
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: _consent,
                          title: Text(l10n.reportConsentCheck),
                          onChanged: (value) => setState(() {
                            _consent = value ?? false;
                            if (_consent) _showConsentError = false;
                          }),
                        ),
                        if (_showConsentError)
                          Text(
                            l10n.reportConsentRequired,
                            key: const ValueKey('report-consent-error'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (_sending) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                ],
                FilledButton(
                  key: const ValueKey('report-send'),
                  onPressed: _sending || _preparing > 0 ? null : _send,
                  child: Text(_sending ? l10n.reportSending : l10n.reportSend),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const ValueKey('report-share'),
                  onPressed: _sending ? null : _shareFile,
                  icon: const Icon(Icons.ios_share),
                  label: Text(l10n.reportShareFile),
                ),
                const SizedBox(height: 24),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    key: const ValueKey('report-advanced'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const FeedbackPage(),
                      ),
                    ),
                    child: Text(l10n.reportAdvancedLink),
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

class _Thumb extends StatelessWidget {
  const _Thumb({
    super.key,
    required this.bytes,
    required this.tooltip,
    required this.onRemove,
  });

  final Uint8List bytes;
  final String tooltip;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 84,
      height: 84,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(
              bytes,
              cacheWidth: 252,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => ColoredBox(
                color: scheme.surfaceContainerHighest,
                child: const Icon(Icons.image_outlined),
              ),
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              key: const ValueKey('report-thumb-remove'),
              tooltip: tooltip,
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
