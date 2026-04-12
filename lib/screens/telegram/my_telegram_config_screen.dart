import 'dart:async';

import 'package:flutter/material.dart';
import 'package:oxplayer/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../infrastructure/data_repository.dart';
import '../../infrastructure/telegram/source_chats_tdlib.dart';
import '../../i18n/strings.g.dart';

/// Pick TDLib dialogs and sync `showInVideo` to the OX API (upsert + PATCH).
class MyTelegramConfigScreen extends StatefulWidget {
  const MyTelegramConfigScreen({super.key});

  @override
  State<MyTelegramConfigScreen> createState() => _MyTelegramConfigScreenState();
}

class _MyTelegramConfigScreenState extends State<MyTelegramConfigScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  final Map<int, TdlibPickerChatRow> _rowsByChatId = {};
  int _listLimit = 50;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int? _selfUserId;
  final Set<String> _showInVideoTdlibIds = {};

  Timer? _debounce;
  final Map<int, bool> _pendingShowInVideo = {};

  SourceChatPickerBucket get _currentBucket =>
      SourceChatPickerBucket.values[_tabController.index];

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

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(_onTabChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_bootstrap());
    });
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {});
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_pendingShowInVideo.isNotEmpty) {
      unawaited(_flushPending());
    }
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _loadShowInVideoIds();
    await _loadChats(reset: true);
  }

  Future<void> _loadShowInVideoIds() async {
    try {
      final repo = await DataRepository.create();
      const buckets = ['chats', 'groups', 'channels', 'bots'];
      final next = <String>{};
      for (final b in buckets) {
        try {
          final page = await repo.fetchUserChats(
            bucket: b,
            indexedOnly: false,
            showInVideoOnly: true,
            limit: 500,
          );
          for (final r in page.items) {
            final id = r.tdlibChatId;
            if (id != null && id.isNotEmpty) next.add(id);
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _showInVideoTdlibIds
            ..clear()
            ..addAll(next);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadChats({required bool reset}) async {
    final repo = await DataRepository.create();
    final facade = repo.telegramTdlib;
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
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = '$e';
        });
      }
    }
  }

  void _scheduleFlush() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _flushPending);
  }

  Future<void> _flushPending() async {
    if (_pendingShowInVideo.isEmpty) return;
    final copy = Map<int, bool>.from(_pendingShowInVideo);
    _pendingShowInVideo.clear();

    try {
      final repo = await DataRepository.create();
      for (final id in copy.keys) {
        final row = _rowsByChatId[id];
        if (row == null) continue;
        await repo.upsertUserChatMapping(
          tdlibChatId: id,
          title: row.title,
          chatType: row.apiChatType,
          peerIsBot: row.peerIsBot,
        );
      }
      final items = copy.entries
          .map(
            (e) => <String, dynamic>{
              'tdlibChatId': e.key,
              'showInVideo': e.value,
            },
          )
          .toList();
      await repo.patchUserChatsShowInVideo(items: items);
    } catch (_) {}
  }

  void _toggleRow(TdlibPickerChatRow row) {
    final idStr = row.chatId.toString();
    final isOn = !_showInVideoTdlibIds.contains(idStr);
    setState(() {
      if (isOn) {
        _showInVideoTdlibIds.add(idStr);
      } else {
        _showInVideoTdlibIds.remove(idStr);
      }
      _pendingShowInVideo[row.chatId] = isOn;
    });
    _scheduleFlush();
  }

  Future<void> _onSavePressed() async {
    await _flushPending();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t.myTelegram.saved)),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;
    final rows = _visibleRows;
    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          unawaited(_flushPending());
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(mt.configTitle),
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: [
              Tab(text: mt.chatsTab),
              Tab(text: mt.groupsTab),
              Tab(text: mt.channelsTab),
              Tab(text: mt.botsTab),
            ],
          ),
          actions: [
            TextButton(
              onPressed: _loading ? null : _onSavePressed,
              child: Text(mt.save),
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
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
                            value: _showInVideoTdlibIds.contains(row.chatId.toString()),
                            onChanged: (_) => _toggleRow(row),
                          ),
                        if (_loadingMore)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Center(child: CircularProgressIndicator()),
                          ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: OutlinedButton.icon(
                            onPressed: _loadingMore ? null : () => _loadChats(reset: false),
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
