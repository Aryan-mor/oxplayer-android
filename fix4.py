import os

for root, dirs, files in os.walk('lib'):
    for f in files:
        if f.endswith('.dart'):
            fp = os.path.join(root, f)
            with open(fp, 'r', encoding='utf-8') as file:
                c = file.read()
            nc = c.replace('package:plezy/', 'package:oxplayer/')
            if nc != c:
                with open(fp, 'w', encoding='utf-8') as file:
                    file.write(nc)
