import 'package:mornye/models/download_item.dart' show DownloadErrorType;

enum QualityReplaceFailure {
  downloadFailed,
  cancelled,
  timedOut,
  noFile,
  emptyFile,
  sameFile,
  durationMismatch,
}

class QualityReplaceResult {
  final String? path;
  final QualityReplaceFailure? failure;
  final String? detail;
  final DownloadErrorType? errorType;
  final String? summary;
  final bool switched;
  final bool removedPrevious;

  const QualityReplaceResult.success(
    String this.path, {
    required this.switched,
    required this.removedPrevious,
  }) : failure = null,
       detail = null,
       errorType = null,
       summary = null;

  const QualityReplaceResult.failed(
    QualityReplaceFailure this.failure, {
    this.detail,
    this.errorType,
    this.summary,
  }) : path = null,
      switched = false,
      removedPrevious = false;

  bool get ok => path != null;
}

String shortFailureCause(String? raw) {
  final text = (raw ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '';
  return text.length <= 90 ? text : '${text.substring(0, 87)}...';
}
