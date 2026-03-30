import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import 'core/auth/auth_notifier.dart';
import 'core/config/app_config.dart';
import 'data/api/tv_app_api_service.dart';
import 'data/local/entities.dart';
import 'data/local/isar_provider.dart';
import 'data/local/telegram_session_store.dart';
import 'data/tmdb/tmdb_repository.dart';
import 'download/download_manager.dart';
import 'telegram/tdlib_controller.dart';
import 'telegram/tdlib_facade.dart';
import 'sync/sync_engine.dart';

final appConfigProvider = Provider<AppConfig>((ref) => AppConfig.fromEnv());
final tvAppApiServiceProvider =
    Provider<TvAppApiService>((ref) => TvAppApiService());

enum LibraryTypeFilter { all, movies, series }

class SourceFilterOption {
  const SourceFilterOption({
    required this.id,
    required this.label,
  });

  final int id;
  final String label;
}

/// Single TDLib JSON client for the app (Android / desktop; not used on web)
final tdlibFacadeProvider = Provider<TdlibFacade>((ref) {
  final facade = TelegramTdlibFacade(
    onUserAuthorized: (user) async {
      final isar = await ref.read(isarProvider.future);
      await isar.runWithRetry(() => putTelegramSessionFromUser(isar, user),
          debugName: 'putSession');
      await ref.read(authNotifierProvider).setSession('tdlib:${user.id}');
    },
    onRequiresInteractiveLogin: () async {
      final auth = ref.read(authNotifierProvider);
      if (!auth.isLoggedIn) return;
      final isar = await ref.read(isarProvider.future);
      await isar.runWithRetry(() => auth.clearTelegramIsarSession(isar),
          debugName: 'clearSession');
    },
  );
  ref.onDispose(() {
    unawaited(facade.dispose());
  });
  return facade;
});

final syncEngineProvider = FutureProvider<SyncEngine>((ref) async {
  final isar = await ref.watch(isarProvider.future);
  return SyncEngine(isar);
});

final authNotifierProvider = ChangeNotifierProvider<AuthNotifier>((ref) {
  return AuthNotifier();
});

final tmdbRepositoryProvider = Provider<TmdbRepository?>((ref) {
  return TmdbRepository();
});

final mediaListProvider = FutureProvider<List<MediaItem>>((ref) async {
  final isar = await ref.watch(isarProvider.future);
  return isar.runWithRetry(() async {
    final all = await isar.mediaItems.where().findAll();
    all.sort((a, b) => b.lastSyncedAt.compareTo(a.lastSyncedAt));
    return all;
  }, debugName: 'mediaList');
});

final selectedTypeFilterProvider =
    StateProvider<LibraryTypeFilter>((ref) => LibraryTypeFilter.all);
final selectedSourceFilterProvider = StateProvider<int?>((ref) => null);
final lastFocusedGridIndexProvider = StateProvider<int>((ref) => 0);

final sourceFilterOptionsProvider = Provider<List<SourceFilterOption>>((ref) {
  final media = ref.watch(mediaListProvider).valueOrNull ?? const <MediaItem>[];
  final ids = media.map((m) => m.mediaSourceId).toSet().toList()..sort();
  return ids
      .map(
        (id) => SourceFilterOption(
          id: id,
          label: id == 0 ? 'Unknown Source' : 'Source $id',
        ),
      )
      .toList();
});

final filteredMediaProvider = Provider<List<MediaItem>>((ref) {
  final media = ref.watch(mediaListProvider).valueOrNull ?? const <MediaItem>[];
  final typeFilter = ref.watch(selectedTypeFilterProvider);
  final sourceFilter = ref.watch(selectedSourceFilterProvider);

  return media.where((item) {
    final byType = switch (typeFilter) {
      LibraryTypeFilter.all => true,
      LibraryTypeFilter.movies => item.mediaType == '#movie',
      LibraryTypeFilter.series => item.mediaType == '#series',
    };
    final bySource =
        sourceFilter == null ? true : item.mediaSourceId == sourceFilter;
    return byType && bySource;
  }).toList();
});

final downloadsListProvider = FutureProvider<List<MediaDownload>>((ref) async {
  final isar = await ref.watch(isarProvider.future);
  return isar.runWithRetry(() async {
    final all = await isar.mediaDownloads.where().findAll();
    all.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return all;
  }, debugName: 'downloadsList');
});

/// Global [DownloadManager] — resolves once [isarProvider] is ready.
final downloadManagerProvider =
    AsyncNotifierProvider<_DownloadManagerNotifier, DownloadManager>(
  _DownloadManagerNotifier.new,
);

class _DownloadManagerNotifier extends AsyncNotifier<DownloadManager> {
  @override
  Future<DownloadManager> build() async {
    final isar = await ref.watch(isarProvider.future);
    final tdlib = ref.watch(tdlibFacadeProvider);
    final dm = DownloadManager(tdlib: tdlib, isar: isar);
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
