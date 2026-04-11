import 'package:dio/dio.dart';

import '../infrastructure/data_repository.dart';
import '../providers/auth_notifier.dart';
import '../utils/app_logger.dart';

/// Result of [OxApiSessionRecovery.tryRecoverSession].
enum OxApiRecoveryOutcome {
  /// Session validated or re-established via Telegram.
  recovered,

  /// API down, gateway error, timeout — safe to retry later.
  transientFailure,

  /// Telegram interactive login required, or token exchange failed irrecoverably.
  hardFailure,
}

/// Re-validates the OXPlayer API session when the app landed offline due to API errors.
///
/// Flow: [DataRepository.bootstrapConnectedSession]. On [OxBootstrapUnauthorized],
/// calls [DataRepository.authenticateWithTelegram] so the server can upsert the user
/// and issue a new access token (same contract as login), then bootstraps again.
class OxApiSessionRecovery {
  OxApiSessionRecovery._();

  static Future<OxApiRecoveryOutcome> tryRecoverSession(AuthNotifier auth) async {
    if (auth.apiAccessToken == null || auth.apiAccessToken!.isEmpty) {
      return OxApiRecoveryOutcome.hardFailure;
    }

    final repo = await DataRepository.create();
    try {
      try {
        final b = await repo.bootstrapConnectedSession(
          requireTelegramSession: auth.hasTelegramSession && !auth.telegramSessionValidatedInProcess,
        );
        if (b.telegramReady) {
          auth.markTelegramSessionValidatedInProcess();
        }
        return OxApiRecoveryOutcome.recovered;
      } on OxBootstrapUnauthorized {
        final result = await repo.authenticateWithTelegram();
        await auth.persistTelegramBackendSession(result);
        try {
          final b2 = await repo.bootstrapConnectedSession(requireTelegramSession: false);
          if (b2.telegramReady) {
            auth.markTelegramSessionValidatedInProcess();
          }
          return OxApiRecoveryOutcome.recovered;
        } on OxBootstrapUnauthorized {
          appLogger.w('OX API recovery: bootstrap still unauthorized after Telegram re-exchange');
          return OxApiRecoveryOutcome.hardFailure;
        }
      } on TdlibInteractiveLoginRequired {
        return OxApiRecoveryOutcome.hardFailure;
      }
    } on DioException catch (e) {
      final c = e.response?.statusCode;
      if (c == null || c >= 500 || c == 408) {
        return OxApiRecoveryOutcome.transientFailure;
      }
      if (c == 401) {
        return OxApiRecoveryOutcome.hardFailure;
      }
      return OxApiRecoveryOutcome.transientFailure;
    } catch (e, st) {
      appLogger.w('OX API recovery failed', error: e, stackTrace: st);
      return OxApiRecoveryOutcome.transientFailure;
    } finally {
      await repo.dispose();
    }
  }
}
