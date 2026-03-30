import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/auth/auth_notifier.dart';
import 'core/config/app_config.dart';
import 'data/api/tv_app_api_service.dart';
import 'data/models/app_media.dart';
import 'data/local/telegram_session_store.dart';
import 'data/tmdb/tmdb_repository.dart';
import 'download/download_manager.dart';
import 'telegram/tdlib_controller.dart';
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
      if (!auth.isLoggedIn) return;
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
  return api.fetchLibrary(config: config, accessToken: authNotifier.apiAccessToken!);
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
    final dm = DownloadManager(tdlib: tdlib);
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
