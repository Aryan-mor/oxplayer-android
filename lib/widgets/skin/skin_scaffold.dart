import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

@Deprecated('Legacy skin scaffold. Use Plezy-style screen layouts directly.')
class SkinScaffold extends StatelessWidget {
  const SkinScaffold({
    super.key,
    this.header,
    required this.child,
  });

  final Widget? header;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            if (header != null) header!,
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
