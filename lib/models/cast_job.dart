class CastJob {
  final String jobId;
  final String chatId;
  final int messageId;
  final String fileId;
  final String fileName;
  final String mimeType;
  final int totalBytes;
  final String? thumbnailUrl;
  final Map<String, dynamic>? metadata;
  final DateTime createdAt;

  CastJob({
    required this.jobId,
    required this.chatId,
    required this.messageId,
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.totalBytes,
    this.thumbnailUrl,
    this.metadata,
    required this.createdAt,
  });

  factory CastJob.fromJson(Map<String, dynamic> json) {
    return CastJob(
      jobId: json['jobId'] as String,
      chatId: json['chatId'] as String,
      messageId: json['messageId'] as int,
      fileId: json['fileId'] as String,
      fileName: json['fileName'] as String,
      mimeType: json['mimeType'] as String,
      totalBytes: json['totalBytes'] as int,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'jobId': jobId,
      'chatId': chatId,
      'messageId': messageId,
      'fileId': fileId,
      'fileName': fileName,
      'mimeType': mimeType,
      'totalBytes': totalBytes,
      'thumbnailUrl': thumbnailUrl,
      'metadata': metadata,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
