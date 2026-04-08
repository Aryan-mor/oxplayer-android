import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../router.dart';
import '../device/device_profile.dart';
import '../focus/input_mode_tracker.dart';
import 'app_debug_log.dart';


/// Debug-only control (bottom-right). Tap opens a dialog: tabs (All + categories), Copy (active tab), Clear, Close.
/// Uses [rootNavigatorKey] so [showDialog] works from [MaterialApp.builder] (FAB is not under [Navigator]).
class DebugLogFab extends StatelessWidget {
  const DebugLogFab({super.key});

  static Future<void> openModal(BuildContext fallbackContext) async {
    if (!AppDebugLog.instance.isEnabled) return;

    void showWith(BuildContext dialogContext) {
      showDialog<void>(
        context: dialogContext,
        useRootNavigator: true,
        barrierDismissible: true,
        builder: (dialogContext) {
          final mq = MediaQuery.sizeOf(dialogContext);
          final maxH = (mq.height * 0.62).clamp(240.0, 560.0);
          return _DebugLogDialog(maxBodyHeight: maxH);
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
    if (!AppDebugLog.instance.isEnabled) return const SizedBox.shrink();

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

class _DebugLogDialog extends StatefulWidget {
  const _DebugLogDialog({required this.maxBodyHeight});

  final double maxBodyHeight;

  @override
  State<_DebugLogDialog> createState() => _DebugLogDialogState();
}

class _DebugLogDialogState extends State<_DebugLogDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 1 + AppDebugLog.tabOrder.length,
      vsync: this,
    );
    _tabController.addListener(() {
      if (_tabController.indexIsChanging) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _activeTabText() {
    final log = AppDebugLog.instance;
    final i = _tabController.index;
    if (i == 0) return log.fullText;
    return log.textForCategory(AppDebugLog.tabOrder[i - 1]);
  }

  @override
  Widget build(BuildContext context) {
    final dialogContext = context;
    return ListenableBuilder(
      listenable: AppDebugLog.instance,
      builder: (context, _) {
        final log = AppDebugLog.instance;
        final activeText = _activeTabText();

        Future<void> copyActive() async {
          if (activeText.isEmpty) return;
          await Clipboard.setData(ClipboardData(text: activeText));
          if (!dialogContext.mounted) return;
          ScaffoldMessenger.of(dialogContext).showSnackBar(
            SnackBar(
              content: Text(
                'Copied ${_tabLabelAt(_tabController.index, log)} (${activeText.length} chars)',
              ),
            ),
          );
        }

        return AlertDialog(
          title: const Text('Debug log'),
          content: SizedBox(
            width: double.maxFinite,
            height: widget.maxBodyHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // UI Testing Overrides
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    children: [
                      SwitchListTile(
                        title: const Text('Force TV Mode (isTv)'),
                        subtitle: const Text('Overrides DeviceProfile to force TV layout'),
                        value: DeviceProfileService.debugOverrideIsTv ?? false,
                        onChanged: (val) {
                          DeviceProfileService.toggleDebugTvMode(val);
                          setState(() {});
                        },
                      ),
                      SwitchListTile(
                        title: const Text('Force Keyboard Mode'),
                        subtitle: const Text('Forces focus styling/scaling on all platforms'),
                        value: InputModeTracker.debugOverrideMode == InputMode.keyboard,
                        onChanged: (val) {
                          InputModeTracker.toggleDebugMode(val);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: 'All (${log.totalCount})'),
                    ...AppDebugLog.tabOrder.map(
                      (c) => Tab(text: '${c.tabLabel} (${log.countIn(c)})'),
                    ),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _LogScrollBody(text: log.fullText),
                      ...AppDebugLog.tabOrder.map(
                        (c) => _LogScrollBody(text: log.textForCategory(c)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          actions: [
            TextButton(
              onPressed: activeText.isEmpty ? null : copyActive,
              child: const Text('Copy tab'),
            ),
            TextButton(
              onPressed: log.totalCount == 0 ? null : () => log.clear(),
              child: const Text('Clear all'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  static String _tabLabelAt(int index, AppDebugLog log) {
    if (index == 0) return 'All';
    return AppDebugLog.tabOrder[index - 1].tabLabel;
  }
}

class _LogScrollBody extends StatefulWidget {
  const _LogScrollBody({required this.text});

  final String text;

  @override
  State<_LogScrollBody> createState() => _LogScrollBodyState();
}

class _LogScrollBodyState extends State<_LogScrollBody> {
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Scrollbar(
        controller: _scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _scrollController,
          primary: false,
          padding: const EdgeInsets.all(10),
          child: SelectableText(
            widget.text.isEmpty ? '(empty)' : widget.text,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 10,
              height: 1.25,
            ),
          ),
        ),
      ),
    );
  }
}


