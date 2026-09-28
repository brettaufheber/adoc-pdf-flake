#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

if (( $# < 2 )); then
  printf 'Usage: %s OUTPUT_DIRECTORY FONT_PACKAGE...\n' "$0" >&2
  exit 2
fi

output_directory=$1
shift

mkdir -p "$output_directory"

collision_counter=0
font_list=$(mktemp)

cleanup() {
  local status=$?

  trap - EXIT
  rm -f -- "$font_list"
  exit "$status"
}

trap cleanup EXIT

for package in "$@"; do
  font_root="$package/share/fonts"

  if [[ ! -d "$font_root" ]]; then
    continue
  fi

  # Materialize the list first so a failure from find or sort is observed by
  # this shell instead of being hidden behind a process substitution.
  find -L "$font_root" \
    -type f \
    \( \
      -iname '*.otf' -o \
      -iname '*.ttf' -o \
      -iname '*.ttc' \
    \) \
    -print0 \
    | sort -z > "$font_list"

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
  done < "$font_list"
done
