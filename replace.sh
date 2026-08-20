#!/bin/bash

# Check if 2 args are passed
if [ "$#" -ne 2 ]; then
    echo "Using: $0 <value_to_search> <value_to_replace>"
    exit 1
fi

SEARCH="$1"
REPLACE="$2"

echo "Replace of '$SEARCH' with '$REPLACE' in all files..."

# Check in all files (escludendo directory) and replace
find . -type f | while read -r file; do
    if grep -qF "$SEARCH" "$file" 2>/dev/null; then
        sed -i "s|$(echo "$SEARCH" | sed 's|[&/\]|\\&|g')|$(echo "$REPLACE" | sed 's|[&/\]|\\&|g')|g" "$file"
        echo "  Changed: $file"
    fi
done

echo "Done."
