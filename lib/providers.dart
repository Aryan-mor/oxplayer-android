import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_notifier.dart';
import 'core/config/app_config.dart';
import 'data/api/tv_app_api_service.dart';
import 'data/models/app_media.dart';
import 'data/local/telegram_session_store.dart';
import 'data/tmdb/tmdb_repository.dart';
import 'data/library_telegram_sync.dart';
import 'download/download_manager.dart';
import 'telegram/tdlib_controller.dart' if (dart.library.html) 'telegram/tdlib_controller_web.dart';
import 'telegram/tdlib_facade.dart';

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnv());
final tvAppApiServiceProvider =
    Provider<TvAppApiService>((ref) => TvAppApiService());

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

final mediaListProvider = FutureProvider<List<AppMediaAggregate>>((ref) async {
  final authNotifier = ref.watch(authNotifierProvider);
  if (!authNotifier.isLoggedIn || authNotifier.apiAccessToken == null) {
    return const [];
  }
  
  final config = ref.read(appConfigProvider);
  final api = ref.read(tvAppApiServiceProvider);
  final result = await api.fetchLibrary(
    config: config,
    accessToken: authNotifier.apiAccessToken!,
  );
  return result.items;
});

final selectedTypeFilterProvider =
    StateProvider<LibraryTypeFilter>((ref) => LibraryTypeFilter.all);
final selectedSourceFilterProvider = StateProvider<String?>((ref) => null);
final lastFocusedGridIndexProvider = StateProvider<int>((ref) => 0);

final sourceFilterOptionsProvider = Provider<List<SourceFilterOption>>((ref) {
  final aggregates = ref.watch(mediaListProvider).valueOrNull ?? const <AppMediaAggregate>[];
  final ids = aggregates.expand((agg) => agg.files.map((f) => f.sourceId).whereType<String>()).toSet().toList();
  ids.sort();
  
  return ids
      .map(
        (id) => SourceFilterOption(
          id: id,
          label: 'Source $id', // In older code this was just channel ID number
        ),
      )
      .toList();
});

final filteredMediaProvider = Provider<List<AppMediaAggregate>>((ref) {
  final media = ref.watch(mediaListProvider).valueOrNull ?? const <AppMediaAggregate>[];
  final typeFilter = ref.watch(selectedTypeFilterProvider);
  final sourceFilter = ref.watch(selectedSourceFilterProvider);

  return media.where((item) {
    final byType = switch (typeFilter) {
      LibraryTypeFilter.all => true,
      LibraryTypeFilter.movies => item.media.type == 'MOVIE' || item.media.type == '#movie',
      LibraryTypeFilter.series => item.media.type == 'SERIES' || item.media.type == '#series',
    };
    
    // Check if any file matching this source exists
    final bySource = sourceFilter == null ? true : item.files.any((f) => f.sourceId == sourceFilter);
    return byType && bySource;
  }).toList();
});

final downloadsListProvider = FutureProvider<List<MediaDownloadRecord>>((ref) async {
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
      indexTagForFileSearch: config.indexTag,
      providerBotUsernameForDownloads: config.providerBotUsername.trim().isEmpty
          ? null
          : config.providerBotUsername,
      recoverFromBackup: (mediaFileId) async {
        final auth = ref.read(authNotifierProvider);
        final token = auth.apiAccessToken;
        if (token == null) return false;
        final api = ref.read(tvAppApiServiceProvider);
        return api.recoverMediaFileFromBackup(
          config: config,
          accessToken: token,
          mediaFileId: mediaFileId,
        );
      },
      afterBackupRecoveryRefresh: () async {
        final auth = ref.read(authNotifierProvider);
        final token = auth.apiAccessToken;
        if (token == null) return;
        await runTelegramLibrarySync(
          api: ref.read(tvAppApiServiceProvider),
          config: ref.read(appConfigProvider),
          tdlib: ref.read(tdlibFacadeProvider),
          accessToken: token,
          invalidateLibrary: () => ref.invalidate(mediaListProvider),
          mode: TelegramLibrarySyncMode.full,
        );
        await ref.read(mediaListProvider.future);
      },
      reloadLocatorAfterRecovery: (_, variantId) async {
        final items =
            await ref.read(mediaListProvider.future);
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
