import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_debug_service.dart';
import '../utils/navigation_keys.dart';

class AuthDebugFab extends StatelessWidget {
  const AuthDebugFab({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthDebugService.instance,
      builder: (context, child) {
        if (!AuthDebugService.instance.isEnabled) {
          return const SizedBox.shrink();
        }

        return SafeArea(
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: FloatingActionButton.small(
                heroTag: 'auth_debug_fab',
                onPressed: () => _showAuthDebugDialog(context),
                child: const Icon(Icons.bug_report_outlined),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showAuthDebugDialog(BuildContext context) {
    final dialogContext = rootNavigatorKey.currentContext;
    if (dialogContext == null) {
      return Future<void>.value();
    }
    return showDialog<void>(
      context: dialogContext,
      useRootNavigator: true,
      builder: (context) => const _AuthDebugDialog(),
    );
  }
}

class _AuthDebugDialog extends StatelessWidget {
  const _AuthDebugDialog();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 560),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Debug Logs',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'Logs'),
                  Tab(text: 'Status'),
                ],
              ),
              const Expanded(
                child: TabBarView(
                  children: [
                    _LogsTab(),
                    _StatusTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LogsTab extends StatefulWidget {
  const _LogsTab();

  @override
  State<_LogsTab> createState() => _LogsTabState();
}

class _LogsTabState extends State<_LogsTab> with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const List<LogType?> _tabs = <LogType?>[
    null,
    ...LogType.values,
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  String _tabLabel(LogType? type) => type?.label ?? 'All';

  String _emptyStateLabel(LogType? type) => type == null ? 'No debug logs yet.' : 'No ${type.label} logs yet.';

  Future<void> _copyLogs(BuildContext context, LogType? selectedType) async {
    final text = AuthDebugService.instance.formattedEntriesText(type: selectedType);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    final label = _tabLabel(selectedType);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label logs copied to clipboard.')),
    );
  }

  void _clearLogs(LogType? selectedType) {
    AuthDebugService.instance.clearEntries(type: selectedType);
  }

  Color _entryColor(BuildContext context, AuthDebugEntry entry) {
    return switch (entry.level) {
      AuthDebugLevel.info => Theme.of(context).colorScheme.secondary,
      AuthDebugLevel.success => Colors.green,
      AuthDebugLevel.error => Theme.of(context).colorScheme.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _tabController,
      builder: (context, child) {
        final selectedType = _tabs[_tabController.index];
        return AnimatedBuilder(
          animation: AuthDebugService.instance,
          builder: (context, child) {
            final entries = AuthDebugService.instance.entriesForType(selectedType);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TabBar(
                      controller: _tabController,
                      isScrollable: true,
                      tabAlignment: TabAlignment.start,
                      tabs: _tabs.map((type) => Tab(text: _tabLabel(type))).toList(growable: false),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _copyLogs(context, selectedType),
                        icon: const Icon(Icons.copy_all_outlined),
                        label: Text('Copy ${_tabLabel(selectedType)}'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: entries.isEmpty ? null : () => _clearLogs(selectedType),
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: Text('Clear ${_tabLabel(selectedType)}'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? Center(child: Text(_emptyStateLabel(selectedType)))
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: entries.length,
                          separatorBuilder: (context, index) => const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final color = _entryColor(context, entry);

                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Theme.of(context).dividerColor),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '${entry.timestamp.hour.toString().padLeft(2, '0')}:${entry.timestamp.minute.toString().padLeft(2, '0')}:${entry.timestamp.second.toString().padLeft(2, '0')}',
                                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(999),
                                          color: color.withValues(alpha: 0.12),
                                        ),
                                        child: Text(
                                          entry.type.label,
                                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(entry.message),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _StatusTab extends StatelessWidget {
  const _StatusTab();

  Future<void> _copyStatuses(BuildContext context) async {
    final statuses = AuthDebugService.instance.statuses;
    final text = statuses
        .map((status) => '${status.completed ? '[x]' : '[ ]'} ${status.label}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Status copied to clipboard.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AuthDebugService.instance,
      builder: (context, child) {
        final statuses = AuthDebugService.instance.statuses;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => _copyStatuses(context),
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('Copy Status'),
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: statuses.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final status = statuses[index];
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      status.completed ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: status.completed ? Colors.green : Theme.of(context).colorScheme.outline,
                    ),
                    title: Text(status.label),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}