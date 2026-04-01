import 'package:flutter/material.dart';

import '../theme/tv_button.dart';

/// D-pad friendly expand/collapse (replaces [ExpansionTile] on Android TV).
class TvExpandableSection extends StatefulWidget {
  const TvExpandableSection({
    super.key,
    required this.title,
    required this.child,
    this.initiallyExpanded = false,
    this.spacingAfter = 6,
  });

  final String title;
  final Widget child;
  final bool initiallyExpanded;

  /// Vertical gap before the next sibling (stacked accordions).
  final double spacingAfter;

  @override
  State<TvExpandableSection> createState() => _TvExpandableSectionState();
}

class _TvExpandableSectionState extends State<TvExpandableSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final section = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TVButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                color: Colors.white70,
              ),
            ],
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
            child: widget.child,
          ),
      ],
    );
    if (widget.spacingAfter <= 0) return section;
    return Padding(
      padding: EdgeInsets.only(bottom: widget.spacingAfter),
      child: section,
    );
  }
}
