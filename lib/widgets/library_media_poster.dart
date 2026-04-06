import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/media/app_media_poster_url.dart';
import '../core/media/local_video_thumbnail_service.dart';
import '../data/models/app_media.dart';
import '../providers.dart';

/// Library poster: remote TMDB/API image when present; otherwise a one-shot local
/// JPEG from the Telegram video (cached on disk; failures are remembered).
class LibraryMediaPoster extends ConsumerStatefulWidget {
  const LibraryMediaPoster({
    super.key,
    required this.media,
    required this.files,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.movie,
    this.placeholderIconSize = 40,
    this.progressStrokeWidth = 2,
  });

  final AppMedia media;
  final List<AppMediaFile> files;
  final BoxFit fit;
  final IconData placeholderIcon;
  final double placeholderIconSize;
  final double progressStrokeWidth;

  @override
  ConsumerState<LibraryMediaPoster> createState() => _LibraryMediaPosterState();
}

class _LibraryMediaPosterState extends ConsumerState<LibraryMediaPoster> {
  String? _localPath;
  bool _loadingLocal = false;

  @override
  void initState() {
    super.initState();
    _scheduleLocalIfNeeded();
  }

  @override
  void didUpdateWidget(covariant LibraryMediaPoster oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.media.id != widget.media.id) {
      _localPath = null;
      _loadingLocal = false;
      _scheduleLocalIfNeeded();
    }
  }

  void _scheduleLocalIfNeeded() {
    final remote = remotePosterUrlForAppMedia(widget.media);
    if (remote != null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_loadLocalPoster());
    });
  }

  Future<void> _loadLocalPoster() async {
    if (!mounted) return;
    final remote = remotePosterUrlForAppMedia(widget.media);
    if (remote != null) return;
    if (_loadingLocal) return;

    final auth = ref.read(authNotifierProvider);
    if (!auth.hasTelegramSession) return;

    final svc = LocalVideoThumbnailService.instance;
    await svc.ensureNegativeLoaded();
    if (!mounted) return;
    if (svc.isNegative(widget.media.id)) return;

    setState(() => _loadingLocal = true);

    final tdlib = ref.read(tdlibFacadeProvider);
    final file = await svc.ensurePosterFile(
      tdlib: tdlib,
      mediaId: widget.media.id,
      files: widget.files,
    );

    if (!mounted) return;
    setState(() {
      _loadingLocal = false;
      _localPath = file?.path;
    });
  }

  @override
  Widget build(BuildContext context) {
    final remote = remotePosterUrlForAppMedia(widget.media);
    if (remote != null) {
      return CachedNetworkImage(
        imageUrl: remote,
        fit: widget.fit,
        placeholder: (_, __) => Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: widget.progressStrokeWidth,
            ),
          ),
        ),
        errorWidget: (_, __, ___) => _placeholder(),
      );
    }

    final path = _localPath;
    if (path != null && path.isNotEmpty) {
      return Image.file(
        File(path),
        fit: widget.fit,
        errorBuilder: (_, __, ___) => _placeholder(),
      );
    }

    if (_loadingLocal) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: widget.progressStrokeWidth,
          ),
        ),
      );
    }

    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: Colors.black26,
      alignment: Alignment.center,
      child: Icon(widget.placeholderIcon, size: widget.placeholderIconSize),
    );
  }
}
