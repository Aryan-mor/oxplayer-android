import os
import re

def clone_and_fix(src, dest):
    with open(src, 'r', encoding='utf-8') as f:
        content = f.read()

    # In src, imports look like `import '../services/plex_client.dart';`
    # In dest (`lib/features/home/home_screen.dart`), they need to be `import '../../services/plex_client.dart';`
    # We will replace `../` with `../../` for all local imports.
    # Wait, `import 'discover_screen.dart';` is fine.
    # What about `import 'libraries/libraries_screen.dart';`? That should be `../../screens/libraries/libraries_screen.dart`
    
    lines = content.split('\n')
    new_lines = []
    for line in lines:
        if line.startswith('import '):
            if 'package:' not in line and not line.startswith("import 'dart:"):
                # If it's a sibling import (e.g., `import 'search_screen.dart';`), it should become `import '../../screens/search_screen.dart';`
                # If it's `import '../something'`, it should become `import '../../something'`
                match = re.search(r"import '([^']+)';", line)
                if match:
                    path = match.group(1)
                    if path.startswith('../'):
                        path = '../' + path
                    elif path == 'discover_screen.dart':
                        # discover_screen is also copied to features/home/
                        pass
                    else:
                        # sibling import from plezy's `screens` folder
                        path = '../../screens/' + path
                    line = f"import '{path}';"
        
        # Replace MainScreen with HomeScreen if it's the home screen
        if 'main_screen.dart' in src:
            line = line.replace('MainScreen', 'HomeScreen')
            line = line.replace('_MainScreenState', '_HomeScreenState')
        
        new_lines.append(line)

    with open(dest, 'w', encoding='utf-8') as f:
        f.write('\n'.join(new_lines))

clone_and_fix('refs/plezy/lib/screens/main_screen.dart', 'lib/features/home/home_screen.dart')
clone_and_fix('refs/plezy/lib/screens/discover_screen.dart', 'lib/features/home/discover_screen.dart')
