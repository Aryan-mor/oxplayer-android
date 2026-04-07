import os

files = [
    'lib/widgets/media_context_menu.dart',
    'lib/widgets/plex_optimized_image.dart',
    'lib/widgets/server_activities_button.dart',
    'lib/widgets/side_navigation_rail.dart',
    'lib/widgets/media_card.dart'
]

for f in files:
    if os.path.exists(f):
        with open(f, 'r', encoding='utf-8') as file:
            c = file.read()
        c = c.replace('package:plezy/', 'package:oxplayer/')
        with open(f, 'w', encoding='utf-8') as file:
            file.write(c)
