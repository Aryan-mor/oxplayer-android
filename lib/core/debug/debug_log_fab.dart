import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../router.dart';
import 'app_debug_log.dart';

/// Debug-only control (bottom-right). Tap opens a dialog: log text, Copy, Clear, Close.
/// Uses [rootNavigatorKey] so [showDialog] works from [MaterialApp.builder] (FAB is not under [Navigator]).
class DebugLogFab extends StatelessWidget {
  const DebugLogFab({super.key});

  static Future<void> openModal(BuildContext fallbackContext) async {
    if (!kDebugMode) return;

    void showWith(BuildContext dialogContext) {
      showDialog<void>(
        context: dialogContext,
        useRootNavigator: true,
        barrierDismissible: true,
        builder: (dialogContext) {
          return ListenableBuilder(
            listenable: AppDebugLog.instance,
            builder: (context, _) {
              final log = AppDebugLog.instance;
              final text = log.fullText;
              final mq = MediaQuery.sizeOf(dialogContext);
              final maxH = (mq.height * 0.5).clamp(200.0, 480.0);

              Future<void> copy() async {
                if (text.isEmpty) return;
                await Clipboard.setData(ClipboardData(text: text));
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              }

              return AlertDialog(
                title: const Text('Debug log'),
                content: SizedBox(
                  width: double.maxFinite,
                  height: maxH,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(dialogContext).dividerColor),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Scrollbar(
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(10),
                        child: SelectableText(
                          text.isEmpty ? '(empty)' : text,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            height: 1.25,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: text.isEmpty ? null : copy,
                    child: const Text('Copy'),
                  ),
                  TextButton(
                    onPressed: text.isEmpty ? null : () => log.clear(),
                    child: const Text('Clear'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          );
        },
      );
    }

    BuildContext? ctx = rootNavigatorKey.currentContext;
    ctx ??= fallbackContext.mounted ? fallbackContext : null;
    if (ctx != null) {
      showWith(ctx);
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final c = rootNavigatorKey.currentContext;
      if (c != null) {
        showWith(c);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return const SizedBox.shrink();

    return SafeArea(
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        elevation: 3,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openModal(context),
          customBorder: const CircleBorder(),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Icon(
              Icons.bug_report_outlined,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
