import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'core/navigation/home_browse_focus.dart';

import 'core/auth/auth_notifier.dart';
import 'core/debug/app_debug_log.dart';
import 'core/config/app_config.dart';
import 'data/api/oxplayer_api_service.dart';
import 'data/models/app_media.dart';
import 'data/models/user_chat_dtos.dart';
import 'data/local/telegram_session_store.dart';
import 'data/tmdb/tmdb_repository.dart';
import 'download/download_manager.dart';
import 'telegram/tdlib_controller.dart'
    if (dart.library.html) 'telegram/tdlib_controller_web.dart';
import 'telegram/tdlib_facade.dart';

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnv());
final oxplayerApiServiceProvider =
    Provider<OxplayerApiService>((ref) => OxplayerApiService());

enum LibraryTypeFilter { all, movies, series }

class SourceFilterOption {
  const SourceFilterOption({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;
}

/// Single TDLib JSON client for the app (Android / desktop; not used on web)
final tdlibFacadeProvider = Provider<TdlibFacade>((ref) {
  final facade = TelegramTdlibFacade(
    onUserAuthorized: (user) async {
      await putTelegramSessionFromUser(user);
      await ref.read(authNotifierProvider).setSession('tdlib:${user.id}');
    },
    onRequiresInteractiveLogin: () async {
      final auth = ref.read(authNotifierProvider);
      if (!auth.hasTelegramSession) return;
      await auth.clearTelegramSession();
    },
  );
  ref.onDispose(() {
    unawaited(facade.dispose());
  });
  return facade;
});

final authNotifierProvider = ChangeNotifierProvider<AuthNotifier>((ref) {
  return AuthNotifier();
});

final tmdbRepositoryProvider = Provider<TmdbRepository?>((ref) {
  return TmdbRepository();
});

/// Merged GET [/me/library/media] for `movie`, `series`, and `general_video` (sorted client-side).
///
/// Only [AuthNotifier.isLoggedIn] + [AuthNotifier.apiAccessToken] are watched so
/// unrelated profile updates (userType, etc.) do not re-run this fetch.
final libraryFetchProvider = FutureProvider<LibraryFetchResult>((ref) async {
  final (:isLoggedIn, :apiAccessToken) = ref.watch(
    authNotifierProvider.select(
      (a) => (isLoggedIn: a.isLoggedIn, apiAccessToken: a.apiAccessToken),
    ),
  );
  final token = apiAccessToken;
  if (!isLoggedIn || token == null || token.isEmpty) {
    AppDebugLog.instance.log(
      'libraryFetchProvider: skipped (isLoggedIn=$isLoggedIn '
      'tokenLen=${token?.length ?? 0}) — empty until bearer is set; '
      'HomeScreen obtains token on open refresh',
      category: AppDebugLogCategory.app,
    );
    return const LibraryFetchResult(items: []);
  }

  final config = ref.read(appConfigProvider);
  final api = ref.read(oxplayerApiServiceProvider);
  AppDebugLog.instance.log(
    'libraryFetchProvider: fetching apiBaseUrl=${config.apiBaseUrl} '
    'tokenLen=${token.length}',
    category: AppDebugLogCategory.app,
  );
  try {
    final result = await api.fetchLibrary(
      config: config,
      accessToken: token,
    );
    AppDebugLog.instance.log(
      'libraryFetchProvider: success items=${result.items.length} '
      'sources=${result.sources.length}',
      category: AppDebugLogCategory.app,
    );
    return result;
  } catch (e, st) {
    final head = st.toString().split('\n').take(5).join(' | ');
    AppDebugLog.instance.log(
      'libraryFetchProvider: failed $e | $head',
      category: AppDebugLogCategory.app,
    );
    rethrow;
  }
});

/// One GET [/me/library/media] per [kind] (`movie` | `series` | `general_video`).
/// Used by Home rows and category grid; separate from merged [libraryFetchProvider].
final libraryMediaByKindProvider =
    FutureProvider.family<List<AppMediaAggregate>, String>((ref, kind) async {
  final (:isLoggedIn, :apiAccessToken) = ref.watch(
    authNotifierProvider.select(
      (a) => (isLoggedIn: a.isLoggedIn, apiAccessToken: a.apiAccessToken),
    ),
  );
  final token = apiAccessToken;
  if (!isLoggedIn || token == null || token.isEmpty) {
    return const [];
  }
  final config = ref.read(appConfigProvider);
  final api = ref.read(oxplayerApiServiceProvider);
  return api.fetchLibraryMediaByKind(
    config: config,
    accessToken: token,
    kind: kind,
    limit: 100,
  );
});

/// Bumped after a library refresh from the API so explore can refetch (`/me/explore/media`).
final exploreCatalogRefreshGenerationProvider = StateProvider<int>((ref) => 0);

/// Bumped to refetch GET [/me/chats] for the Sources tab and picker.
final indexedChatsRefreshGenerationProvider = StateProvider<int>((ref) => 0);

/// Indexed chats for one API bucket: `chats` | `groups` | `channels` | `bots`.
final indexedChatsForBucketProvider =
    FutureProvider.family<UserChatListPage, String>((ref, bucket) async {
  final (:isLoggedIn, :apiAccessToken) = ref.watch(
    authNotifierProvider.select(
      (a) => (isLoggedIn: a.isLoggedIn, apiAccessToken: a.apiAccessToken),
    ),
  );
  ref.watch(indexedChatsRefreshGenerationProvider);
  final token = apiAccessToken;
  if (!isLoggedIn || token == null || token.isEmpty) {
    return const UserChatListPage(items: [], total: 0);
  }
  final config = ref.read(appConfigProvider);
  final api = ref.read(oxplayerApiServiceProvider);
  return api.fetchUserChats(
    config: config,
    accessToken: token,
    bucket: bucket,
    indexedOnly: true,
    limit: 200,
    offset: 0,
  );
});

/// Library items only (same [AsyncValue] shape widgets expect from the old [FutureProvider]).
final mediaListProvider = Provider<AsyncValue<List<AppMediaAggregate>>>((ref) {
  return ref.watch(libraryFetchProvider).whenData((r) => r.items);
});

final selectedTypeFilterProvider =
    StateProvider<LibraryTypeFilter>((ref) => LibraryTypeFilter.all);
final selectedSourceFilterProvider = StateProvider<String?>((ref) => null);
final lastFocusedGridIndexProvider = StateProvider<int>((ref) => 0);

final sourceFilterOptionsProvider = Provider<List<SourceFilterOption>>((ref) {
  final lib = ref.watch(libraryFetchProvider).valueOrNull;
  if (lib != null && lib.sources.isNotEmpty) {
    return lib.sources
        .map(
          (s) => SourceFilterOption(
            id: s.id,
            label: s.label.trim().isNotEmpty ? s.label : 'Source ${s.id}',
          ),
        )
        .toList();
  }

  final aggregates =
      ref.watch(mediaListProvider).valueOrNull ?? const <AppMediaAggregate>[];
  final ids = aggregates
      .expand((agg) => agg.files.map((f) => f.sourceId).whereType<String>())
      .toSet()
      .toList();
  ids.sort();

  final idToLabel = <String, String>{};
  for (final agg in aggregates) {
    for (final f in agg.files) {
      final sid = f.sourceId;
      if (sid == null || sid.isEmpty) continue;
      final name = f.sourceName?.trim();
      if (name != null && name.isNotEmpty) {
        idToLabel[sid] = name;
      }
    }
  }

  return ids
      .map(
        (id) => SourceFilterOption(
          id: id,
          label: idToLabel[id] ?? 'Source $id',
        ),
      )
      .toList();
});

final filteredMediaProvider = Provider<List<AppMediaAggregate>>((ref) {
  final media =
      ref.watch(mediaListProvider).valueOrNull ?? const <AppMediaAggregate>[];
  final typeFilter = ref.watch(selectedTypeFilterProvider);
  final sourceFilter = ref.watch(selectedSourceFilterProvider);

  return media.where((item) {
    final byType = switch (typeFilter) {
      LibraryTypeFilter.all => true,
      // `/me/library/media` general_video rows are single-title; show them with
      // movies so the default "Movies" browse is not empty when TMDB is unset.
      LibraryTypeFilter.movies =>
        item.media.type == 'MOVIE' ||
        item.media.type == '#movie' ||
        item.media.type == 'GENERAL_VIDEO',
      LibraryTypeFilter.series =>
        item.media.type == 'SERIES' || item.media.type == '#series',
    };

    if (item.files.isEmpty) {
      // Light library rows from GET [/me/library/media] have no source ids; only type filter applies.
      return byType;
    }

    final bySource = sourceFilter == null ||
        item.files.any((f) => f.sourceId == sourceFilter);
    return byType && bySource;
  }).toList();
});

final downloadsListProvider =
    FutureProvider<List<MediaDownloadRecord>>((ref) async {
  final dm = await ref.watch(downloadManagerProvider.future);
  return dm.getAllRecords();
});

/// Global [DownloadManager]
final downloadManagerProvider =
    AsyncNotifierProvider<_DownloadManagerNotifier, DownloadManager>(
  _DownloadManagerNotifier.new,
);

class _DownloadManagerNotifier extends AsyncNotifier<DownloadManager> {
  @override
  Future<DownloadManager> build() async {
    final tdlib = ref.watch(tdlibFacadeProvider);
    final config = ref.read(appConfigProvider);
    final dm = DownloadManager(
      tdlib: tdlib,
      recoverFromBackup: (mediaFileId) async {
        final auth = ref.read(authNotifierProvider);
        final token = auth.apiAccessToken;
        if (token == null) return false;
        final api = ref.read(oxplayerApiServiceProvider);
        return api.recoverMediaFileFromBackup(
          config: config,
          accessToken: token,
          mediaFileId: mediaFileId,
        );
      },
      afterBackupRecoveryRefresh: () async {
        final auth = ref.read(authNotifierProvider);
        if (auth.apiAccessToken == null) return;
        ref.invalidate(libraryFetchProvider);
        ref.read(exploreCatalogRefreshGenerationProvider.notifier).state++;
        await ref.read(libraryFetchProvider.future);
      },
      reloadLocatorAfterRecovery: (_, variantId) async {
        final lib = await ref.read(libraryFetchProvider.future);
        final items = lib.items;
        AppMediaFile? hit;
        for (final agg in items) {
          for (final f in agg.files) {
            if (f.id == variantId) {
              hit = f;
              break;
            }
          }
          if (hit != null) break;
        }
        if (hit == null) return null;
        return DownloadLocatorRefresh(
          telegramFileId: hit.telegramFileId,
          sourceChatId: hit.sourceChatId,
          mediaFileId: hit.id,
          locatorType: hit.locatorType,
          locatorChatId: hit.locatorChatId,
          locatorMessageId: hit.locatorMessageId,
          locatorBotUsername: hit.locatorBotUsername,
          locatorRemoteFileId: hit.locatorRemoteFileId,
        );
      },
    );
    await dm.restorePersistedStates();

    void onManagerChanged() {
      state = AsyncData(dm);
    }

    dm.addListener(onManagerChanged);
    ref.onDispose(() {
      dm.removeListener(onManagerChanged);
      dm.dispose();
    });
    return dm;
  }
}
