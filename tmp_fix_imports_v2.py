import os
import re

lib_dir = r'c:\Users\Aryan\Documents\Projects\oxplayer-wrapper\oxplayer-android\lib'

def fix_file(path):
    with open(path, 'r', encoding='utf-8', errors='ignore') as f:
        content = f.read()
    
    new_content = content
    rel_path = os.path.relpath(path, lib_dir)
    
    # Check if file is in lib/infrastructure/api
    if rel_path.startswith('infrastructure' + os.sep + 'api'):
        # Fix relative imports to models -> data/models
        new_content = re.sub(r"import '\.\./models/", "import '../../data/models/", new_content)
    
    # Check if file is in lib/database
    if rel_path.startswith('database'):
        # Fix relative imports to models -> data/models
        new_content = re.sub(r"import '\.\./models/", "import '../data/models/", new_content)

    # General fixes for telegram (already done mostly, but for safety)
    new_content = re.sub(r"import 'telegram/", "import 'infrastructure/telegram/", new_content)
    new_content = re.sub(r"import '\.\./telegram/", "import '../infrastructure/telegram/", new_content)
    new_content = re.sub(r"import '\.\./\.\./telegram/", "import '../../infrastructure/telegram/", new_content)

    if new_content != content:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(new_content)
        print(f"Fixed imports in {rel_path}")

for root, dirs, files in os.walk(lib_dir):
    for name in files:
        if name.endswith('.dart'):
            fix_file(os.path.join(root, name))
