import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'app_debug_log.dart';

/// Debug-only: logs [LayoutBuilder] constraints and this subtree's [RenderBox]
/// size after layout when values change.
class LayoutProbe extends StatefulWidget {
  const LayoutProbe({
    super.key,
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  State<LayoutProbe> createState() => _LayoutProbeState();
}

class _LayoutProbeState extends State<LayoutProbe> {
  final GlobalKey _paintKey = GlobalKey(debugLabel: 'LayoutProbe');
  String? _lastConstraintSig;
  String? _lastBoxSig;

  void _log(String line) {
    if (!kDebugMode) return;
    AppDebugLog.instance.log(line, category: AppDebugLogCategory.app);
  }

  void _reportBox() {
    if (!kDebugMode) return;
    final ctx = _paintKey.currentContext;
    if (ctx == null) {
      _log('LayoutProbe[${widget.label}] postLayout: context=null');
      return;
    }
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox) {
      _log(
        'LayoutProbe[${widget.label}] postLayout: RO=${ro.runtimeType}',
      );
      return;
    }
    final sig = 'hasSize=${ro.hasSize};'
        'w=${ro.hasSize ? ro.size.width.toStringAsFixed(1) : "-"};'
        'h=${ro.hasSize ? ro.size.height.toStringAsFixed(1) : "-"};'
        'paint=${ro.hasSize ? ro.localToGlobal(Offset.zero) : "-"}';
    if (sig == _lastBoxSig) return;
    _lastBoxSig = sig;
    _log('LayoutProbe[${widget.label}] RenderBox $sig');
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) return widget.child;

    final mq = MediaQuery.sizeOf(context);
    final v = View.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final cSig =
            'max=${constraints.maxWidth.toStringAsFixed(1)}x${constraints.maxHeight.toStringAsFixed(1)} '
            'min=${constraints.minWidth.toStringAsFixed(1)}x${constraints.minHeight.toStringAsFixed(1)} '
            'mq=${mq.width.toStringAsFixed(1)}x${mq.height.toStringAsFixed(1)} '
            'dpr=${MediaQuery.devicePixelRatioOf(context).toStringAsFixed(2)} '
            'view=${v.physicalSize.width.toStringAsFixed(0)}x${v.physicalSize.height.toStringAsFixed(0)}';
        if (cSig != _lastConstraintSig) {
          _lastConstraintSig = cSig;
          _log('LayoutProbe[${widget.label}] constraints $cSig');
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _reportBox();
        });

        return RepaintBoundary(
          key: _paintKey,
          child: widget.child,
        );
      },
    );
  }
}
