import 'package:flutter/material.dart';

import '../focus/section_focus_coordinator.dart';

class SectionContainer extends StatelessWidget {
  const SectionContainer({
    super.key,
    required this.sectionId,
    required this.child,
    this.focusCoordinator,
    this.title,
    this.padding,
    this.alignment = 0.1,
  });

  final String sectionId;
  final SectionFocusCoordinator? focusCoordinator;
  final Widget? title;
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double alignment;

  @override
  Widget build(BuildContext context) {
    final body = Focus(
      onFocusChange: (focused) {
        if (!focused) return;
        focusCoordinator?.ensureSectionVisible(
          context: context,
          sectionId: sectionId,
          alignment: alignment,
        );
      },
      child: child,
    );
    if (title == null) {
      return Padding(
        padding: padding ?? EdgeInsets.zero,
        child: body,
      );
    }
    return Padding(
      padding: padding ?? EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title!,
          body,
        ],
      ),
    );
  }
}

