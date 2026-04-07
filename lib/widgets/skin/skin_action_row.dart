import 'package:flutter/material.dart';

class SkinActionRow extends StatelessWidget {
  const SkinActionRow({
    super.key,
    required this.children,
  });

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.start,
      children: children,
    );
  }
}
