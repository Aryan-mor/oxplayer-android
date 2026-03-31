import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/config/app_config.dart';
import '../../core/debug/app_debug_log.dart';
import '../../telegram/tdlib_facade.dart';
import '../models/app_media.dart';

class TvAppApiService {
  TvAppApiService();
  int _requestCounter = 0;

  Dio _dio(String baseUrl) {
    final dio = Dio(
      BaseOptions(
        baseUrl: baseUrl,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: const {
          // Needed for ngrok dev tunnels; ignored by normal backends.
          'ngrok-skip-browser-warning': 'true',
          'accept': 'application/json',
        },
      ),
    );

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final reqId = ++_requestCounter;
          final startedAt = DateTime.now().microsecondsSinceEpoch;
          options.extra['reqId'] = reqId;
          options.extra['startedAtUs'] = startedAt;
          AppDebugLog.instance.log(
            'API[$reqId] -> ${options.method} ${options.uri} '
            'headers=${_summarizeHeaders(options.headers)} '
            'body=${_summarizePayload(options.data)}',
          );
          handler.next(options);
        },
        onResponse: (response, handler) {
          final reqId = response.requestOptions.extra['reqId'] ?? '?';
          final startedAt = response.requestOptions.extra['startedAtUs'] as int?;
          final elapsedMs = startedAt == null
              ? -1
              : ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000)
                    .round();
          AppDebugLog.instance.log(
            'API[$reqId] <- ${response.statusCode} ${response.requestOptions.uri} '
            'in ${elapsedMs}ms '
            'body=${_summarizePayload(response.data)}',
          );
          handler.next(response);
        },
        onError: (error, handler) {
          final reqId = error.requestOptions.extra['reqId'] ?? '?';
          final startedAt = error.requestOptions.extra['startedAtUs'] as int?;
          final elapsedMs = startedAt == null
              ? -1
              : ((DateTime.now().microsecondsSinceEpoch - startedAt) / 1000)
                    .round();
          final status = error.response?.statusCode;
          AppDebugLog.instance.log(
            'API[$reqId] !! ${error.type} status=$status '
            '${error.requestOptions.method} ${error.requestOptions.uri} '
            'in ${elapsedMs}ms '
            'error=${error.message} '
            'body=${_summarizePayload(error.response?.data)}',
          );
          handler.next(error);
        },
      ),
    );

    return dio;
  }

  Future<String> authenticateWithTelegram({
    required TdlibFacade tdlib,
    required AppConfig config,
  }) async {
    AppDebugLog.instance.log(
      'API auth start: baseUrl=${config.tvAppApiBaseUrl}, '
      'bot=${config.botUsername}, shortName=${config.tvAppWebAppShortName}, '
      'fallbackUrlSet=${config.tvAppWebAppUrl.isNotEmpty}',
    );
    final initData = await _fetchSignedInitData(tdlib: tdlib, config: config);
    AppDebugLog.instance.log(
      'API auth: extracted initData length=${initData.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.post<Map<String, dynamic>>(
      '/auth/telegram',
      data: {'initData': initData},
    );

    final accessToken = response.data?['accessToken']?.toString() ?? '';
    if (accessToken.isEmpty) {
      throw StateError('API did not return accessToken');
    }
    AppDebugLog.instance.log(
      'API auth success: tokenLength=${accessToken.length}',
    );
    return accessToken;
  }

  Future<List<AppMediaAggregate>> fetchLibrary({
    required AppConfig config,
    required String accessToken,
  }) async {
    AppDebugLog.instance.log(
      'API fetchLibrary start: tokenLength=${accessToken.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.get<Map<String, dynamic>>(
      '/me/library',
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final items = _readItems(response.data);
    AppDebugLog.instance.log('API fetchLibrary success: items=${items.length}');
    return items;
  }

  Future<List<AppMediaAggregate>> syncLibrary({
    required AppConfig config,
    required String accessToken,
    required List<String> mediaFileIds,
  }) async {
    AppDebugLog.instance.log(
      'API syncLibrary start: ids=${mediaFileIds.length}, tokenLength=${accessToken.length}',
    );
    final dio = _dio(config.tvAppApiBaseUrl);
    final response = await dio.post<Map<String, dynamic>>(
      '/me/sync',
      data: {'mediaFileIds': mediaFileIds},
      options: Options(headers: {'Authorization': 'Bearer $accessToken'}),
    );
    final items = _readItems(response.data);
    AppDebugLog.instance.log('API syncLibrary success: items=${items.length}');
    return items;
  }

  Future<void> collectMediaFileIdsFromTelegram({
    required TdlibFacade tdlib,
    required AppConfig config,
    required Future<void> Function(Set<String> discoveredIds) onBatch,
  }) async {
    AppDebugLog.instance.log(
      'Sync discover start: bot=${config.botUsername}, query=${config.indexTag}',
    );
    await tdlib.ensureAuthorized();
    final chatIds = <int>{};

    final resolved = await tdlib.send(
      td.SearchPublicChat(username: config.botUsername),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      AppDebugLog.instance.log('Sync discover: BOT_USERNAME did not resolve to private chat');
      return;
    }
    final botUserId = (resolved.type as td.ChatTypePrivate).userId;

    final privateChat = await tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is td.Chat) {
      chatIds.add(privateChat.id);
    }

    final groups = await tdlib.send(
      td.GetGroupsInCommon(userId: botUserId, offsetChatId: 0, limit: 100),
    );
    if (groups is td.Chats) {
      chatIds.addAll(groups.chatIds);
    }
    AppDebugLog.instance.log('Sync discover: scanning chats=${chatIds.length}');

    int totalCollected = 0;
    final currentBatch = <String>{};
    final timer = Stopwatch()..start();

    Future<void> flushBatch() async {
      if (currentBatch.isEmpty) return;
      try {
        await onBatch(Set.of(currentBatch));
        totalCollected += currentBatch.length;
      } catch (e) {
        AppDebugLog.instance.log('Sync discover: onBatch failed with $e');
      }
      currentBatch.clear();
      timer.reset();
    }

    for (final chatId in chatIds) {
      var fromMessageId = 0;
      var hasMore = true;
      var pageCount = 0;

      while (hasMore && pageCount < 20) {
        pageCount++;
        final batch = await tdlib.send(
          td.SearchChatMessages(
            chatId: chatId,
            query: config.indexTag,
            senderId: null,
            filter: null,
            messageThreadId: 0,
            fromMessageId: fromMessageId,
            offset: 0,
            limit: 100,
          ),
        );

        if (batch is td.FoundChatMessages) {
          if (batch.messages.isEmpty) {
            hasMore = false;
            continue;
          }
          for (final msg in batch.messages) {
            final text = _extractText(msg);
            final mediaFileId = _extractMediaFileId(text);
            if (mediaFileId != null) currentBatch.add(mediaFileId);
          }
          if (timer.elapsed.inSeconds >= 10 && currentBatch.isNotEmpty) {
            await flushBatch();
          }
          fromMessageId = batch.nextFromMessageId;
          if (fromMessageId == 0) hasMore = false;
          continue;
        }

        if (batch is td.Messages) {
          if (batch.messages.isEmpty) {
            hasMore = false;
            continue;
          }
          for (final msg in batch.messages) {
            final text = _extractText(msg);
            final mediaFileId = _extractMediaFileId(text);
            if (mediaFileId != null) currentBatch.add(mediaFileId);
          }
          if (timer.elapsed.inSeconds >= 10 && currentBatch.isNotEmpty) {
            await flushBatch();
          }
          fromMessageId = batch.messages.last.id;
          continue;
        }

        hasMore = false;
      }
    }
    
    // Final flush
    if (currentBatch.isNotEmpty) {
      await flushBatch();
    }
    
    AppDebugLog.instance.log('Sync discover done: total mediaFileIds=$totalCollected');
  }

  Future<String> _fetchSignedInitData({
    required TdlibFacade tdlib,
    required AppConfig config,
  }) async {
    await tdlib.ensureAuthorized();
    final resolved = await tdlib.send(
      td.SearchPublicChat(username: config.botUsername),
    );
    if (resolved is! td.Chat || resolved.type is! td.ChatTypePrivate) {
      throw StateError('Cannot resolve BOT_USERNAME to a private chat');
    }
    final botUserId = (resolved.type as td.ChatTypePrivate).userId;

    final privateChat = await tdlib.send(
      td.CreatePrivateChat(userId: botUserId, force: false),
    );
    if (privateChat is! td.Chat) {
      throw StateError('Failed to create private chat with bot');
    }

    String? webAppUrl;
    td.TdError? shortNameError;

    if (config.tvAppWebAppShortName.isNotEmpty) {
      try {
        AppDebugLog.instance.log(
          'InitData: trying GetWebAppLinkUrl shortName=${config.tvAppWebAppShortName}',
        );
        final result = await tdlib.send(
          td.GetWebAppLinkUrl(
            chatId: privateChat.id,
            botUserId: botUserId,
            webAppShortName: config.tvAppWebAppShortName,
            startParameter: '',
            theme: null,
            applicationName: 'telecima_tv',
            allowWriteAccess: true,
          ),
        );
        if (result is td.HttpUrl) {
          webAppUrl = result.url;
          AppDebugLog.instance.log(
            'InitData: shortName URL received (len=${webAppUrl.length})',
          );
        }
      } catch (e) {
        if (e is td.TdError) shortNameError = e;
        AppDebugLog.instance.log('InitData: shortName failed: $e');
      }
    }

    if (webAppUrl == null && config.tvAppWebAppUrl.isNotEmpty) {
      AppDebugLog.instance.log('InitData: trying GetWebAppUrl fallback');
      final fallbackResult = await tdlib.send(
        td.GetWebAppUrl(
          botUserId: botUserId,
          url: config.tvAppWebAppUrl,
          theme: null,
          applicationName: 'telecima_tv',
        ),
      );
      if (fallbackResult is td.HttpUrl) {
        webAppUrl = fallbackResult.url;
        AppDebugLog.instance.log(
          'InitData: fallback URL received (len=${webAppUrl.length})',
        );
      }
    }

    if (webAppUrl == null) {
      if (shortNameError != null) {
        throw StateError(
          'WebApp initData failed (${shortNameError.message}). '
          'Set TV_APP_WEBAPP_SHORT_NAME correctly or set TV_APP_WEBAPP_URL fallback.',
        );
      }
      throw StateError(
        'Cannot get WebApp URL. Set TV_APP_WEBAPP_SHORT_NAME or TV_APP_WEBAPP_URL in env.',
      );
    }

    final initData = _extractTgWebAppData(webAppUrl);
    if (initData == null || initData.isEmpty) {
      throw StateError('tgWebAppData not found in web app URL');
    }
    _logInitDataAuthAge(initData);
    AppDebugLog.instance.log(
      'InitData: tgWebAppData extracted (len=${initData.length})',
    );
    return initData;
  }

  List<AppMediaAggregate> _readItems(Map<String, dynamic>? body) {
    final raw = body?['items'];
    if (raw is! List) return const <AppMediaAggregate>[];
    return raw
        .whereType<Map<String, dynamic>>()
        .map((e) {
          try {
            return AppMediaAggregate.fromJson(e);
          } catch (_) {
            return null;
          }
        })
        .whereType<AppMediaAggregate>()
        .toList();
  }

  String _extractText(td.Message msg) {
    final content = msg.content;
    if (content is td.MessageVideo) return content.caption.text;
    if (content is td.MessageDocument) return content.caption.text;
    if (content is td.MessageText) return content.text.text;
    return '';
  }

  String? _extractMediaFileId(String text) {
    if (text.isEmpty) return null;
    final pattern = RegExp(
      r'MediaFileID:\s*(?:<code>)?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12})',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(text);
    return match?.group(1);
  }

  String? _extractTgWebAppData(String webAppUrl) {
    final uri = Uri.tryParse(webAppUrl);
    if (uri == null) return null;

    final fromQuery = uri.queryParameters['tgWebAppData'];
    if (fromQuery != null && fromQuery.isNotEmpty) {
      return Uri.decodeComponent(fromQuery);
    }

    final fragment = uri.fragment;
    if (fragment.isNotEmpty) {
      final fragmentUri = Uri.parse('https://local/?$fragment');
      final fromFragment = fragmentUri.queryParameters['tgWebAppData'];
      if (fromFragment != null && fromFragment.isNotEmpty) {
        return Uri.decodeComponent(fromFragment);
      }
    }
    return null;
  }

  String _summarizeHeaders(Map<String, dynamic> headers) {
    final cleaned = <String, dynamic>{};
    for (final entry in headers.entries) {
      final key = entry.key.toLowerCase();
      if (key == 'authorization') {
        cleaned[entry.key] = '<redacted>';
      } else {
        cleaned[entry.key] = entry.value;
      }
    }
    return cleaned.toString();
  }

  String _summarizePayload(dynamic payload) {
    if (payload == null) return 'null';
    String text;
    try {
      text = payload is String ? payload : jsonEncode(payload);
    } catch (_) {
      text = payload.toString();
    }
    if (text.length > 300) {
      return '${text.substring(0, 300)}...(${text.length} chars)';
    }
    return text;
  }

  void _logInitDataAuthAge(String initData) {
    try {
      final params = Uri.splitQueryString(initData);
      final authDateRaw = params['auth_date'];
      if (authDateRaw == null || authDateRaw.isEmpty) {
        AppDebugLog.instance.log('InitData: auth_date missing');
        return;
      }
      final authDate = int.tryParse(authDateRaw);
      if (authDate == null) {
        AppDebugLog.instance.log('InitData: auth_date invalid ($authDateRaw)');
        return;
      }
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ageSec = nowSec - authDate;
      AppDebugLog.instance.log(
        'InitData: auth_date=$authDate now=$nowSec ageSec=$ageSec',
      );
    } catch (e) {
      AppDebugLog.instance.log('InitData: failed to parse auth_date: $e');
    }
  }
}
