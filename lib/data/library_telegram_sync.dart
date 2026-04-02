import 'package:shared_preferences/shared_preferences.dart';

import '../core/debug/app_debug_log.dart';
import '../core/sync_prefs.dart';
import '../telegram/tdlib_facade.dart';
import 'api/discovery_media_ids_store.dart';
import 'api/discovery_refs_store.dart';
import 'api/tv_app_api_service.dart';
import '../core/config/app_config.dart';

void _synclog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.sync);

/// How aggressively Telegram [searchMessages] is filtered by date.
enum TelegramLibrarySyncMode {
  incremental,
  full,
}

/// Telegram hashtag discovery + [DiscoveryRefsStore] merge + POST [/me/sync].
Future<void> runTelegramLibrarySync({
  required TvAppApiService api,
  required AppConfig config,
  required TdlibFacade tdlib,
  required String accessToken,
  required void Function() invalidateLibrary,
  TelegramLibrarySyncMode mode = TelegramLibrarySyncMode.incremental,
}) async {
  final libraryFetch = await api.fetchLibrary(
    config: config,
    accessToken: accessToken,
  );
  final currentLibrary = libraryFetch.items;

  final existingFileIds = currentLibrary
      .expand((agg) => agg.files)
      .map((f) => f.id)
      .toSet();

  DateTime? minMessageDateUtc;
  if (mode == TelegramLibrarySyncMode.incremental && currentLibrary.isNotEmpty) {
    final prefs = await SharedPreferences.getInstance();
    final localMs = prefs.getInt(kSyncIndexWatermarkPrefsKey);
    final localW = localMs != null
        ? DateTime.fromMillisecondsSinceEpoch(localMs, isUtc: true)
        : null;
    minMessageDateUtc = libraryFetch.lastIndexedAt;
    if (localW != null) {
      if (minMessageDateUtc == null || localW.isAfter(minMessageDateUtc)) {
        minMessageDateUtc = localW;
      }
    }
    _synclog(
      'LibrarySync: minDate watermark=$minMessageDateUtc '
      '(server=${libraryFetch.lastIndexedAt} local=$localW)',
    );
  } else if (mode == TelegramLibrarySyncMode.full) {
    _synclog('LibrarySync: full Telegram search (no minDate)');
  }

  _synclog('LibrarySync: scanning Telegram…');
  await api.collectMediaFileIdsFromTelegram(
    tdlib: tdlib,
    config: config,
    minMessageDateUtc: minMessageDateUtc,
    onBatch: (discoveredRefs, discoveredMediaIds) async {
      await DiscoveryRefsStore.merge(discoveredRefs);
      await DiscoveryMediaIdsStore.merge(discoveredMediaIds);
      _synclog(
        'LibrarySync: discovery batch refs=${discoveredRefs.length} '
        'mediaIds=${discoveredMediaIds.length}',
      );
    },
  );

  await DiscoveryRefsStore.pruneLegacyUuidKeys();
  await DiscoveryMediaIdsStore.pruneInvalid();
  final persistedRefs = await DiscoveryRefsStore.loadAll();
  final persistedMediaIds = (await DiscoveryMediaIdsStore.loadAll()).toList(growable: false);
  if (persistedRefs.isEmpty && persistedMediaIds.isEmpty) {
    _synclog('LibrarySync: discovery store empty, sync skipped');
    invalidateLibrary();
    return;
  }

  _synclog(
    'LibrarySync: syncing ${persistedRefs.length} ref(s), ${persistedMediaIds.length} mediaId(s)',
  );
  final syncResult = await api.syncLibrary(
    config: config,
    accessToken: accessToken,
    mediaFileIds: persistedRefs.map((r) => r.mediaFileId).toList(growable: false),
    mediaIds: persistedMediaIds.isEmpty ? null : persistedMediaIds,
    refs: persistedRefs.isEmpty ? null : persistedRefs,
  );
  final w = syncResult.lastIndexedAt;
  if (w != null) {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kSyncIndexWatermarkPrefsKey,
      w.toUtc().millisecondsSinceEpoch,
    );
  }
  existingFileIds.addAll(persistedRefs.map((r) => r.mediaFileId));
  invalidateLibrary();
}
