import os
import shutil
import re

base_dir = r"c:\Users\Aryan\Documents\Projects\oxplayer-wrapper\oxplayer-android"
plezy_dir = os.path.join(base_dir, "refs", "plezy")
lib_dir = os.path.join(base_dir, "lib")

# Missing files to copy
missing_files = [
    ("lib/widgets/library_media_poster.dart", "lib/widgets/library_media_poster.dart"),
    ("lib/widgets/telegram_file_playback_actions.dart", "lib/widgets/telegram_file_playback_actions.dart"),
    ("lib/core/theme/app_theme.dart", "lib/core/theme/app_theme.dart"),
]

for src, dest in missing_files:
    src_path = os.path.join(plezy_dir, src)
    dest_path = os.path.join(base_dir, dest)
    if os.path.exists(src_path):
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        shutil.copy2(src_path, dest_path)
        print(f"Copied {src_path} to {dest_path}")
    else:
        print(f"Could NOT find {src_path}")

# File modifications
replacements = [
    {
        "file": "lib/database/app_database.dart",
        "replacements": [
            (r"import '../data/models/download_models.dart';", "import '../models/download_models.dart';")
        ]
    },
    {
        "file": "lib/database/download_operations.dart",
        "replacements": [
            (r"import '../data/models/download_models.dart';", "import '../models/download_models.dart';")
        ]
    },
    {
        "file": "lib/core/focus/input_mode_tracker.dart",
        "replacements": [
            (r"import '../services/companion_remote/companion_remote_receiver.dart';", "import '../../services/companion_remote/companion_remote_receiver.dart';")
        ]
    },
    {
        "file": "lib/widgets/oxplayer_button.dart",
        "replacements": [
            (r"import 'focus_theme.dart';", "import '../core/focus/focus_theme.dart';"),
            (r"import 'focusable_wrapper.dart';", "import '../core/focus/focusable_wrapper.dart';"),
            (r"import 'input_mode_tracker.dart';", "import '../core/focus/input_mode_tracker.dart';")
        ]
    },
    {
        "file": "lib/infrastructure/telegram/tdlib_controller.dart",
        "replacements": [
            (r"import '../core/config/app_config.dart';", "import '../../core/config/app_config.dart';"),
            (r"import '../core/debug/app_debug_log.dart';", "import '../../core/debug/app_debug_log.dart';")
        ]
    },
    {
        "file": "lib/player/vlc_install_prompt.dart",
        "replacements": [
            (r"import '../core/theme/oxplayer_button.dart';", "import '../widgets/oxplayer_button.dart';")
        ]
    },
    {
        "file": "lib/features/sources/source_chat_media_screen.dart",
        "replacements": [
            (r"import '../../core/theme/oxplayer_button.dart';", "import '../../widgets/oxplayer_button.dart';")
        ]
    },
    {
        "file": "lib/features/sources/source_picker_screen.dart",
        "replacements": [
            (r"import '../../core/theme/oxplayer_button.dart';", "import '../../widgets/oxplayer_button.dart';")
        ]
    }
]

for rep in replacements:
    file_path = os.path.join(base_dir, rep["file"])
    if os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8") as f:
            content = f.read()
        
        for old, new in rep["replacements"]:
            content = content.replace(old, new)
            
        with open(file_path, "w", encoding="utf-8") as f:
            f.write(content)
        print(f"Updated imports in {rep['file']}")
    else:
        print(f"File not found: {file_path}")
