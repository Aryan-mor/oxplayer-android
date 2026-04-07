import 'package:flutter/material.dart';

import '../../core/theme/oxplayer_button.dart';

class SkinChipButton extends StatelessWidget {
  const SkinChipButton({
    super.key,
    required this.label,
    this.selected = false,
    this.focusNode,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final FocusNode? focusNode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OxplayerButton(
      focusNode: focusNode,
      selected: selected,
      borderRadius: 999,
      onPressed: onPressed,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(label),
    );
  }
}
