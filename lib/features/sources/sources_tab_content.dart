import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/theme/oxplayer_button.dart';
import '../../models/user_chat_dtos.dart';
import '../../providers.dart';

/// Home "Sources" tab: indexed chats from the API, four buckets, opens chat media grid.
class SourcesTabContent extends ConsumerStatefulWidget {
  const SourcesTabContent({
    super.key,
    required this.sourcesNavFocus,
  });

  final FocusNode sourcesNavFocus;

  @override
  ConsumerState<SourcesTabContent> createState() => SourcesTabContentState();
}

class SourcesTabContentState extends ConsumerState<SourcesTabContent> {
  static const int _cols = 5;
  static const List<String> _buckets = [
    'chats',
    'groups',
    'channels',
    'bots',
  ];

  int _bucketIndex = 0;
  final List<FocusNode> _focusNodes = <FocusNode>[];
  int? _focusedIndex;
  int? _lastItemCount;

  @override
  void dispose() {
    for (final n in _focusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncFocusNodes(int count) {
    while (_focusNodes.length < count) {
      _focusNodes.add(FocusNode(debugLabel: 'sources-grid-${_focusNodes.length}'));
    }
    while (_focusNodes.length > count) {
      _focusNodes.removeLast().dispose();
    }
  }

  int? get lastBuiltItemCount => _lastItemCount;

  bool focusGridIndex(int index) {
    final n = _lastItemCount;
    if (n == null || n <= 0 || index < 0 || index >= n) return false;
    _syncFocusNodes(n);
    setState(() => _focusedIndex = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (index < _focusNodes.length) {
        _focusNodes[index].requestFocus();
      }
    });
    return true;
  }

  void focusFirstGridTile() {
    void attempt(int n) {
      if (!mounted) return;
      if (focusGridIndex(0)) return;
      if (n < 15) {
        WidgetsBinding.instance.addPostFrameCallback((_) => attempt(n + 1));
      }
    }

    attempt(0);
  }

  void _moveGridFocus(int newIndex, int total) {
    if (newIndex < 0 || newIndex >= total) return;
    setState(() => _focusedIndex = newIndex);
    if (newIndex < _focusNodes.length) {
      _focusNodes[newIndex].requestFocus();
    }
  }

  KeyEventResult _gridKeyHandler(
    int index,
    List<UserChatRow> items,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final total = items.length;
    const cols = _cols;
    final row = index ~/ cols;
    final col = index % cols;
    final k = event.logicalKey;

    if (_focusedIndex != index) {
      setState(() => _focusedIndex = index);
    }

    if (k == LogicalKeyboardKey.arrowLeft) {
      if (col > 0) _moveGridFocus(index - 1, total);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (col < cols - 1 && index + 1 < total) {
        _moveGridFocus(index + 1, total);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (row > 0) {
        _moveGridFocus(index - cols, total);
      } else {
        widget.sourcesNavFocus.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (index + cols < total) {
        _moveGridFocus(index + cols, total);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.space) {
      ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
            mainTab: 1,
            gridIndex: index,
          );
      final chat = items[index];
      final tid = int.tryParse(chat.telegramChatId) ?? 0;
      final last = chat.lastIndexedMessageId ?? '';
      context.push(
        '/sources/chat/$tid?title=${Uri.encodeComponent(chat.title)}'
        '${last.isNotEmpty ? '&lastMsg=${Uri.encodeComponent(last)}' : ''}',
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _bucketLabel(String b) {
    switch (b) {
      case 'chats':
        return 'Chats';
      case 'groups':
        return 'Groups';
      case 'channels':
        return 'Channels';
      case 'bots':
        return 'Bots';
      default:
        return b;
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final token = auth.apiAccessToken;
    final bucket = _buckets[_bucketIndex.clamp(0, _buckets.length - 1)];
    final async = ref.watch(indexedChatsForBucketProvider(bucket));

    if (token == null || token.isEmpty) {
      return const Center(
        child: Text(
          'Sign in to manage Telegram sources.',
          style: TextStyle(color: AppColors.textMuted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppLayout.tvHorizontalInset,
            10,
            AppLayout.tvHorizontalInset,
            6,
          ),
          child: Row(
            children: [
              OxplayerButton(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                borderRadius: 8,
                onPressed: () => context.push('/sources/picker'),
                child: const Text(
                  'Select sources',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppLayout.tvHorizontalInset,
            0,
            AppLayout.tvHorizontalInset,
            8,
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < _buckets.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  OxplayerButton(
                    selected: _bucketIndex == i,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    borderRadius: 8,
                    onPressed: () => setState(() => _bucketIndex = i),
                    child: Text(
                      _bucketLabel(_buckets[i]),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: async.when(
            data: (page) {
              final items = page.items;
              if (items.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'No sources in this tab yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 20),
                        OxplayerButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          borderRadius: 10,
                          onPressed: () => context.push('/sources/picker'),
                          child: const Text(
                            'Choose sources',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final n = items.length;
              _lastItemCount = n;
              _syncFocusNodes(n);
              if (_focusedIndex != null && _focusedIndex! >= n) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() => _focusedIndex = null);
                });
              }
              return LayoutBuilder(
                builder: (context, c) {
                  const gap = 10.0;
                  final pad = AppLayout.tvHorizontalInset;
                  final w = c.maxWidth - pad * 2;
                  final cellW = (w - gap * (_cols - 1)) / _cols;
                  final avatarR = cellW * 0.28;
                  final cellH = avatarR * 2 + 56;
                  return GridView.builder(
                    padding: EdgeInsets.fromLTRB(
                      pad,
                      4,
                      pad,
                      AppLayout.screenBottomInset + AppLayout.tvSectionVerticalGap,
                    ),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _cols,
                      mainAxisSpacing: gap,
                      crossAxisSpacing: gap,
                      childAspectRatio: cellW / cellH,
                    ),
                    itemCount: n,
                    itemBuilder: (context, index) {
                      final row = items[index];
                      final focused = _focusedIndex == index;
                      return Focus(
                        focusNode: _focusNodes[index],
                        onFocusChange: (hasFocus) {
                          if (hasFocus) {
                            ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
                                  mainTab: 1,
                                  gridIndex: index,
                                );
                            if (_focusedIndex != index) {
                              setState(() => _focusedIndex = index);
                            }
                            return;
                          }
                          if (_focusedIndex == index) {
                            setState(() => _focusedIndex = null);
                          }
                        },
                        onKeyEvent: (_, e) => _gridKeyHandler(index, items, e),
                        child: Material(
                          color: AppColors.card,
                          borderRadius: BorderRadius.circular(12),
                          elevation: focused ? 6 : 0,
                          clipBehavior: Clip.antiAlias,
                          child: InkWell(
                            onTap: () {
                              ref.read(homeBrowseFocusProvider.notifier).setSourcesGridFocus(
                                    mainTab: 1,
                                    gridIndex: index,
                                  );
                              final tid = int.tryParse(row.telegramChatId) ?? 0;
                              final last = row.lastIndexedMessageId ?? '';
                              context.push(
                                '/sources/chat/$tid?title=${Uri.encodeComponent(row.title)}'
                                '${last.isNotEmpty ? '&lastMsg=${Uri.encodeComponent(last)}' : ''}',
                              );
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                children: [
                                  CircleAvatar(
                                    radius: avatarR.clamp(22, 40),
                                    backgroundColor: AppColors.border,
                                    backgroundImage: row.photoUrl != null &&
                                            row.photoUrl!.trim().startsWith('http')
                                        ? NetworkImage(row.photoUrl!.trim())
                                        : null,
                                    child: row.photoUrl == null ||
                                            !row.photoUrl!.trim().startsWith('http')
                                        ? Text(
                                            row.title.isNotEmpty
                                                ? row.title[0].toUpperCase()
                                                : '?',
                                            style: TextStyle(
                                              fontSize: avatarR.clamp(22, 40) * 0.9,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          )
                                        : null,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    row.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: focused ? 12 : 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Text(
                'Could not load sources.\n$e',
                style: const TextStyle(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

