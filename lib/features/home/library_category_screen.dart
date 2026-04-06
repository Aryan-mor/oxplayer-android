import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/app_media.dart';
import '../../providers.dart';
import '../../widgets/library_media_poster.dart';

String _titleForApiKind(String kind) {
  return switch (kind) {
    'movie' => 'Movies',
    'series' => 'Shows',
    'general_video' => 'Other',
    _ => kind,
  };
}

String _typeLabel(String type) {
  return switch (type) {
    'MOVIE' || '#movie' => 'Movie',
    'SERIES' || '#series' => 'Show',
    'GENERAL_VIDEO' => 'Video',
    _ => type,
  };
}

/// Full library grid for one API kind (5 columns). Route: `/library/:kind`.
class LibraryCategoryScreen extends ConsumerWidget {
  const LibraryCategoryScreen({super.key, required this.kind});

  final String kind;

  static const Set<String> validKinds = {'movie', 'series', 'general_video'};

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!validKinds.contains(kind)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Invalid category')),
        body: const Center(child: Text('Unknown library category.')),
      );
    }

    final title = _titleForApiKind(kind);
    final async = ref.watch(libraryMediaByKindProvider(kind));

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        foregroundColor: Colors.white,
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.pop(),
        ),
      ),
      body: async.when(
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Text(
                'No items in this category.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            );
          }
          return LayoutBuilder(
            builder: (context, c) {
              const gap = 10.0;
              const pad = 16.0;
              final w = c.maxWidth - pad * 2;
              const cols = 5;
              final cellW = (w - gap * (cols - 1)) / cols;
              final posterH = cellW * 1.5;
              final cellH = posterH + 52;
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(pad, 12, pad, 28),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  childAspectRatio: cellW / cellH,
                ),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  final m = item.media;
                  return _CategoryCell(
                    title: m.title,
                    typeLabel: _typeLabel(m.type),
                    media: m,
                    files: item.files,
                    onTap: () => context.push(
                      '/item/${Uri.encodeComponent(m.id)}',
                    ),
                  );
                },
              );
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Could not load category.\n$e',
              style: const TextStyle(color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

class _CategoryCell extends StatelessWidget {
  const _CategoryCell({
    required this.title,
    required this.typeLabel,
    required this.media,
    required this.files,
    required this.onTap,
  });

  final String title;
  final String typeLabel;
  final AppMedia media;
  final List<AppMediaFile> files;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.card,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: LibraryMediaPoster(
                media: media,
                files: files,
                placeholderIconSize: 32,
                progressStrokeWidth: 2,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    typeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
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
