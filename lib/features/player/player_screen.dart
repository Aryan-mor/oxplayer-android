import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import 'player_route_args.dart';

/// Internal player stub — streaming is removed from MVP v1.
///
/// All playback now goes through the external player intent fired by
/// [SingleItemScreen] → [ExternalPlayer.launchVideo]. This screen is kept
/// so any lingering `/play` pushes don't crash, but it will not actually play.
class PlayerScreen extends StatelessWidget {
  const PlayerScreen({super.key, required this.args});

  final PlayerRouteArgs args;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(args.title)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off, size: 64, color: AppColors.textMuted),
            const SizedBox(height: 16),
            const Text(
              'Internal playback is disabled in this version.',
              style: TextStyle(fontSize: 16, color: AppColors.textMuted),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Download the file and use Play to open in an external player.',
              style: TextStyle(color: AppColors.textMuted, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }
}
