import 'data_repository.dart';

class MediaRepository {
  const MediaRepository({required this.dataRepository});

  final DataRepository dataRepository;

  Future<OxLibraryMediaDetail> fetchLibraryMediaDetail(String globalId) {
    return dataRepository.fetchOxLibraryMediaDetail(globalId);
  }

  /// Picks the first streamable file, or falls back to the first available file.
  OxLibraryMediaDetailFile? selectPreferredFile(OxLibraryMediaDetail detail) {
    for (final file in detail.files) {
      if (file.canStream == true) {
        return file;
      }
    }
    if (detail.files.isEmpty) {
      return null;
    }
    return detail.files.first;
  }

  Future<String?> resolveFilePathForSystemPlayback(OxLibraryMediaDetailFile file) {
    return dataRepository.resolveOxMediaFilePathForPlayback(
      mediaId: file.id,
      fileUniqueId: file.fileUniqueId,
      locatorType: file.locatorType,
      locatorChatId: file.locatorChatId,
      locatorMessageId: file.locatorMessageId,
      locatorRemoteFileId: file.locatorRemoteFileId,
    );
  }

  Future<bool> requestMediaRecovery(String mediaId) {
    return dataRepository.requestOxMediaRecovery(mediaId);
  }

  /// Fetches and caches the Telegram thumbnail for a [general_video] item.
  ///
  /// Delegates to [DataRepository.fetchVideoThumbnail] which resolves the
  /// Telegram file through locator metadata first and falls back to source
  /// message thumbnail extraction only when needed. Returns a local absolute
  /// file path, or `null` when no thumbnail is available.
  Future<String?> fetchVideoThumbnail(OxLibraryMediaItem item) {
    return dataRepository.fetchVideoThumbnail(
      mediaId: item.globalId,
      fileUniqueId: item.fileUniqueId,
      locatorType: item.locatorType,
      locatorChatId: item.locatorChatId,
      locatorMessageId: item.locatorMessageId,
      locatorRemoteFileId: item.locatorRemoteFileId,
      chatId: item.thumbnailSourceChatId,
      messageId: item.thumbnailSourceMessageId,
    );
  }
}