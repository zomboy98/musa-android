import 'dart:convert';
import 'dart:typed_data';

enum ReportKind {
  error('error'),
  idea('idea'),
  other('otro');

  const ReportKind(this.wire);

  final String wire;
}

class ReportImage {
  const ReportImage(this.bytes, {this.mime = 'image/jpeg'});

  final Uint8List bytes;
  final String mime;
}

class ReportDraft {
  const ReportDraft({
    required this.kind,
    required this.text,
    this.contact = '',
    this.includeLog = false,
    this.includeDevice = false,
    this.images = const [],
  });

  final ReportKind kind;
  final String text;
  final String contact;
  final bool includeLog;
  final bool includeDevice;
  final List<ReportImage> images;
}

/// Everything that leaves the phone, already redacted and limited.
class ReportPackage {
  const ReportPackage({
    required this.kind,
    required this.text,
    required this.contact,
    required this.version,
    required this.os,
    required this.logField,
    required this.deviceText,
    required this.logText,
    required this.images,
  });

  static const maxText = 2000;
  static const maxContact = 120;
  static const maxImages = 3;

  final ReportKind kind;
  final String text;
  final String contact;
  final String version;
  final int os;
  final String logField;
  final String deviceText;
  final String logText;
  final List<ReportImage> images;

  Map<String, Object?> toBody(String installId) => {
    'id': installId,
    'kind': kind.wire,
    'text': text,
    if (contact.isNotEmpty) 'contact': contact,
    'version': version,
    'os': os,
    if (logField.isNotEmpty) 'log': logField,
    if (images.isNotEmpty)
      'images': [
        for (final image in images)
          {'mime': image.mime, 'data': base64Encode(image.bytes)},
      ],
  };
}
