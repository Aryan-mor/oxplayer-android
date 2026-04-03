import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/detail/single_item_screen.dart';
import 'features/gate/membership_gate_shell.dart';
import 'features/explore/explore_screen.dart';
import 'features/home/home_screen.dart';
import 'features/player/player_route_args.dart';
import 'features/player/player_screen.dart';
import 'features/welcome/welcome_screen.dart';
import 'providers.dart';

/// Root [Navigator] key so overlays (e.g. debug log dialog) work from [MaterialApp.builder]
/// where the FAB sits *next to* the navigator subtree.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// [AuthNotifier] is hydrated from SharedPreferences; [TeleCimaApp] also merges
/// an existing [TelegramSession] row from Isar into the same notifier on startup.
final goRouterProvider = Provider<GoRouter>((ref) {
  final auth = ref.read(authNotifierProvider);
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/welcome',
    refreshListenable: auth,
    redirect: (context, state) {
      if (!auth.ready) return null;
      final path = state.uri.path;
      if (auth.isLoggedIn && path == '/welcome') return '/';
      if (!auth.isLoggedIn && path != '/welcome') return '/welcome';
      if (auth.isLoggedIn && path == '/explore' && !auth.canAccessExplore) {
        return '/';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (context, state) => const WelcomeScreen(),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            MembershipGateShell(child: child),
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/explore',
            builder: (context, state) => ExploreScreen(
              initialGenreId: state.uri.queryParameters['genreId'],
            ),
          ),
          GoRoute(
            path: '/item/:globalId',
            builder: (context, state) {
              final globalId = state.pathParameters['globalId'] ?? '';
              if (globalId.isEmpty) {
                return const Scaffold(
                  body: Center(child: Text('Invalid item.')),
                );
              }
              return SingleItemScreen(globalId: globalId);
            },
          ),
          GoRoute(
            path: '/item',
            builder: (context, state) {
              return const Scaffold(
                body: Center(child: Text('Invalid item. Missing item id.')),
              );
            },
          ),
          GoRoute(
            path: '/play',
            builder: (context, state) {
              final extra = state.extra as PlayerRouteArgs?;
              if (extra == null) {
                return const Scaffold(
                  body: Center(child: Text('Missing playback arguments.')),
                );
              }
              return PlayerScreen(args: extra);
            },
          ),
        ],
      ),
    ],
  );
});
