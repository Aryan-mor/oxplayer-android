import 'package:flutter/material.dart';

import '../../core/focus/section_focus_coordinator.dart';
import '../../core/layout/section_container.dart';
import 'skin_section_header.dart';

@Deprecated('Legacy section wrapper. Use Plezy-style hub row sections.')
class SkinSection extends StatelessWidget {
  const SkinSection({
    super.key,
    required this.sectionId,
    required this.coordinator,
    required this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  final String sectionId;
  final SectionFocusCoordinator coordinator;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: SectionContainer(
        sectionId: sectionId,
        focusCoordinator: coordinator,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkinSectionHeader(
              title: title,
              subtitle: subtitle,
              trailing: trailing,
            ),
            child,
          ],
        ),
      ),
    );
  }
}
