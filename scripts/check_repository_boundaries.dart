import 'dart:io';

final _workspaceRoot = Directory.current;

final _allowedTelegramFiles = <String>{
  'lib/infrastructure/data_repository.dart',
};

final _allowedApiFiles = <String>{
  'lib/infrastructure/data_repository.dart',
  'lib/infrastructure/media_repository.dart',
  'lib/infrastructure/config/app_config.dart',
};

void main() {
  final libDir = Directory('${_workspaceRoot.path}${Platform.pathSeparator}lib');
  if (!libDir.existsSync()) {
    stderr.writeln('Boundary lint expected to run from the Flutter workspace root.');
    exitCode = 2;
    return;
  }

  final violations = <String>[];
  for (final entity in libDir.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final relativePath = _toRelativePath(entity.path);
    final content = entity.readAsStringSync();

    final isTelegramInfrastructure = relativePath.startsWith('lib/infrastructure/telegram/');
    final isAllowedTelegram = isTelegramInfrastructure || _allowedTelegramFiles.contains(relativePath);
    if (!isAllowedTelegram) {
      if (content.contains("package:tdlib/") || content.contains('/infrastructure/telegram/')) {
        violations.add('$relativePath: direct Telegram/TDLib access is only allowed inside DataRepository or infrastructure/telegram.');
      }
    }

    final isAllowedApi = _allowedApiFiles.contains(relativePath);
    if (!isAllowedApi) {
      final hasOxApiRoute = RegExp(r'''["\']/(auth/telegram|me(?:/|["\']))''').hasMatch(content);
      final hasOxApiConfig = content.contains('OXPLAYER_API_BASE_URL') || content.contains('TV_APP_API_BASE_URL');
      if (hasOxApiRoute || hasOxApiConfig) {
        violations.add('$relativePath: direct OX API access is only allowed inside DataRepository/MediaRepository.');
      }
    }
  }

  if (violations.isEmpty) {
    stdout.writeln('Repository boundary lint passed.');
    return;
  }

  stderr.writeln('Repository boundary lint failed:');
  for (final violation in violations) {
    stderr.writeln(' - $violation');
  }
  exitCode = 1;
}

String _toRelativePath(String absolutePath) {
  final relative = absolutePath.substring(_workspaceRoot.path.length + 1);
  return relative.replaceAll('\\', '/');
}