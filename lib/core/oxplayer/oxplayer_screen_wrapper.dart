import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class OxplayerBackIntent extends Intent {
  const OxplayerBackIntent();
}

class OxplayerMenuIntent extends Intent {
  const OxplayerMenuIntent();
}

class OxplayerGuideIntent extends Intent {
  const OxplayerGuideIntent();
}

class OxplayerScreenWrapper extends StatefulWidget {
  const OxplayerScreenWrapper({
    super.key,
    required this.child,
    this.primaryFocusNode,
  });

  final Widget child;
  final FocusNode? primaryFocusNode;

  @override
  State<OxplayerScreenWrapper> createState() => _OxplayerScreenWrapperState();
}

class _OxplayerScreenWrapperState extends State<OxplayerScreenWrapper> {
  late final FocusScopeNode _scopeNode;

  @override
  void initState() {
    super.initState();
    _scopeNode = FocusScopeNode(debugLabel: 'OxplayerScreenWrapperScope');
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
        SingleActivator(LogicalKeyboardKey.goBack): OxplayerBackIntent(),
        SingleActivator(LogicalKeyboardKey.escape): OxplayerBackIntent(),
        SingleActivator(LogicalKeyboardKey.browserBack): OxplayerBackIntent(),
        SingleActivator(LogicalKeyboardKey.contextMenu): OxplayerMenuIntent(),
        SingleActivator(LogicalKeyboardKey.guide): OxplayerGuideIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          OxplayerBackIntent: CallbackAction<OxplayerBackIntent>(
            onInvoke: (_) => _handleBack(context),
          ),
          OxplayerMenuIntent: CallbackAction<OxplayerMenuIntent>(
            onInvoke: (_) => null,
          ),
          OxplayerGuideIntent: CallbackAction<OxplayerGuideIntent>(
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
