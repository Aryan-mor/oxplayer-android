import 'package:flutter/material.dart';

import '../../infrastructure/data_repository.dart';
import '../../infrastructure/telegram/source_chats_tdlib.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import 'my_telegram_chat_media_screen.dart';

/// Forum supergroup: horizontal topic tabs — indexed chats use API media per topic; others use TDLib video search for that thread.
class MyTelegramForumTopicsScreen extends StatefulWidget {
  const MyTelegramForumTopicsScreen({
    super.key,
    required this.chatTitle,
    required this.tdlibChatId,
    this.libraryIndexed = false,
  });

  final String chatTitle;
  final String tdlibChatId;

  /// When true, each tab lists `GET /me/chats/.../media?messageThreadId=` for that topic.
  final bool libraryIndexed;

  @override
  State<MyTelegramForumTopicsScreen> createState() => _MyTelegramForumTopicsScreenState();
}

class _MyTelegramForumTopicsScreenState extends State<MyTelegramForumTopicsScreen>
    with SingleTickerProviderStateMixin {
  TabController? _tabController;

  /// First entry is always global forum search (`message_thread_id` 0); then each [ForumTopic].
  List<({int messageThreadId, String title})> _tabEntries = const [];
  bool _loading = true;
  String? _error;

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = int.tryParse(widget.tdlibChatId.trim());
    if (id == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Invalid chat id';
        });
      }
      return;
    }
    try {
      final repo = await DataRepository.create();
      final topics = await tdlibLoadAllForumTopics(repo.telegramTdlib, id);
      if (!mounted) return;
      final mt = t.myTelegram;
      final entries = <({int messageThreadId, String title})>[
        (messageThreadId: 0, title: mt.forumAllVideosTab),
        for (final topic in topics)
          (
            messageThreadId: topic.info.messageThreadId,
            title: topic.info.name.trim().isEmpty ? '…' : topic.info.name.trim(),
          ),
      ];
      _tabController?.dispose();
      _tabController = TabController(length: entries.length, vsync: this);
      setState(() {
        _tabEntries = entries;
        _loading = false;
        _error = null;
      });
    } catch (e, st) {
      if (!mounted) return;
      final detail = describeTdlibError(e);
      appLogger.e('MyTelegram forum topics load failed chatId=$id', error: detail, stackTrace: st);
      setState(() {
        _loading = false;
        _error = detail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mt = t.myTelegram;
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.chatTitle)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.chatTitle)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(mt.forumTopicsLoadError),
                const SizedBox(height: 8),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    _load();
                  },
                  child: Text(t.common.retry),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final tc = _tabController!;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.chatTitle),
        bottom: TabBar(
          controller: tc,
          isScrollable: true,
          tabs: [for (final e in _tabEntries) Tab(text: e.title)],
        ),
      ),
      body: TabBarView(
        controller: tc,
        children: [
          for (final e in _tabEntries)
            MyTelegramChatMediaScreen(
              key: ValueKey<String>('${widget.tdlibChatId}_${e.messageThreadId}_${widget.libraryIndexed}'),
              chatTitle: e.title,
              tdlibChatId: widget.tdlibChatId,
              messageThreadId: e.messageThreadId,
              embedInTabView: true,
              libraryIndexed: widget.libraryIndexed,
            ),
        ],
      ),
    );
  }
}
