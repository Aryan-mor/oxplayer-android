import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TVBackIntent extends Intent {
  const TVBackIntent();
}

class TVMenuIntent extends Intent {
  const TVMenuIntent();
}

class TVGuideIntent extends Intent {
  const TVGuideIntent();
}

class TVScreenWrapper extends StatefulWidget {
  const TVScreenWrapper({
    super.key,
    required this.child,
    this.primaryFocusNode,
  });

  final Widget child;
  final FocusNode? primaryFocusNode;

  @override
  State<TVScreenWrapper> createState() => _TVScreenWrapperState();
}

class _TVScreenWrapperState extends State<TVScreenWrapper> {
  late final FocusScopeNode _scopeNode;

  @override
  void initState() {
    super.initState();
    _scopeNode = FocusScopeNode(debugLabel: 'TVScreenWrapperScope');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = widget.primaryFocusNode;
      if (target != null && mounted) {
        _scopeNode.requestFocus(target);
      }
    });
  }

  @override
  void dispose() {
    _scopeNode.dispose();
    super.dispose();
  }

  void _handleBack(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.goBack): TVBackIntent(),
        SingleActivator(LogicalKeyboardKey.escape): TVBackIntent(),
        SingleActivator(LogicalKeyboardKey.browserBack): TVBackIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): TVMenuIntent(),
        SingleActivator(LogicalKeyboardKey.guide): TVGuideIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          TVBackIntent: CallbackAction<TVBackIntent>(
            onInvoke: (_) => _handleBack(context),
          ),
          TVMenuIntent: CallbackAction<TVMenuIntent>(
            onInvoke: (_) => null,
          ),
          TVGuideIntent: CallbackAction<TVGuideIntent>(
            onInvoke: (_) => null,
          ),
        },
        child: FocusTraversalGroup(
          policy: OrderedTraversalPolicy(),
          child: FocusScope(
            node: _scopeNode,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
