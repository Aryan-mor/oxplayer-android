import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:oxplayer/infrastructure/subtitles/subdl_service.dart';
import 'package:oxplayer/mpv/mpv.dart';

import '../../../i18n/strings.g.dart';
import '../../../models/plex_metadata.dart';
import '../../../services/auth_debug_service.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/language_codes.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/app_icon.dart';
import '../../../widgets/focusable_list_tile.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../../widgets/pill_input_decoration.dart';
import 'base_video_control_sheet.dart';

class SubtitleSearchSheet extends StatefulWidget {
  final String ratingKey;
  final String serverId;
  final PlexMetadata metadata;
  final String? mediaTitle;
  final Future<void> Function()? onSubtitleDownloaded;
  final Future<void> Function(SubtitleTrack track)? onExternalSubtitleReady;

  const SubtitleSearchSheet({
    super.key,
    required this.ratingKey,
    required this.serverId,
    required this.metadata,
    this.mediaTitle,
    this.onSubtitleDownloaded,
    this.onExternalSubtitleReady,
  });

  @override
  State<SubtitleSearchSheet> createState() => _SubtitleSearchSheetState();
}

class _SubtitleSearchSheetState extends State<SubtitleSearchSheet> {
  String _languageCode = 'en';
  String _languageName = 'English';
  final _titleController = TextEditingController();
  Timer? _debounceTimer;

  List<SubdlSearchResult>? _results;
  bool _isSearching = false;
  String? _error;
  String? _downloadingKey;

  bool _showLanguagePicker = false;

  @override
  void initState() {
    super.initState();
    _initDefaultLanguage();
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  void _initDefaultLanguage() {
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final code = locale.languageCode;
    final name = LanguageCodes.getLanguageName(code);
    if (name != null) {
      _languageCode = code;
      _languageName = name;
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (!mounted) return;
    setState(() {
      _isSearching = true;
      _error = null;
    });

    try {
      final title = _titleController.text.trim();
      playMediaDebugInfo(
        'Subtitle search UI requested: lang=${_languageCode.toUpperCase()}, title=${title.isEmpty ? '<default>' : title}',
      );
      final results = await SubdlService().search(
        metadata: widget.metadata,
        languageCode: _languageCode,
        titleOverride: title.isEmpty ? null : title,
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _isSearching = false;
      });
      playMediaDebugSuccess('Subtitle search UI received ${results.length} SubDL results.');
    } catch (e) {
      appLogger.e('Subtitle search sheet failed', error: e);
      playMediaDebugError('Subtitle search UI failed: $e');
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isSearching = false;
      });
    }
  }

  void _onTitleChanged(String _) {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 500), _search);
  }

  void _onLanguageSelected(String code, String name) {
    setState(() {
      _languageCode = code;
      _languageName = name;
      _showLanguagePicker = false;
    });
    _search();
  }

  Future<void> _downloadSubdlSubtitle(SubdlSearchResult result) async {
    if (_downloadingKey != null) return;
    setState(() => _downloadingKey = result.rawDownload);

    try {
      playMediaDebugInfo('Subtitle download UI requested: ${result.displayLabel}');
      final downloaded = await SubdlService().downloadAndExtract(
        rawDownload: result.rawDownload,
        displayLabel: result.displayLabel,
        languageCode: result.languageCode,
      );

      if (!mounted) return;

      await widget.onExternalSubtitleReady?.call(
        SubtitleTrack.uri(
          downloaded.file.uri.toString(),
          title: downloaded.displayLabel,
          language: downloaded.languageCode?.toLowerCase(),
        ),
      );
      if (!mounted) return;

      showSuccessSnackBar(context, t.videoControls.subtitleDownloaded);
      playMediaDebugSuccess('Subtitle download UI finished successfully.');
      OverlaySheetController.of(context).close();
    } catch (e) {
      appLogger.e('Subtitle download sheet failed', error: e);
      playMediaDebugError('Subtitle download UI failed: $e');
      if (!mounted) return;
      showErrorSnackBar(context, t.videoControls.subtitleDownloadFailed);
      setState(() => _downloadingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showLanguagePicker) {
      return _LanguagePickerView(
        currentCode: _languageCode,
        onSelected: _onLanguageSelected,
        onBack: () => setState(() => _showLanguagePicker = false),
      );
    }

    final fillColor = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);

    return BaseVideoControlSheet(
      title: t.videoControls.searchSubtitles,
      icon: Symbols.search_rounded,
      onBack: () => OverlaySheetController.of(context).pop(),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                // Language chip
                Material(
                  color: fillColor,
                  borderRadius: pillInputRadius,
                  child: InkWell(
                    borderRadius: pillInputRadius,
                    onTap: () => setState(() => _showLanguagePicker = true),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_languageName),
                          const SizedBox(width: 2),
                          const AppIcon(Symbols.arrow_drop_down_rounded, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Title search field
                Expanded(
                  child: TextField(
                    controller: _titleController,
                    decoration: pillInputDecoration(
                      context,
                      hintText: widget.mediaTitle ?? 'Title',
                      prefixIcon: const Icon(Symbols.search_rounded, size: 20),
                    ),
                    onChanged: _onTitleChanged,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _buildResults()),
        ],
      ),
    );
  }

  Widget _buildResults() {
    if (_isSearching) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
      );
    }

    if (_results == null) {
      return const SizedBox.shrink();
    }

    if (_results!.isEmpty) {
      return Center(
        child: Text(
          t.videoControls.noSubtitlesFound,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }

    return ListView.builder(
      itemCount: _results!.length,
      itemBuilder: (context, index) {
        final result = _results![index];
        final downloadKey = result.rawDownload;
        final isDownloading = _downloadingKey == downloadKey;
        final colorScheme = Theme.of(context).colorScheme;

        Widget? trailing;
        if (isDownloading) {
          trailing = const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          );
        } else {
          trailing = Text(
            result.languageCode?.toUpperCase() ?? 'SUBDL',
            style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
          );
        }

        return FocusableListTile(
          title: Text(
            result.displayLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            'SubDL',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurfaceVariant),
          ),
          trailing: trailing,
          onTap: isDownloading ? null : () => _downloadSubdlSubtitle(result),
        );
      },
    );
  }
}

class _LanguagePickerView extends StatefulWidget {
  final String currentCode;
  final void Function(String code, String name) onSelected;
  final VoidCallback onBack;

  const _LanguagePickerView({
    required this.currentCode,
    required this.onSelected,
    required this.onBack,
  });

  @override
  State<_LanguagePickerView> createState() => _LanguagePickerViewState();
}

class _LanguagePickerViewState extends State<_LanguagePickerView> {
  final _filterController = TextEditingController();
  late List<({String code, String name})> _allLanguages;
  List<({String code, String name})> _filteredLanguages = [];

  @override
  void initState() {
    super.initState();
    _allLanguages = LanguageCodes.getAllLanguages();
    _filteredLanguages = _allLanguages;
  }

  @override
  void dispose() {
    _filterController.dispose();
    super.dispose();
  }

  void _onFilterChanged(String query) {
    final lower = query.toLowerCase();
    setState(() {
      if (lower.isEmpty) {
        _filteredLanguages = _allLanguages;
      } else {
        _filteredLanguages = _allLanguages.where((l) {
          return l.name.toLowerCase().contains(lower) || l.code.toLowerCase().contains(lower);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return BaseVideoControlSheet(
      title: t.videoControls.language,
      icon: Symbols.language_rounded,
      onBack: widget.onBack,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _filterController,
              autofocus: true,
              decoration: pillInputDecoration(
                context,
                hintText: t.videoControls.searchLanguages,
                prefixIcon: const Icon(Symbols.search_rounded, size: 20),
              ),
              onChanged: _onFilterChanged,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredLanguages.length,
              itemBuilder: (context, index) {
                final lang = _filteredLanguages[index];
                final isSelected = lang.code == widget.currentCode;
                return FocusableListTile(
                  title: Text(
                    lang.name,
                    style: TextStyle(color: isSelected ? Theme.of(context).colorScheme.primary : null),
                  ),
                  trailing: isSelected
                      ? AppIcon(Symbols.check_rounded, fill: 1, color: Theme.of(context).colorScheme.primary)
                      : null,
                  onTap: () => widget.onSelected(lang.code, lang.name),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
