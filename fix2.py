import os

def fix(f):
    with open(f, 'r', encoding='utf-8') as file:
        c = file.read()
    c = c.replace("import '../../infrastructure/mocks/widgets/app_icon.dart';", "import '../../widgets/app_icon.dart';")
    c = c.replace("import '../../infrastructure/mocks/widgets/plex_optimized_image.dart'", "import '../../widgets/plex_optimized_image.dart'")
    c = c.replace("import '../../infrastructure/mocks/widgets/server_activities_button.dart'", "import '../../widgets/server_activities_button.dart'")
    with open(f, 'w', encoding='utf-8') as file:
        file.write(c)

fix('lib/features/home/discover_screen.dart')
fix('lib/features/home/home_screen.dart')
