#!/bin/bash
# Resolve Inja-style includes in migration files and concatenate them.
# Handles: /*{% include "../src/foo.sql" %}*/

set -e

process_file() {
    local file="$1"
    local dir
    dir=$(dirname "$file")

    while IFS= read -r line; do
        # Match /*{% include "path" %}*/
        if [[ "$line" =~ \/\*\{%\ include\ \"([^\"]+)\"\ %\}\*\/ ]]; then
            local include_path="${BASH_REMATCH[1]}"
            # Resolve relative to the file's directory
            local resolved="$dir/$include_path"
            if [[ -f "$resolved" ]]; then
                cat "$resolved"
            else
                echo "-- ERROR: include not found: $resolved" >&2
                exit 1
            fi
        else
            echo "$line"
        fi
    done < "$file"
}

# Process migration files in sort order
for f in $(ls migrate/*.sql | sort -V); do
    echo "-- $(basename "$f")"
    process_file "$f"
    echo ""
done
