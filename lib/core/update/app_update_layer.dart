import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../theme/tv_button.dart';
import 'app_update_notifier.dart';

/// Runs the GitHub release check once and shows a TV-friendly update dialog.
class AppUpdateLayer extends ConsumerStatefulWidget {
  const AppUpdateLayer({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppUpdateLayer> createState() => _AppUpdateLayerState();
}

class _AppUpdateLayerState extends ConsumerState<AppUpdateLayer> {
  bool _started = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _started) return;
      _started = true;
      unawaited(
        ref.read(appUpdateNotifierProvider.notifier).runStartupCheck(),
      );
    });
  }

  Future<void> _openDownload(AppUpdatePrompt p) async {
    final target = p.downloadUrl ?? p.fallbackUrl;
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    final mode = LaunchMode.externalApplication;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: mode);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prompt = ref.watch(appUpdateNotifierProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (prompt != null)
          ModalBarrier(
            color: Colors.black.withValues(alpha: 0.72),
            dismissible: false,
          ),
        if (prompt != null)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          prompt.mandatory
                              ? 'Update required'
                              : 'Update available',
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          prompt.mandatory
                              ? 'This version of TeleCima is no longer supported. '
                                  'The service or app protocol has changed, so you '
                                  'must download and install the new build for your '
                                  'device before you can continue.'
                              : 'A newer release (${prompt.releaseTag}) is available. '
                                  'You are on ${prompt.currentVersion}.',
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 16,
                            height: 1.45,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 28),
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(0),
                          child: TVButton(
                            autofocus: true,
                            onPressed: () async {
                              await _openDownload(prompt);
                              if (!context.mounted) return;
                              if (prompt.mandatory) {
                                return;
                              }
                              ref
                                  .read(appUpdateNotifierProvider.notifier)
                                  .clearOptionalAfterDownload();
                            },
                            child: const Text('Download'),
                          ),
                        ),
                        if (!prompt.mandatory) ...[
                          const SizedBox(height: 14),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(1),
                            child: TVButton(
                              onPressed: () {
                                ref
                                    .read(appUpdateNotifierProvider.notifier)
                                    .skipThisVersion(prompt);
                              },
                              child: const Text('Skip this version'),
                            ),
                          ),
                          const SizedBox(height: 14),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(2),
                            child: TVButton(
                              onPressed: () {
                                ref
                                    .read(appUpdateNotifierProvider.notifier)
                                    .closeOptional();
                              },
                              child: const Text('Close'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
