import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/theme/oxplayer_button.dart';
import 'playback_surface_prefs.dart';

export 'playback_surface_prefs.dart'
    show PlaybackSurface, PlaybackSurfaceKind;

/// Remote-friendly picker: external vs internal player.
///
/// If [remember] is true, saves [PlaybackSurfacePrefs] for [kind] before popping.
Future<PlaybackSurface?> showPlaybackSurfacePicker(
  BuildContext context, {
  required PlaybackSurfaceKind kind,
}) async {
  final saved = await PlaybackSurfacePrefs.getSaved(kind);
  if (saved != null) {
    return saved;
  }
  if (!context.mounted) return null;
  final title = switch (kind) {
    PlaybackSurfaceKind.stream => 'How do you want to stream?',
    PlaybackSurfaceKind.localFile => 'How do you want to play this file?',
  };
  final blurb = switch (kind) {
    PlaybackSurfaceKind.stream =>
      'External opens VLC or another app. Internal plays inside OXPlayer.',
    PlaybackSurfaceKind.localFile =>
      'External opens VLC or another app. Internal plays inside OXPlayer. '
          'This choice applies to local files only, not streams.',
  };
  return showDialog<PlaybackSurface>(
    context: context,
    barrierDismissible: true,
    builder: (dialogContext) {
      return _PlaybackSurfacePickerDialog(
        title: title,
        blurb: blurb,
        onChoose: (surface, remember) async {
          if (remember) {
            await PlaybackSurfacePrefs.save(kind, surface);
          }
          if (dialogContext.mounted) {
            Navigator.of(dialogContext).pop(surface);
          }
        },
      );
    },
  );
}

class _PlaybackSurfacePickerDialog extends StatefulWidget {
  const _PlaybackSurfacePickerDialog({
    required this.title,
    required this.blurb,
    required this.onChoose,
  });

  final String title;
  final String blurb;
  final Future<void> Function(PlaybackSurface surface, bool remember) onChoose;

  @override
  State<_PlaybackSurfacePickerDialog> createState() =>
      _PlaybackSurfacePickerDialogState();
}

class _PlaybackSurfacePickerDialogState
    extends State<_PlaybackSurfacePickerDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.card,
      title: Text(
        widget.title,
        style: const TextStyle(color: Colors.white, fontSize: 20),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.blurb,
              style: const TextStyle(color: AppColors.textMuted, height: 1.35),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? false),
              title: const Text(
                'Remember for this type of playback',
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              activeColor: AppColors.highlight,
              checkColor: Colors.black,
              tileColor: Colors.transparent,
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
      actions: [
        FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OxplayerButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel', style: TextStyle(color: Colors.white)),
              ),
              OxplayerButton(
                onPressed: () async {
                  await widget.onChoose(PlaybackSurface.external, _remember);
                },
                child: const Text('External player'),
              ),
              OxplayerButton(
                onPressed: () async {
                  await widget.onChoose(PlaybackSurface.internal, _remember);
                },
                child: const Text('Internal player'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
