import 'data_repository.dart';

class MediaRepository {
  const MediaRepository({required this.dataRepository});

  final DataRepository dataRepository;

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
      verificationStatus: item.verificationStatus,
      locatorType: item.locatorType,
      locatorChatId: item.locatorChatId,
      locatorMessageId: item.locatorMessageId,
      locatorBotUsername: item.locatorBotUsername,
      locatorRemoteFileId: item.locatorRemoteFileId,
      chatId: item.thumbnailSourceChatId,
      messageId: item.thumbnailSourceMessageId,
    );
  }
}