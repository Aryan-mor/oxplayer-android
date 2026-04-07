import os

def fix_all_imports(dir_path):
    for root, dirs, files in os.walk(dir_path):
        for file in files:
            if file.endswith('.dart'):
                file_path = os.path.join(root, file)
                with open(file_path, 'r', encoding='utf-8') as f:
                    content = f.read()
                
                new_content = content.replace('package:plezy/', 'package:oxplayer/')
                
                if content != new_content:
                    with open(file_path, 'w', encoding='utf-8') as f:
                        f.write(new_content)

fix_all_imports('lib')
