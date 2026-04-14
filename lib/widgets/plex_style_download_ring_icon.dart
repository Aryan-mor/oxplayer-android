import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Plex-style download control: circular progress around a center icon (pause / play / etc.).
///
/// Use [indeterminate] for queued / preparing; use [determinateProgress] in `0..1` while
/// downloading or paused so the ring shows completion around the icon.
class PlexStyleDownloadRingIcon extends StatelessWidget {
  const PlexStyleDownloadRingIcon({
    super.key,
    required this.centerIcon,
    required this.indeterminate,
    this.determinateProgress,
    this.diameter = 38,
    this.strokeWidth = 2.5,
    this.trackColor,
    this.progressColor,
  }) : assert(indeterminate || determinateProgress != null, 'Provide determinateProgress when not indeterminate');

  final Widget centerIcon;
  final bool indeterminate;
  final double? determinateProgress;
  final double diameter;
  final double strokeWidth;
  final Color? trackColor;
  final Color? progressColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final track = trackColor ?? theme.colorScheme.surfaceContainerHighest;
    final prog = progressColor ?? theme.colorScheme.primary;

    if (indeterminate) {
      return SizedBox(
        width: diameter,
        height: diameter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CircularProgressIndicator(
                strokeWidth: strokeWidth,
                valueColor: AlwaysStoppedAnimation<Color>(prog),
              ),
            ),
            centerIcon,
          ],
        ),
      );
    }

    final p = math.max(determinateProgress!.clamp(0.0, 1.0), 0.02);

    return SizedBox(
      width: diameter,
      height: diameter,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned.fill(
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: strokeWidth,
              valueColor: AlwaysStoppedAnimation<Color>(track.withValues(alpha: 0.55)),
            ),
          ),
          Positioned.fill(
            child: CircularProgressIndicator(
              value: p,
              strokeWidth: strokeWidth,
              backgroundColor: Colors.transparent,
              valueColor: AlwaysStoppedAnimation<Color>(prog),
            ),
          ),
          centerIcon,
        ],
      ),
    );
  }
}
