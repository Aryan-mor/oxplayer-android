import 'package:flutter/material.dart';

import '../providers/ox_cast_receiver_provider.dart';

/// Explains TV receive-cast and enables background listening (no spinner).
Future<void> showTvCastReceiverInfoDialog(BuildContext context, OxCastReceiverProvider provider) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text('Receive cast'),
      content: const SingleChildScrollView(
        child: Text(
          'Send videos from your phone to this TV.\n\n'
          'On your phone — signed into the same OXPlayer account — open a title in your library, '
          'choose a video file, then tap Cast. Playback can start here automatically.\n\n'
          'Enable below to keep listening while the app is open. You can turn it off anytime.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await provider.setListeningEnabled(true);
          },
          child: const Text('Enable'),
        ),
      ],
    ),
  );
}

Future<void> showTvCastReceiverDisableDialog(BuildContext context, OxCastReceiverProvider provider) async {
  await showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      title: const Text('Receive cast is on'),
      content: const Text(
        'This TV is listening for casts from your phone. Turn off?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(ctx).pop();
            await provider.setListeningEnabled(false);
          },
          child: const Text('Turn off'),
        ),
      ],
    ),
  );
}
