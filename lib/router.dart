import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'main.dart' show OrientationAwareSetup;
import 'providers/auth_notifier.dart';
import 'screens/auth_screen.dart';

class AppRouter extends StatelessWidget {
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthNotifier>(
      builder: (context, auth, child) {
        // Wait until hydration finishes before mounting AuthScreen. Otherwise
        // AuthScreen may start Telegram restore while we still think there is no
        // token, then hydration reveals a stale token and we jump to setup —
        // causing bootstrap/logout thrash when the server DB was wiped.
        if (!auth.ready) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (auth.hasPersistedSession) {
          return const OrientationAwareSetup();
        }
        return const AuthScreen();
      },
    );
  }
}