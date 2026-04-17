/// Represents a file with resolved peer connection information and metadata.
///
/// This model is used after peer hydration to provide all necessary information
/// for media playback, including connection details and file metadata.
class HydratedFile {
  /// Unique identifier for the file
  final String fileId;

  /// Display name of the file
  final String fileName;

  /// MIME type of the file (e.g., 'video/mp4', 'audio/mpeg')
  final String mimeType;

  /// Total size of the file in bytes
  final int totalBytes;

  /// Peer connection information for file streaming
  /// 
  /// TODO: Replace with proper PeerConnection type once implemented.
  /// This should contain Telegram peer connection details needed for streaming.
  final dynamic peerConnection;

  /// Optional metadata containing additional file information
  /// 
  /// May include fields like:
  /// - title: Display title for the media
  /// - duration: Duration in seconds for audio/video
  /// - thumbnailUrl: URL to thumbnail image
  final Map<String, dynamic>? metadata;

  HydratedFile({
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.totalBytes,
    required this.peerConnection,
    this.metadata,
  });

  /// Creates a copy of this HydratedFile with the given fields replaced
  HydratedFile copyWith({
    String? fileId,
    String? fileName,
    String? mimeType,
    int? totalBytes,
    dynamic peerConnection,
    Map<String, dynamic>? metadata,
  }) {
    return HydratedFile(
      fileId: fileId ?? this.fileId,
      fileName: fileName ?? this.fileName,
      mimeType: mimeType ?? this.mimeType,
      totalBytes: totalBytes ?? this.totalBytes,
      peerConnection: peerConnection ?? this.peerConnection,
      metadata: metadata ?? this.metadata,
    );
  }

  @override
  String toString() {
    return 'HydratedFile(fileId: $fileId, fileName: $fileName, mimeType: $mimeType, totalBytes: $totalBytes)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is HydratedFile &&
        other.fileId == fileId &&
        other.fileName == fileName &&
        other.mimeType == mimeType &&
        other.totalBytes == totalBytes &&
        other.peerConnection == peerConnection &&
        other.metadata == metadata;
  }

  @override
  int get hashCode {
    return Object.hash(
      fileId,
      fileName,
      mimeType,
      totalBytes,
      peerConnection,
      metadata,
    );
  }
}
