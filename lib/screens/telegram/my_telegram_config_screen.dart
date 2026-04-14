import 'package:flutter/material.dart';
import 'package:oxplayer/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../infrastructure/data_repository.dart';
import '../../infrastructure/telegram/source_chats_tdlib.dart';
import '../../i18n/strings.g.dart';

/// Pick TDLib dialogs and sync `showInVideo` to the OX API on explicit Save (Cancel discards).
class MyTelegramConfigScreen extends StatefulWidget {
  const MyTelegramConfigScreen({super.key});

  @override
  State<MyTelegramConfigScreen> createState() => _MyTelegramConfigScreenState();
}

class _MyTelegramConfigScreenState extends State<MyTelegramConfigScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _searchController = TextEditingController();

  final Map<int, TdlibPickerChatRow> _rowsByChatId = {};
  int _listLimit = 50;
  bool _loading = true;
  bool _loadingMore = false;
  bool _saving = false;
  String? _error;
  int? _selfUserId;

  /// Last loaded from server (committed).
  final Set<String> _serverShowInVideoIds = {};

  /// Editable selection; only pushed to server when user taps Save.
  final Set<String> _draftShowInVideoIds = {};

  String get _searchQuery => _searchController.text.trim().toLowerCase();

  SourceChatPickerBucket get _currentBucket =>
      SourceChatPickerBucket.values[_tabController.index];

  bool get _isDirty {
    if (_serverShowInVideoIds.length != _draftShowInVideoIds.length) return true;
    for (final id in _serverShowInVideoIds) {
      if (!_draftShowInVideoIds.contains(id)) return true;
    }
    return false;
  }

  List<TdlibPickerChatRow> get _visibleRows {
    final bucket = _currentBucket;
    final list = _rowsByChatId.values.where((r) => r.matchesBucket(bucket)).toList();
    if (bucket == SourceChatPickerBucket.chats) {
      list.sort((a, b) {
        if (a.isSavedMessages != b.isSavedMessages) {
          return a.isSavedMessages ? -1 : 1;
        }
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    } else {
      list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    return list;
  }

  List<TdlibPickerChatRow> get _filteredRows {
    final query = _searchQuery;
    if (query.isEmpty) return _visibleRows;
    return _visibleRows.where((row) => row.title.toLowerCase().contains(query)).toList();
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
    });
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {});
  }

  void _onSearchChanged(String _) {
    setState(() {});
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) return;
    _searchController.clear();
    setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadShowInVideoIds();
    await _loadChats(reset: true);
  }

  Future<void> _loadShowInVideoIds() async {
    try {
      final repo = await DataRepository.create();
      const buckets = ['chats', 'groups', 'supergroups', 'channels', 'bots'];
      final next = <String>{};
      const apiPageLimit = 200;
      for (final b in buckets) {
        try {
          var offset = 0;
          while (true) {
            final page = await repo.fetchUserChats(
              bucket: b,
              indexedOnly: false,
              showInVideoOnly: true,
              limit: apiPageLimit,
              offset: offset,
            );
            for (final r in page.items) {
              final id = r.tdlibChatId;
              if (id != null && id.isNotEmpty) next.add(id);
            }
            offset += page.items.length;
            if (page.items.isEmpty || offset >= page.total) break;
          }
        } catch (e, st) {
          debugPrint('MyTelegramConfig: load showInVideo ids bucket=$b failed: $e\n$st');
        }
      }
      if (mounted) {
        setState(() {
          _serverShowInVideoIds
            ..clear()
            ..addAll(next);
          _draftShowInVideoIds
            ..clear()
            ..addAll(next);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _serverShowInVideoIds.clear();
          _draftShowInVideoIds.clear();
        });
      }
    }
  }

  Future<void> _loadChats({required bool reset}) async {
    if (!mounted) return;
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _listLimit = 50;
        _rowsByChatId.clear();
      });
    } else {
      setState(() => _loadingMore = true);
    }
    final repo = await DataRepository.create();
    if (!mounted) return;
    final facade = repo.telegramTdlib;
    try {
      _selfUserId ??= await tdlibGetSelfUserId(facade);
      final self = _selfUserId!;
      if (reset) {
        await tdlibLoadChatsPage(facade, limit: 80);
      } else {
        await tdlibLoadChatsPage(facade, limit: 40);
        _listLimit += 40;
      }
      final ids = await tdlibGetMainChatIds(facade, _listLimit);
      for (final id in ids) {
        if (_rowsByChatId.containsKey(id)) continue;
        try {
          final chat = await tdlibGetChat(facade, id);
          if (chat == null) continue;
          final row = await tdlibBuildPickerRow(
            facade: facade,
            chat: chat,
            selfUserId: self,
            savedMessagesTitle: t.myTelegram.savedMessages,
          );
          if (row != null) {
            _rowsByChatId[id] = row;
          }
        } catch (e, st) {
          debugPrint('MyTelegramConfig: skip tdlib chat $id: $e\n$st');
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = '$e';
      });
    }
  }

  void _toggleRow(TdlibPickerChatRow row) {
    if (_saving) return;
    final idStr = row.chatId.toString();
    setState(() {
      if (_draftShowInVideoIds.contains(idStr)) {
        _draftShowInVideoIds.remove(idStr);
      } else {
        _draftShowInVideoIds.add(idStr);
      }
    });
  }

  Future<void> _onSavePressed() async {
    if (!_isDirty || _saving || _loading) return;
    setState(() => _saving = true);
    try {
      final repo = await DataRepository.create();
      final toOn = _draftShowInVideoIds.difference(_serverShowInVideoIds);
      final toOff = _serverShowInVideoIds.difference(_draftShowInVideoIds);

      final patchItems = <Map<String, dynamic>>[];

      for (final idStr in _draftShowInVideoIds) {
        final id = int.tryParse(idStr);
        if (id == null) continue;
        final row = _rowsByChatId[id];
        if (row == null) continue;
        await repo.upsertUserChatMapping(
          tdlibChatId: id,
          title: row.title,
          chatType: row.apiChatType,
          peerIsBot: row.peerIsBot,
          isForum: row.apiChatType == 'supergroup' && row.isForum,
        );
      }

      for (final idStr in toOn) {
        patchItems.add(<String, dynamic>{'tdlibChatId': idStr, 'showInVideo': true});
      }

      for (final idStr in toOff) {
        patchItems.add(<String, dynamic>{'tdlibChatId': idStr, 'showInVideo': false});
      }

      const chunkSize = 200;
      var patched = 0;
      for (var i = 0; i < patchItems.length; i += chunkSize) {
        final end = i + chunkSize > patchItems.length ? patchItems.length : i + chunkSize;
        patched += await repo.patchUserChatsShowInVideo(items: patchItems.sublist(i, end));
      }
      if (patchItems.isNotEmpty && patched == 0) {
        throw StateError('showInVideo patch updated 0 rows (check tdlibChatId / mapping)');
      }

      if (!mounted) return;
      setState(() {
        _serverShowInVideoIds
          ..clear()
          ..addAll(_draftShowInVideoIds);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t.myTelegram.saved)),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${t.myTelegram.saveFailed} ($e)')),
      );
    }
  }

  void _onCancelPressed() {
    if (_saving) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;
    final rows = _filteredRows;
    final hasSearch = _searchQuery.isNotEmpty;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: Text(mt.configTitle),
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: [
              Tab(text: mt.chatsTab),
              Tab(text: mt.groupsTab),
              Tab(text: mt.supergroupsTab),
              Tab(text: mt.channelsTab),
              Tab(text: mt.botsTab),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _loading || _saving ? null : _onCancelPressed,
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: _loading || _saving || !_isDirty ? null : _onSavePressed,
              child: _saving
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    )
                  : Text(mt.save),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              child: TextField(
                controller: _searchController,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: t.common.search,
                  prefixIcon: const Padding(
                    padding: EdgeInsetsDirectional.only(start: 12, end: 8),
                    child: AppIcon(Symbols.search_rounded, fill: 1),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                  suffixIcon: _searchController.text.isNotEmpty
                      ? IconButton(
                          tooltip: t.common.clear,
                          onPressed: _clearSearch,
                          icon: const AppIcon(Symbols.close_rounded, fill: 1),
                        )
                      : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const AppIcon(Symbols.search_rounded, fill: 1, size: 48),
                                const SizedBox(height: 16),
                                Text(hasSearch ? t.messages.noResultsFound : t.myTelegram.empty),
                                if (hasSearch) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    t.search.tryDifferentTerm,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            for (final row in rows)
                              SwitchListTile.adaptive(
                                secondary: CircleAvatar(
                                  child: Text(
                                    row.title.isNotEmpty ? row.title.substring(0, 1).toUpperCase() : '?',
                                  ),
                                ),
                                title: Text(row.title),
                                subtitle: Text(mt.showInVideo),
                                value: _draftShowInVideoIds.contains(row.chatId.toString()),
                                onChanged: _saving ? null : (_) => _toggleRow(row),
                              ),
                            if (_loadingMore)
                              const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: OutlinedButton.icon(
                                onPressed: _loadingMore || _saving ? null : () => _loadChats(reset: false),
                                icon: const AppIcon(Symbols.expand_more_rounded, fill: 1),
                                label: Text(mt.loadMore),
                              ),
                            ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}
