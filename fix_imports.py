import os
import re

def fix_imports(file_path):
    with open(file_path, 'r', encoding='utf-8') as f:
        content = f.read()

    # Replace relative imports that go up to `lib/` with `lib/infrastructure/mocks/`
    # For example, `../../services/plex_client.dart` -> `../../infrastructure/mocks/services/plex_client.dart`
    # We only want to replace imports that match our mocked folders:
    # services, i18n, utils, mixins, widgets, providers, watch_together, screens
    
    # Wait, widgets, utils, navigation were copied properly.
    # So we SHOULD NOT mock widgets, utils, navigation, focus, theme, models if we copied them.
    # Let's define exactly what goes to `mocks/`
    mocked_dirs = ['services', 'i18n', 'mixins', 'providers', 'watch_together', 'screens']
    # some widgets, utils were mocked
    mocked_specific = [
        'widgets/overlay_sheet.dart', 'widgets/app_icon.dart', 'widgets/server_activities_button.dart',
        'widgets/plex_optimized_image.dart', 'widgets/companion_remote/remote_session_dialog.dart',
        'utils/app_logger.dart', 'utils/dialogs.dart', 'utils/provider_extensions.dart',
        'utils/video_player_navigation.dart', 'utils/content_utils.dart', 'utils/global_key_utils.dart',
        'utils/plex_image_helper.dart', 'utils/watch_state_notifier.dart'
    ]
    
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        if line.startswith('import '):
            # Check if it matches any of the mocked dirs or specific files
            is_mocked = False
            for md in mocked_dirs:
                if re.search(r'[\'"](\.\./)*' + md + r'/', line):
                    is_mocked = True
                    break
            for ms in mocked_specific:
                if re.search(r'[\'"](\.\./)*' + ms + r'[\'"]', line):
                    is_mocked = True
                    break
            
            if is_mocked:
                # Replace the '..' part with '../../infrastructure/mocks/'
                # First extract the actual path after the '..'
                match = re.search(r'[\'"](?:(?:\.\./)+)(.*?)[\'"]', line)
                if match:
                    actual_path = match.group(1)
                    line = f"import '../../infrastructure/mocks/{actual_path}';"
                else:
                    # Maybe it's a sibling import like 'auth_screen.dart'
                    match2 = re.search(r'[\'"](.*?)[\'"]', line)
                    if match2:
                        actual_path = match2.group(1)
                        if 'package:' not in actual_path and not actual_path.startswith('.'):
                            line = f"import '../../infrastructure/mocks/screens/{actual_path}';"
        new_lines.append(line)

    with open(file_path, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_lines))

fix_imports('lib/features/home/home_screen.dart')
fix_imports('lib/features/home/discover_screen.dart')
