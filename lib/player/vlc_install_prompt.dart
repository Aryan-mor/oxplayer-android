import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/theme/app_theme.dart';
import '../widgets/oxplayer_button.dart';
import '../core/update/android_package_info.dart';
import 'external_player.dart';

const _kVlcPackageId = 'org.videolan.vlc';
const _kPrefsKey = 'oxplayer_vlc_install_prompt_dismissed_version';

Future<bool> _vlcPromptSuppressedForCurrentVersion() async {
  final label = await readAndroidPackageVersionLabel();
  if (label == null || label.isEmpty) return false;
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kPrefsKey) == label;
}

Future<void> _persistVlcPromptDismissedForCurrentVersion() async {
  final label = await readAndroidPackageVersionLabel();
  if (label == null || label.isEmpty) return;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kPrefsKey, label);
}

enum _VlcDialogResult {
  /// Opened Play Store; defer this play/stream.
  install,
  /// Show the dialog again on next play/stream.
  remindLater,
  /// Do not show again for this app version; continue playback now.
  dismissForVersion,
}

/// Returns `true` if external playback should run now.
///
/// Android TV and Android phone use the **same** logic: one app binary,
/// [TargetPlatform.android], package [org.videolan.vlc], and the same
/// Play Store / browser listing. Only the system store UI may differ by form factor.
///
/// When VLC is not installed and the user has not chosen **Close** for this app
/// version, shows a dialog. **Install** and **Remind me later** defer the current
/// action; **Close** saves opt-out for this version and continues playback.
Future<bool> ensureVlcOrProceedToExternalPlayer(BuildContext context) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return true;
  }
  if (await ExternalPlayer.isPackageInstalled(_kVlcPackageId)) {
    return true;
  }
  if (await _vlcPromptSuppressedForCurrentVersion()) {
    return true;
  }
  if (!context.mounted) return false;
  final result = await showDialog<_VlcDialogResult>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        backgroundColor: AppColors.card,
        title: const Text(
          'Play with VLC',
          style: TextStyle(color: Colors.white),
        ),
        content: const Text(
          'VLC works best with this app for playback. '
          'Install VLC for the recommended experience.',
          style: TextStyle(color: AppColors.textMuted, height: 1.35),
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
                  autofocus: true,
                  onPressed: () async {
                    await ExternalPlayer.openPlayStoreListing(_kVlcPackageId);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop(_VlcDialogResult.install);
                    }
                  },
                  child: const Text(
                    'Install',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                OxplayerButton(
                  onPressed: () => Navigator.of(dialogContext)
                      .pop(_VlcDialogResult.remindLater),
                  child: const Text(
                    'Remind me later',
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
                OxplayerButton(
                  onPressed: () async {
                    await _persistVlcPromptDismissedForCurrentVersion();
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext)
                          .pop(_VlcDialogResult.dismissForVersion);
                    }
                  },
                  child: const Text(
                    'Close',
                    style: TextStyle(color: AppColors.textMuted),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
  return result == _VlcDialogResult.dismissForVersion;
}

