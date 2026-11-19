enum FeedbackKind { bug, suggestion, design, other }

enum FeedbackStatus { sent, reviewing, fixed, dismissed }

class FeedbackComment {
  const FeedbackComment({
    required this.id,
    required this.createdAt,
    required this.text,
    this.remoteId,
  });

  final String id;
  final DateTime createdAt;
  final String text;
  final int? remoteId;

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'text': text,
    if (remoteId != null) 'remoteId': remoteId,
  };

  static FeedbackComment? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || text is! String || created == null) return null;
    final remote = raw['remoteId'];
    return FeedbackComment(
      id: id,
      createdAt: created.toLocal(),
      text: text,
      remoteId: remote is int ? remote : null,
    );
  }
}

class FeedbackThread {
  const FeedbackThread({
    required this.id,
    required this.createdAt,
    required this.kind,
    required this.text,
    this.screen = '',
    this.attachments = const [],
    this.diagnostics,
    this.status = FeedbackStatus.sent,
    this.fixedInVersion = '',
    this.comments = const [],
    this.issueNumber,
    this.issueUrl = '',
    this.pendingSend = false,
  });

  final String id;
  final DateTime createdAt;
  final FeedbackKind kind;
  final String text;
  final String screen;
  final List<String> attachments;
  final String? diagnostics;
  final FeedbackStatus status;
  final String fixedInVersion;
  final List<FeedbackComment> comments;
  final int? issueNumber;
  final String issueUrl;
  final bool pendingSend;

  FeedbackThread copyWith({
    FeedbackStatus? status,
    String? fixedInVersion,
    List<String>? attachments,
    List<FeedbackComment>? comments,
    int? issueNumber,
    String? issueUrl,
    bool? pendingSend,
  }) => FeedbackThread(
    id: id,
    createdAt: createdAt,
    kind: kind,
    text: text,
    screen: screen,
    attachments: attachments ?? this.attachments,
    diagnostics: diagnostics,
    status: status ?? this.status,
    fixedInVersion: fixedInVersion ?? this.fixedInVersion,
    comments: comments ?? this.comments,
    issueNumber: issueNumber ?? this.issueNumber,
    issueUrl: issueUrl ?? this.issueUrl,
    pendingSend: pendingSend ?? this.pendingSend,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'kind': kind.name,
    'text': text,
    'screen': screen,
    'attachments': attachments,
    'diagnostics': diagnostics,
    'status': status.name,
    'fixedInVersion': fixedInVersion,
    'comments': [for (final comment in comments) comment.toJson()],
    'issueNumber': issueNumber,
    'issueUrl': issueUrl,
    'pendingSend': pendingSend,
  };

  static FeedbackThread? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    final created = DateTime.tryParse('${raw['createdAt']}');
    if (id is! String || id.isEmpty || text is! String || created == null) {
      return null;
    }
    final comments = raw['comments'];
    final attachments = raw['attachments'];
    final diagnostics = raw['diagnostics'];
    return FeedbackThread(
      id: id,
      createdAt: created.toLocal(),
      kind:
          FeedbackKind.values.asNameMap()['${raw['kind']}'] ??
          FeedbackKind.other,
      text: text,
      screen: raw['screen'] is String ? raw['screen'] as String : '',
      attachments: attachments is List
          ? [
              for (final name in attachments)
                if (name is String && name.isNotEmpty) name,
            ]
          : const [],
      diagnostics: diagnostics is String ? diagnostics : null,
      status:
          FeedbackStatus.values.asNameMap()['${raw['status']}'] ??
          FeedbackStatus.sent,
      fixedInVersion: raw['fixedInVersion'] is String
          ? raw['fixedInVersion'] as String
          : '',
      comments: comments is List
          ? [for (final item in comments) ?FeedbackComment.fromJson(item)]
          : const [],
      issueNumber: raw['issueNumber'] is int ? raw['issueNumber'] as int : null,
      issueUrl: raw['issueUrl'] is String ? raw['issueUrl'] as String : '',
      pendingSend: raw['pendingSend'] == true,
    );
  }
}
