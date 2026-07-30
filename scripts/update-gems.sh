#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-asciidoctor-gems.sh [--repository PATH] [GEM...]

Description:
  Creates or updates:

    nix/asciidoctor/Gemfile.lock
    nix/asciidoctor/gemset.nix

  When Gemfile.lock does not exist, it is created.

  When Gemfile.lock already exists:
    - without GEM arguments, all permitted gems are updated;
    - with GEM arguments, only those gems and their dependencies are updated.

Examples:
  update-asciidoctor-gems.sh
  update-asciidoctor-gems.sh asciidoctor-pdf rouge
  update-asciidoctor-gems.sh --repository /path/to/tool-repository
EOF
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

repository_root=${ASCIIDOCTOR_TOOL_REPOSITORY:-}
declare -a gems_to_update=()

while (( $# > 0 )); do
  case $1 in
    --repository)
      (( $# >= 2 )) || die "--repository requires a path"
      repository_root=$2
      shift 2
      ;;

    -h|--help)
      usage
      exit 0
      ;;

    --)
      shift
      gems_to_update+=("$@")
      break
      ;;

    -*)
      die "unknown option: $1"
      ;;

    *)
      gems_to_update+=("$1")
      shift
      ;;
  esac
done

resolve_repository_root() {
  local script_directory
  local candidate
  local git_root

  if [[ -n "$repository_root" ]]; then
    candidate=$repository_root

  elif [[ -f "$PWD/nix/asciidoctor/Gemfile" ]]; then
    candidate=$PWD

  else
    script_directory=$(
      cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
      pwd -P
    )

    candidate=$(
      cd -- "$script_directory/.."
      pwd -P
    )

    if [[ ! -f "$candidate/nix/asciidoctor/Gemfile" ]]; then
      if git_root=$(git rev-parse --show-toplevel 2>/dev/null) \
        && [[ -f "$git_root/nix/asciidoctor/Gemfile" ]]
      then
        candidate=$git_root
      else
        die \
          "repository root could not be found; use --repository PATH"
      fi
    fi
  fi

  [[ -d "$candidate" ]] \
    || die "repository does not exist: $candidate"

  (
    cd -- "$candidate"
    pwd -P
  )
}

repository_root=$(resolve_repository_root)

gem_directory="$repository_root/nix/asciidoctor"
gemfile="$gem_directory/Gemfile"
lockfile="$gem_directory/Gemfile.lock"
gemset="$gem_directory/gemset.nix"

[[ -r "$gemfile" ]] \
  || die "Gemfile not found or not readable: $gemfile"

command -v bundle >/dev/null \
  || die "bundle is not available"

command -v bundix >/dev/null \
  || die "bundix is not available"

backup_directory=$(mktemp -d)
had_lockfile=0
had_gemset=0

if [[ -e "$lockfile" ]]; then
  cp -p -- "$lockfile" "$backup_directory/Gemfile.lock"
  had_lockfile=1
fi

if [[ -e "$gemset" ]]; then
  cp -p -- "$gemset" "$backup_directory/gemset.nix"
  had_gemset=1
fi

cleanup() {
  local status=$?

  trap - EXIT

  if (( status != 0 )); then
    printf '\nRuby dependency update failed; restoring previous files.\n' >&2

    if (( had_lockfile )); then
      cp -p -- \
        "$backup_directory/Gemfile.lock" \
        "$lockfile"
    else
      rm -f -- "$lockfile"
    fi

    if (( had_gemset )); then
      cp -p -- \
        "$backup_directory/gemset.nix" \
        "$gemset"
    else
      rm -f -- "$gemset"
    fi
  fi

  rm -rf -- "$backup_directory"
  exit "$status"
}

trap cleanup EXIT

cd -- "$gem_directory"

export BUNDLE_GEMFILE="$gemfile"

# Prefer source gems so Bundix can describe portable Ruby builds instead of
# locking precompiled gems for only the current host platform.
export BUNDLE_FORCE_RUBY_PLATFORM=true

if [[ -e "$lockfile" ]]; then
  if (( ${#gems_to_update[@]} > 0 )); then
    printf 'Updating selected Ruby gems:\n'

    printf '  %s\n' "${gems_to_update[@]}"

    bundle lock \
      --update "${gems_to_update[@]}"
  else
    printf 'Updating all Ruby gems allowed by Gemfile constraints.\n'

    bundle lock --update
  fi
else
  if (( ${#gems_to_update[@]} > 0 )); then
    die \
      "selective updates require an existing Gemfile.lock; run without GEM arguments first"
  fi

  printf 'Creating Gemfile.lock for the first time.\n'

  bundle lock
fi

# Ensure that the generic Ruby platform is represented in the lockfile.
bundle lock --add-platform ruby

[[ -s "$lockfile" ]] \
  || die "Bundler did not produce a valid Gemfile.lock"

# Avoid accidentally retaining a stale gemset if Bundix fails.
rm -f -- "$gemset"

printf 'Generating gemset.nix.\n'

bundix

[[ -s "$gemset" ]] \
  || die "Bundix did not produce a valid gemset.nix"

printf '\nRuby dependency files updated successfully:\n'
printf '  %s\n' "$lockfile" "$gemset"
