import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:oxplayer/widgets/app_icon.dart';

import '../../i18n/strings.g.dart';
import '../../infrastructure/data_repository.dart';
import '../../mixins/refreshable.dart';
import 'my_telegram_chat_media_screen.dart';
import 'my_telegram_config_screen.dart';
import 'my_telegram_forum_topics_screen.dart';

/// Main "My Telegram" hub: buckets of server-side dialogs with `showInVideo`.
class MyTelegramScreen extends StatefulWidget {
  const MyTelegramScreen({super.key});

  @override
  State<MyTelegramScreen> createState() => _MyTelegramScreenState();
}

class _MyTelegramScreenState extends State<MyTelegramScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin, FocusableTab {
  late TabController _tabController;

  /// Bumped after Configure closes so bucket lists refetch `showInVideo` from the API.
  int _listGeneration = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void focusActiveTabIfReady() {}

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openConfig() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (context) => const MyTelegramConfigScreen()));
    if (!mounted) return;
    setState(() => _listGeneration++);
    if (saved == true) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.myTelegram.savedCheckOtherTabsHint)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final mt = t.myTelegram;
    return Scaffold(
      appBar: AppBar(
        title: Text(mt.title),
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
          IconButton(tooltip: mt.config, icon: const AppIcon(Symbols.tune_rounded, fill: 1), onPressed: _openConfig),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _MyTelegramBucketList(
            key: ValueKey<String>('mt_chats_$_listGeneration'),
            bucket: 'chats',
            listGeneration: _listGeneration,
          ),
          _MyTelegramBucketList(
            key: ValueKey<String>('mt_groups_$_listGeneration'),
            bucket: 'groups',
            listGeneration: _listGeneration,
          ),
          _MyTelegramBucketList(
            key: ValueKey<String>('mt_supergroups_$_listGeneration'),
            bucket: 'supergroups',
            listGeneration: _listGeneration,
          ),
          _MyTelegramBucketList(
            key: ValueKey<String>('mt_channels_$_listGeneration'),
            bucket: 'channels',
            listGeneration: _listGeneration,
          ),
          _MyTelegramBucketList(
            key: ValueKey<String>('mt_bots_$_listGeneration'),
            bucket: 'bots',
            listGeneration: _listGeneration,
          ),
        ],
      ),
    );
  }
}

class _MyTelegramBucketList extends StatefulWidget {
  const _MyTelegramBucketList({super.key, required this.bucket, required this.listGeneration});

  final String bucket;
  final int listGeneration;

  @override
  State<_MyTelegramBucketList> createState() => _MyTelegramBucketListState();
}

class _MyTelegramBucketListState extends State<_MyTelegramBucketList> {
  Future<OxUserChatListPage>? _future;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void didUpdateWidget(covariant _MyTelegramBucketList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bucket != widget.bucket || oldWidget.listGeneration != widget.listGeneration) {
      _reload();
    }
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<OxUserChatListPage> _load() async {
    final repo = await DataRepository.create();
    return repo.fetchUserChats(bucket: widget.bucket, indexedOnly: false, showInVideoOnly: true, limit: 200);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<OxUserChatListPage>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t.myTelegram.loadError),
                const SizedBox(height: 12),
                FilledButton(onPressed: _reload, child: Text(t.common.retry)),
              ],
            ),
          );
        }
        final page = snapshot.data ?? const OxUserChatListPage(items: [], total: 0);
        if (page.items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(t.myTelegram.empty, textAlign: TextAlign.center),
            ),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            final next = _load();
            setState(() => _future = next);
            await next;
          },
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: page.items.length,
            separatorBuilder: (context, index) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final row = page.items[index];
              final tdlib = row.tdlibChatId?.trim();
              return ListTile(
                leading: _ChatAvatar(photoUrl: row.photoUrl, title: row.title),
                title: Text(row.title),
                subtitle: row.isIndexed ? Text(t.myTelegram.indexedForLibrary) : null,
                trailing: row.isIndexed && tdlib != null && tdlib.isNotEmpty
                    ? const AppIcon(Symbols.chevron_right_rounded, fill: 1)
                    : null,
                onTap: () {
                  if (tdlib == null || tdlib.isEmpty) return;
                  if (row.chatType == 'supergroup' && row.isForum) {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) => MyTelegramForumTopicsScreen(
                          chatTitle: row.title,
                          tdlibChatId: tdlib,
                          libraryIndexed: row.isIndexed,
                        ),
                      ),
                    );
                  } else {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (context) => MyTelegramChatMediaScreen(chatTitle: row.title, tdlibChatId: tdlib),
                      ),
                    );
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _ChatAvatar extends StatelessWidget {
  const _ChatAvatar({required this.photoUrl, required this.title});

  final String? photoUrl;
  final String title;

  @override
  Widget build(BuildContext context) {
    final url = photoUrl?.trim();
    if (url != null && url.isNotEmpty) {
      return CircleAvatar(
        child: ClipOval(
          child: CachedNetworkImage(
            imageUrl: url,
            width: 40,
            height: 40,
            fit: BoxFit.cover,
            errorWidget: (context, url, error) => _Initials(title),
          ),
        ),
      );
    }
    return _Initials(title);
  }
}

class _Initials extends StatelessWidget {
  const _Initials(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final letter = title.isNotEmpty ? title.substring(0, 1).toUpperCase() : '?';
    return CircleAvatar(child: Text(letter));
  }
}
