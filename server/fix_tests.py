#!/usr/bin/env python3
import re

# Read the file
with open('cast/handlers_test.go', 'r') as f:
    content = f.read()

# Replace the pattern
pattern = r'(\s+)store := NewJobStore\(\)\s+handler := NewHandler\(store\)'
replacement = r'\1store := NewJobStore()\n\1deviceStore := NewDeviceStore()\n\1handler := NewHandler(store, deviceStore)'

content = re.sub(pattern, replacement, content)

# Write back
with open('cast/handlers_test.go', 'w') as f:
    f.write(content)

print("Fixed all NewHandler calls")
