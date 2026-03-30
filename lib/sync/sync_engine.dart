import 'package:flutter/foundation.dart';
import 'package:isar/isar.dart';
import 'package:tdlib/td_api.dart' as td;

import '../core/config/app_config.dart';
import '../core/debug/app_debug_log.dart';
import '../data/local/entities.dart';
import '../data/local/isar_provider.dart';
import '../telegram/tdlib_facade.dart';
import 'sync_parser.dart';

class SyncEngine {
  SyncEngine(this._isar);

  final Isar _isar;

  Future<void> runSync(TdlibFacade tdlib, AppConfig config) async {
    try {
      AppDebugLog.instance.log('SyncEngine: Starting sync...');
      AppDebugLog.instance.log('SyncEngine: Waiting for tdlib.ensureAuthorized()...');
      await tdlib.ensureAuthorized();
      AppDebugLog.instance.log('SyncEngine: TDLib authorized, proceeding...');
      
      final chatIds = <int>{};

      // 1. Resolve bot username to get bot user ID
      AppDebugLog.instance.log('SyncEngine: Resolving bot @${config.botUsername}');
      final resolved = await tdlib.send(td.SearchPublicChat(username: config.botUsername));
      if (resolved is! td.Chat) {
        AppDebugLog.instance.log('SyncEngine: Failed to resolve bot username');
        return;
      }
      final botUserId = (resolved.type as td.ChatTypePrivate).userId;
      AppDebugLog.instance.log('SyncEngine: Bot resolved (userId=$botUserId)');

      // 2. Private chat with bot
      final privateChat = await tdlib.send(td.CreatePrivateChat(userId: botUserId, force: false));
      if (privateChat is td.Chat) {
        chatIds.add(privateChat.id);
      }

      // 3. Shared groups
      AppDebugLog.instance.log('SyncEngine: Fetching groups in common...');
      final groups = await tdlib.send(td.GetGroupsInCommon(userId: botUserId, offsetChatId: 0, limit: 100));
      if (groups is td.Chats) {
        chatIds.addAll(groups.chatIds);
        AppDebugLog.instance.log('SyncEngine: Found ${groups.chatIds.length} common groups');
      }

      // 4. For each chat, save MediaSource and search messages
      AppDebugLog.instance.log('SyncEngine: Processing ${chatIds.length} sources total');
      for (final chatId in chatIds) {
        final chatObj = await tdlib.send(td.GetChat(chatId: chatId));
        if (chatObj is td.Chat) {
          AppDebugLog.instance.log('SyncEngine: Syncing source "${chatObj.title}" (id=$chatId)');
          final photoPath = chatObj.photo?.small.local.path;
          final source = MediaSource()
            ..sourceId = chatId
            ..name = chatObj.title
            ..imagePath = photoPath;
          
          await _isar.runWithRetry(() => _isar.writeTxn(() async {
            await _isar.mediaSources.put(source);
          }), debugName: 'putSource:$chatId');
        }

        // Search messages
        var offsetMessageId = 0;
        var hasMore = true;

        while (hasMore) {
          AppDebugLog.instance.log(
            'SyncEngine: SearchChatMessages chatId=$chatId query="${config.indexTag}" '
            'fromMessageId=$offsetMessageId',
          );
          Object? msgsObj;
          try {
            msgsObj = await tdlib.send(td.SearchChatMessages(
              chatId: chatId,
              query: config.indexTag,
              senderId: null,
              filter: null,
              messageThreadId: 0,
              fromMessageId: offsetMessageId,
              offset: 0,
              limit: 100,
            ));
          } catch (e, st) {
            AppDebugLog.instance.log('SyncEngine: SearchChatMessages FAILED: $e');
            debugPrint('SearchChatMessages error: $e\n$st');
            hasMore = false;
            continue;
          }

          final batch = msgsObj;
          if (batch is td.FoundChatMessages) {
            if (batch.messages.isEmpty) {
              AppDebugLog.instance.log(
                'SyncEngine: No more messages (tag="${config.indexTag}") in $chatId',
              );
              hasMore = false;
            } else {
              AppDebugLog.instance.log(
                'SyncEngine: Found ${batch.messages.length} potential messages in $chatId',
              );
              await _isar.runWithRetry(() => _isar.writeTxn(() async {
                for (final msg in batch.messages) {
                  await _indexMessage(tdlib, msg, chatId);
                }
              }), debugName: 'batchIndexFound:$chatId');
              offsetMessageId = batch.nextFromMessageId;
              if (offsetMessageId == 0) {
                hasMore = false;
              }
            }
          } else if (batch is td.Messages) {
            if (batch.messages.isEmpty) {
              AppDebugLog.instance.log(
                'SyncEngine: No more messages (tag="${config.indexTag}") in $chatId',
              );
              hasMore = false;
            } else {
              AppDebugLog.instance.log(
                'SyncEngine: Found ${batch.messages.length} potential messages in $chatId',
              );
              await _isar.runWithRetry(() => _isar.writeTxn(() async {
                for (final msg in batch.messages) {
                  await _indexMessage(tdlib, msg, chatId);
                  offsetMessageId = msg.id;
                }
              }), debugName: 'batchIndexMsgs:$chatId');
            }
          } else {
            AppDebugLog.instance.log(
              'SyncEngine: Unexpected SearchChatMessages result: ${batch.runtimeType}',
            );
            hasMore = false;
          }
        }
      }

      // 5. Save global sync checkpoint for 4-hour auto-sync tracking
      await _isar.runWithRetry(() => _isar.writeTxn(() async {
        final now = DateTime.now().millisecondsSinceEpoch;
        final globalSync = SyncCheckpoint()
          ..dialogKey = 'global_sync'
          ..scope = 'global'
          ..dialogId = 0
          ..lastMessageId = 0
          ..lastSyncAt = now
          ..status = 'success';
        await _isar.syncCheckpoints.put(globalSync);
      }), debugName: 'putSyncCheckpoint');
    } catch (e, st) {
      if (e is td.TdError) {
        AppDebugLog.instance.log(
          'SyncEngine: runSync TdError code=${e.code} message=${e.message}',
        );
      } else {
        AppDebugLog.instance.log('SyncEngine: runSync error: $e');
      }
      debugPrint('SyncEngine runSync error: $e\n$st');
      rethrow;
    }
  }

  Future<void> _indexMessage(TdlibFacade tdlib, td.Message msg, int chatId) async {
    String text = '';
    td.MessageVideo? video;
    td.MessageDocument? document;
    var sourceMessageId = msg.id;
    
    // Type A: Caption
    if (msg.content is td.MessageVideo) {
      video = msg.content as td.MessageVideo;
      text = video.caption.text;
    } else if (msg.content is td.MessageDocument) {
      document = msg.content as td.MessageDocument;
      text = document.caption.text;
    } 
    // Type B: Reply
    else if (msg.content is td.MessageText) {
      final mt = msg.content as td.MessageText;
      text = mt.text.text;
      if (msg.replyTo is td.MessageReplyToMessage) {
        final replyToId = (msg.replyTo as td.MessageReplyToMessage).messageId;
        try {
          final repliedMsg = await tdlib.send(td.GetMessage(chatId: chatId, messageId: replyToId));
          if (repliedMsg is td.Message) {
            if (repliedMsg.content is td.MessageVideo) {
              video = repliedMsg.content as td.MessageVideo;
              sourceMessageId = repliedMsg.id;
            } else if (repliedMsg.content is td.MessageDocument) {
              document = repliedMsg.content as td.MessageDocument;
              sourceMessageId = repliedMsg.id;
            }
          }
        } catch (_) {}
      }
    }

    if (video == null && document == null) {
      return; 
    }

    final title = SyncParser.extractTag(text, 'name');
    if (title == null || title.isEmpty) {
      return; 
    }

    final imdbId = SyncParser.extractTag(text, 'imdb') ?? '';
    final tmdbId = SyncParser.extractTag(text, 'tmdb_id') ?? SyncParser.extractTag(text, 'tmdb');
    final mediaType = text.contains('#series') ? '#series' : '#movie';
    final explicitRes = SyncParser.extractTag(text, 'RES');

    final tags = SyncParser.extractAllTags(text);
    final resolvedGlobalTag = SyncParser.extractUuidTag(text, 'global_id');
    final resolvedFileTag = SyncParser.extractUuidTag(text, 'file_id');

    final fileIdFallback = video?.video.video.remote.id ?? document?.document.document.remote.id ?? '';
    final fileName = video?.video.fileName ?? document?.document.fileName ?? fileIdFallback;
    final mimeType = video?.video.mimeType ?? document?.document.mimeType ?? 'video/mp4';
    final fileSize = video?.video.video.expectedSize ?? document?.document.document.expectedSize;
    final durationSec = video?.video.duration ?? 0;

    final resolvedGlobalId = resolvedGlobalTag ?? SyncParser.buildFallbackGlobalId(chatId, msg.id, title);
    final bitrateEstimate = SyncParser.estimateBitrate(fileSize, durationSec);
    final streamFlags = SyncParser.streamSupportHeuristic(fileSize, bitrateEstimate);
    final supportsStreamingAttr = video?.video.supportsStreaming ?? false;

    final variantId = resolvedFileTag != null && resolvedFileTag.isNotEmpty
        ? '$resolvedGlobalId:$resolvedFileTag'
        : '$resolvedGlobalId:$chatId:$sourceMessageId';

    final now = DateTime.now().millisecondsSinceEpoch;

    final existingVariant = await _isar.mediaVariants.getByVariantId(variantId);
    final variant = MediaVariant()
      ..id = existingVariant?.id ?? Isar.autoIncrement
      ..variantId = variantId
      ..globalId = resolvedGlobalId
      ..msgId = sourceMessageId
      ..chatId = chatId
      ..sourceScope = 'tdlib'
      ..fileName = fileName
      ..mimeType = mimeType
      ..fileSize = fileSize
      ..durationSec = durationSec
      ..qualityLabel = SyncParser.deriveQualityLabel(fileName: fileName, sizeBytes: fileSize, explicitRes: explicitRes)
      ..bitrateEstimate = bitrateEstimate
      ..streamSupported = streamFlags.streamSupported || supportsStreamingAttr
      ..isPremiumNeeded = streamFlags.isPremiumNeeded
      ..fileReferenceJson = null
      ..createdAt = now;

    await _isar.mediaVariants.put(variant);

    final existing = await _isar.mediaItems.getByGlobalId(resolvedGlobalId);
    final variants = await _isar.mediaVariants.filter().globalIdEqualTo(resolvedGlobalId).findAll();

    variants.sort((a, b) {
      if (a.streamSupported != b.streamSupported) return a.streamSupported ? -1 : 1;
      return (a.fileSize ?? 0) - (b.fileSize ?? 0);
    });

    final best = variants.isEmpty ? null : variants.first;

    final merged = MediaItem()
      ..id = existing?.id ?? Isar.autoIncrement
      ..globalId = resolvedGlobalId
      ..title = title
      ..imdbId = imdbId
      ..tmdbId = tmdbId
      ..mediaType = mediaType
      ..genres = existing?.genres ?? const <String>[]
      ..tags = tags
      ..posterUrl = existing?.posterUrl
      ..backdropUrl = existing?.backdropUrl
      ..mediaSourceId = chatId
      ..lastMsgId = msg.id
      ..lastSyncedAt = now
      ..variantsCount = variants.length
      ..bestVariantId = best?.variantId
      ..streamSupported = (best?.streamSupported ?? false) || supportsStreamingAttr
      ..isPremiumNeeded = best?.isPremiumNeeded ?? false
      ..bitrateEstimate = best?.bitrateEstimate
      ..metaCachedAt = existing?.metaCachedAt;

    await _isar.mediaItems.put(merged);

    // ── Series sub-indexing ───────────────────────────────────────────────────
    if (mediaType == '#series') {
      final seasonNum = SyncParser.extractSeasonNumber(text) ?? 1;
      final episodeNum = SyncParser.extractEpisodeNumber(text);
      if (episodeNum != null) {
        await _indexSeriesEpisode(
          globalId: resolvedGlobalId,
          seasonNumber: seasonNum,
          episodeNumber: episodeNum,
          title: title,
          variantId: variantId,
          msgId: sourceMessageId,
          chatId: chatId,
          fileSize: fileSize,
          durationSec: durationSec,
        );
      }
    }
  }

  Future<void> _indexSeriesEpisode({
    required String globalId,
    required int seasonNumber,
    required int episodeNumber,
    required String title,
    required String variantId,
    required int msgId,
    required int chatId,
    int? fileSize,
    int? durationSec,
  }) async {
    final seasonKey = '$globalId:S$seasonNumber';
    final episodeKey = '$globalId:S$seasonNumber:E$episodeNumber';

    // Upsert season
    final existingSeason = await _isar.mediaSeasons.getBySeasonKey(seasonKey);
    final season = MediaSeason()
      ..id = existingSeason?.id ?? Isar.autoIncrement
      ..globalId = globalId
      ..seasonKey = seasonKey
      ..seasonNumber = seasonNumber
      ..title = existingSeason?.title ?? 'Season $seasonNumber'
      ..episodeCount = (existingSeason?.episodeCount ?? 0);

    // Upsert episode
    final existingEp = await _isar.mediaEpisodes.getByEpisodeKey(episodeKey);
    final episode = MediaEpisode()
      ..id = existingEp?.id ?? Isar.autoIncrement
      ..episodeKey = episodeKey
      ..globalId = globalId
      ..seasonKey = seasonKey
      ..seasonNumber = seasonNumber
      ..episodeNumber = episodeNumber
      ..title = existingEp?.title ?? 'Episode $episodeNumber'
      ..variantId = variantId
      ..msgId = msgId
      ..chatId = chatId
      ..fileSize = fileSize
      ..durationSec = durationSec;

    await _isar.mediaSeasons.put(season);
    await _isar.mediaEpisodes.put(episode);

    final allEps = await _isar.mediaEpisodes
        .filter()
        .seasonKeyEqualTo(seasonKey)
        .findAll();
    final updatedSeason = await _isar.mediaSeasons.getBySeasonKey(seasonKey);
    if (updatedSeason != null) {
      updatedSeason.episodeCount = allEps.length;
      await _isar.mediaSeasons.put(updatedSeason);
    }
  }
}
