import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:oxplayer/widgets/app_icon.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../infrastructure/data_repository.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/refreshable.dart';
import 'my_telegram_config_screen.dart';

/// Main "My Telegram" hub: four buckets of server-side dialogs with `showInVideo`.
class MyTelegramScreen extends StatefulWidget {
  const MyTelegramScreen({super.key});

  @override
  State<MyTelegramScreen> createState() => _MyTelegramScreenState();
}

class _MyTelegramScreenState extends State<MyTelegramScreen>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin, FocusableTab {
  late TabController _tabController;

  @override
  bool get wantKeepAlive => true;

  @override
  void focusActiveTabIfReady() {}

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openConfig() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (context) => const MyTelegramConfigScreen()),
    );
    if (mounted) setState(() {});
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
            Tab(text: mt.channelsTab),
            Tab(text: mt.botsTab),
          ],
        ),
        actions: [
          IconButton(
            tooltip: mt.config,
            icon: const AppIcon(Symbols.tune_rounded, fill: 1),
            onPressed: _openConfig,
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _MyTelegramBucketList(bucket: 'chats'),
          _MyTelegramBucketList(bucket: 'groups'),
          _MyTelegramBucketList(bucket: 'channels'),
          _MyTelegramBucketList(bucket: 'bots'),
        ],
      ),
    );
  }
}

class _MyTelegramBucketList extends StatefulWidget {
  const _MyTelegramBucketList({required this.bucket});

  final String bucket;

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
    if (oldWidget.bucket != widget.bucket) {
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
    return repo.fetchUserChats(
      bucket: widget.bucket,
      indexedOnly: false,
      showInVideoOnly: true,
      limit: 200,
    );
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
                FilledButton(
                  onPressed: _reload,
                  child: Text(t.common.retry),
                ),
              ],
            ),
          );
        }
        final page = snapshot.data ?? const OxUserChatListPage(items: [], total: 0);
        if (page.items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                t.myTelegram.empty,
                textAlign: TextAlign.center,
              ),
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
              return ListTile(
                leading: _ChatAvatar(photoUrl: row.photoUrl, title: row.title),
                title: Text(row.title),
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
