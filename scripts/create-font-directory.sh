#!/usr/bin/env bash
set -euo pipefail

if (( $# < 2 )); then
  printf 'Usage: %s OUTPUT_DIRECTORY FONT_PACKAGE...\n' "$0" >&2
  exit 2
fi

output_directory=$1
shift

mkdir -p "$output_directory"

collision_counter=0

for package in "$@"; do
  font_root="$package/share/fonts"

  if [[ ! -d "$font_root" ]]; then
    continue
  fi

  while IFS= read -r -d '' font_file; do
    filename=$(basename "$font_file")
    destination="$output_directory/$filename"

    # Der erste Font behält seinen ursprünglichen Dateinamen.
    # Bei Namenskollisionen erhält der weitere Font einen eindeutigen Namen.
    if [[ -e "$destination" ]]; then
      collision_counter=$((collision_counter + 1))

      if [[ "$filename" == *.* ]]; then
        stem=${filename%.*}
        extension=${filename##*.}
        destination="$output_directory/${stem}-${collision_counter}.${extension}"
      else
        destination="$output_directory/${filename}-${collision_counter}"
      fi
    fi

    ln -s "$font_file" "$destination"
  done < <(
    find -L "$font_root" \
      -type f \
      \( \
        -iname '*.otf' -o \
        -iname '*.ttf' -o \
        -iname '*.ttc' \
      \) \
      -print0 \
      | sort -z
  )
done
