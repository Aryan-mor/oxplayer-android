import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/focus/focusable_wrapper.dart';
import '../../core/focus/input_mode_tracker.dart';
import '../../models/app_media.dart';
import '../../providers.dart';
import '../../widgets/library_media_poster.dart';
import '../../widgets/telegram_file_playback_actions.dart';
import 'detail_presentation_adapter.dart';

class SingleItemScreen extends ConsumerStatefulWidget {
  const SingleItemScreen({
    super.key,
    required this.globalId,
    this.preloadedAggregate,
  });

  final String globalId;
  final AppMediaAggregate? preloadedAggregate;

  @override
  ConsumerState<SingleItemScreen> createState() => _SingleItemScreenState();
}

class _SingleItemScreenState extends ConsumerState<SingleItemScreen> {
  final ScrollController _scrollController = ScrollController();
  final FocusNode _backFocus = FocusNode(debugLabel: 'detail_back');
  AppMediaAggregate? _aggregate;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    if (widget.preloadedAggregate != null) {
      _aggregate = widget.preloadedAggregate;
      _loading = false;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _backFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final auth = ref.read(authNotifierProvider);
    final token = auth.apiAccessToken;
    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Not signed in.';
      });
      return;
    }
    final api = ref.read(oxplayerApiServiceProvider);
    final cfg = ref.read(appConfigProvider);
    try {
      final detail = await api.fetchLibraryMediaDetail(
        config: cfg,
        accessToken: token,
        mediaId: widget.globalId,
      );
      if (!mounted) return;
      if (detail == null) {
        setState(() {
          _loading = false;
          _error = 'Media not found.';
        });
        return;
      }
      setState(() {
        _aggregate = detail;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return InputModeTracker(
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error.isNotEmpty
                  ? Center(child: Text(_error))
                  : CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                            child: _buildBackButton(context),
                          ),
                        ),
                        SliverToBoxAdapter(child: _buildHero(context)),
                        SliverToBoxAdapter(child: _buildPlaybackSection(context)),
                        const SliverToBoxAdapter(child: SizedBox(height: 24)),
                      ],
                    ),
        ),
      ),
    );
  }

  Widget _buildBackButton(BuildContext context) {
    return FocusableWrapper(
      autofocus: true,
      focusNode: _backFocus,
      descendantsAreFocusable: false,
      onSelect: () => context.pop(),
      child: InkWell(
        onTap: () => context.pop(),
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_back_rounded, size: 18),
              SizedBox(width: 8),
              Text('Back'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(BuildContext context) {
    final aggregate = _aggregate!;
    final vm = DetailPresentationAdapter.fromAggregate(aggregate);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).colorScheme.outline),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 220,
              child: AspectRatio(
                aspectRatio: 2 / 3,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LibraryMediaPoster(
                    media: aggregate.media,
                    files: aggregate.files,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    vm.title,
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  if (vm.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(vm.subtitle, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.75))),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    aggregate.media.summary?.trim().isNotEmpty == true ? aggregate.media.summary! : 'No overview available.',
                    style: const TextStyle(height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaybackSection(BuildContext context) {
    final aggregate = _aggregate!;
    if (aggregate.files.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text('No files indexed yet.'),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Playback', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: aggregate.files.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final file = aggregate.files[index];
              final label = (file.quality ?? '').isNotEmpty ? file.quality! : 'Default quality';
              return FocusableWrapper(
                onSelect: () => _openPlaybackActions(context, aggregate, file),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openPlaybackActions(context, aggregate, file),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Theme.of(context).colorScheme.outline),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.play_circle_outline_rounded),
                        const SizedBox(width: 10),
                        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _openPlaybackActions(BuildContext context, AppMediaAggregate aggregate, AppMediaFile file) {
    showModalBottomSheet<void>(
      context: context,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TelegramFilePlaybackActions(
              media: aggregate.media,
              file: file,
              downloadGlobalId: file.id,
              downloadTitle: aggregate.media.title,
            ),
          ),
        );
      },
    );
  }
}


