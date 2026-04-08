import os
import re

lib_dir = r'c:\Users\Aryan\Documents\Projects\oxplayer-wrapper\oxplayer-android\lib'

# Patterns to find and replace
replacements = [
    (re.compile(r"import 'telegram/"), "import 'infrastructure/telegram/"),
    (re.compile(r"import '../telegram/"), "import '../infrastructure/telegram/"),
    (re.compile(r"import '../../telegram/"), "import '../../infrastructure/telegram/"),
    # Fix input_mode_tracker.dart gamepad_service import specifically if needed
    (re.compile(r"import '\.\./services/gamepad_service\.dart'"), "import '../../services/gamepad_service.dart'"),
]

for root, dirs, files in os.walk(lib_dir):
    for name in files:
        if name.endswith('.dart'):
            path = os.path.join(root, name)
            with open(path, 'r', encoding='utf-8', errors='ignore') as f:
                content = f.read()
            
            new_content = content
            for pattern, replacement in replacements:
                new_content = pattern.sub(replacement, new_content)
            
            if new_content != content:
                with open(path, 'w', encoding='utf-8') as f:
                    f.write(new_content)
                print(f"Fixed imports in {os.path.relpath(path, lib_dir)}")
