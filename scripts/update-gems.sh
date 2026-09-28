#!/usr/bin/env bash
set -euo pipefail
shopt -s inherit_errexit

APP_NAME="${0##*/}"
readonly APP_NAME

BACKUP_DIRECTORY=""
GEMFILE=""
LOCKFILE=""
GEMSET=""
HAD_LOCKFILE=0
HAD_GEMSET=0
RESTORE_ON_ERROR=0

function main {
  local REPOSITORY_OPTION
  local REPOSITORY_ROOT
  local GEM_DIRECTORY
  local -a GEMS_TO_UPDATE=()

  REPOSITORY_OPTION="${ASCIIDOCTOR_TOOL_REPOSITORY:-}"

  while (($# > 0)); do
    case "${1}" in
      --repository)
        (($# >= 2)) ||
          die "--repository requires a path"

        REPOSITORY_OPTION="${2}"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        GEMS_TO_UPDATE+=("${@}")
        break
        ;;
      -*)
        die "unknown option: ${1}"
        ;;
      *)
        GEMS_TO_UPDATE+=("${1}")
        shift
        ;;
    esac
  done

  REPOSITORY_ROOT="$(resolve_repository_root "${REPOSITORY_OPTION}")"
  GEM_DIRECTORY="${REPOSITORY_ROOT}/nix/asciidoctor"
  GEMFILE="${GEM_DIRECTORY}/Gemfile"
  LOCKFILE="${GEM_DIRECTORY}/Gemfile.lock"
  GEMSET="${GEM_DIRECTORY}/gemset.nix"

  [[ -r "${GEMFILE}" ]] ||
    die "Gemfile not found or not readable: ${GEMFILE}"

  command -v bundle >/dev/null ||
    die "bundle is not available"

  command -v bundix >/dev/null ||
    die "bundix is not available"

  if [[ ! -e "${LOCKFILE}" ]] && ((${#GEMS_TO_UPDATE[@]} > 0)); then
    die \
      "selective updates require an existing Gemfile.lock; run without GEM arguments first"
  fi

  BACKUP_DIRECTORY="$(mktemp -d)"
  trap cleanup EXIT

  if [[ -e "${LOCKFILE}" ]]; then
    cp -p -- \
      "${LOCKFILE}" \
      "${BACKUP_DIRECTORY}/Gemfile.lock"
    HAD_LOCKFILE=1
  fi

  if [[ -e "${GEMSET}" ]]; then
    cp -p -- \
      "${GEMSET}" \
      "${BACKUP_DIRECTORY}/gemset.nix"
    HAD_GEMSET=1
  fi

  # Only restore after all backups have been created successfully. Before this
  # point no dependency file has been modified.
  RESTORE_ON_ERROR=1

  cd -- "${GEM_DIRECTORY}"

  export BUNDLE_GEMFILE="${GEMFILE}"

  # Prefer source gems so Bundix can describe portable Ruby builds instead of
  # locking precompiled gems for only the current host platform.
  export BUNDLE_FORCE_RUBY_PLATFORM=true

  if [[ -e "${LOCKFILE}" ]]; then
    if ((${#GEMS_TO_UPDATE[@]} > 0)); then
      printf 'Updating selected Ruby gems:\n'
      printf '  %s\n' "${GEMS_TO_UPDATE[@]}"

      bundle lock \
        --update "${GEMS_TO_UPDATE[@]}"
    else
      printf 'Updating all Ruby gems allowed by Gemfile constraints.\n'
      bundle lock --update
    fi
  else
    printf 'Creating Gemfile.lock for the first time.\n'
    bundle lock
  fi

  # Ensure that the generic Ruby platform is represented in the lockfile.
  bundle lock --add-platform ruby

  [[ -s "${LOCKFILE}" ]] ||
    die "Bundler did not produce a valid Gemfile.lock"

  # Avoid accidentally retaining a stale gemset if Bundix fails.
  rm -f -- "${GEMSET}"

  printf 'Generating gemset.nix.\n'
  bundix

  [[ -s "${GEMSET}" ]] ||
    die "Bundix did not produce a valid gemset.nix"

  printf '\nRuby dependency files updated successfully:\n'
  printf '  %s\n' "${LOCKFILE}" "${GEMSET}"
}

function resolve_repository_root {
  local REPOSITORY_OPTION="${1}"
  local SCRIPT_DIRECTORY
  local CANDIDATE
  local GIT_ROOT

  if [[ -n "${REPOSITORY_OPTION}" ]]; then
    CANDIDATE="${REPOSITORY_OPTION}"
  elif [[ -f "${PWD}/nix/asciidoctor/Gemfile" ]]; then
    CANDIDATE="${PWD}"
  else
    SCRIPT_DIRECTORY="$(realpath -- "$(dirname -- "${BASH_SOURCE[0]}")")"
    CANDIDATE="$(realpath -- "${SCRIPT_DIRECTORY}/..")"

    if [[ ! -f "${CANDIDATE}/nix/asciidoctor/Gemfile" ]]; then
      if GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" &&
        [[ -f "${GIT_ROOT}/nix/asciidoctor/Gemfile" ]]
      then
        CANDIDATE="${GIT_ROOT}"
      else
        die \
          "repository root could not be found; use --repository PATH"
      fi
    fi
  fi

  [[ -d "${CANDIDATE}" ]] ||
    die "repository does not exist: ${CANDIDATE}"

  realpath -- "${CANDIDATE}"
}

# shellcheck disable=SC2317,SC2329
# Called indirectly via: trap cleanup EXIT
function cleanup {
  local EXIT_STATUS="${?}"

  trap - EXIT

  if (( EXIT_STATUS != 0 && RESTORE_ON_ERROR )); then
    printf '\nRuby dependency update failed; restoring previous files.\n' >&2

    if (( HAD_LOCKFILE )); then
      cp -p -- \
        "${BACKUP_DIRECTORY}/Gemfile.lock" \
        "${LOCKFILE}"
    else
      rm -f -- "${LOCKFILE}"
    fi

    if (( HAD_GEMSET )); then
      cp -p -- \
        "${BACKUP_DIRECTORY}/gemset.nix" \
        "${GEMSET}"
    else
      rm -f -- "${GEMSET}"
    fi
  fi

  if [[ -n "${BACKUP_DIRECTORY}" && -d "${BACKUP_DIRECTORY}" ]]; then
    rm -rf -- "${BACKUP_DIRECTORY}"
  fi

  exit "${EXIT_STATUS}"
}

function die {
  printf '%s - Error: %s\n' "${APP_NAME}" "${*}" >&2
  printf 'Try "%s --help" for usage.\n' "${APP_NAME}" >&2
  exit 1
}

function usage {
  cat <<_EOI_
Usage:
  ${APP_NAME} [--repository PATH] [GEM...]

Description:
  Creates or updates:

    nix/asciidoctor/Gemfile.lock
    nix/asciidoctor/gemset.nix

  When Gemfile.lock does not exist, it is created.

  When Gemfile.lock already exists:
    - without GEM arguments, all permitted gems are updated;
    - with GEM arguments, only those gems and their dependencies are updated.

Examples:
  ${APP_NAME}
  ${APP_NAME} asciidoctor-pdf rouge
  ${APP_NAME} --repository /path/to/tool-repository
_EOI_
}

main "${@}"
exit 0
