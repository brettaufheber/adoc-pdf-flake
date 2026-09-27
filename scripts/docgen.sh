#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local INPUT_PATH
  local INPUT_ROOT
  local ADOC_FILE
  local ADOC_FILE_BASE64
  local ADOC_FILES_RESULT
  local WATCH_PATH
  local RESOLVED_WATCH_PATH
  local INITIAL_BUILD_FAILED
  local -a ADOC_FILES
  local -a WATCH_PATHS
  local -a GENERATOR_ARGS
  local -a WATCH_ARGS
  local -a RESOLVED_WATCH_FILES
  local -a RESOLVED_WATCH_DIRS

  ADOC_FILES=()
  WATCH_PATHS=()
  GENERATOR_ARGS=()
  WATCH_ARGS=()
  RESOLVED_WATCH_FILES=()
  RESOLVED_WATCH_DIRS=()

  APP_NAME="${0##*/}"
  WATCH_MODE=0

  : "${DOCGEN_COMMAND:?DOCGEN_COMMAND is not set}"
  : "${DOCGEN_PDF_GENERATOR:?DOCGEN_PDF_GENERATOR is not set}"

  #
  # Internal mode used by watchexec.
  #
  # Watchexec owns this process and provides one debounced event batch
  # as JSON objects on stdin.
  #
  if [[ "${DOCGEN_WATCH_DISPATCH:-0}" == 1 ]]; then
    dispatch_watch_events "${@}"
    return
  fi

  OPTS="$(
    getopt \
      --name "${APP_NAME}" \
      --options 'f:s:i:a:h' \
      --longoptions "$(
        printf '%s' \
          'failure-level:,' \
          'safe-mode:,' \
          'images-dir:,' \
          'attribute:,' \
          'watch,' \
          'watch-path:,' \
          'no-image-collection,' \
          'no-theme-discovery,' \
          'keep-temp,' \
          'help'
      )" \
      -- "${@}"
  )"

  eval set -- "${OPTS}"

  while true; do
    case "${1}" in
      -f|--failure-level)
        GENERATOR_ARGS+=(--failure-level "${2}")
        shift 2
        ;;
      -s|--safe-mode)
        GENERATOR_ARGS+=(--safe-mode "${2}")
        shift 2
        ;;
      -i|--images-dir)
        GENERATOR_ARGS+=(--images-dir "${2}")
        shift 2
        ;;
      -a|--attribute)
        GENERATOR_ARGS+=(--attribute "${2}")
        shift 2
        ;;
      --watch)
        WATCH_MODE=1
        shift
        ;;
      --watch-path)
        WATCH_PATHS+=("${2}")
        shift 2
        ;;
      --no-image-collection)
        GENERATOR_ARGS+=(--no-image-collection)
        shift
        ;;
      --no-theme-discovery)
        GENERATOR_ARGS+=(--no-theme-discovery)
        shift
        ;;
      --keep-temp)
        GENERATOR_ARGS+=(--keep-temp)
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  if (($# > 1)); then
    die "only one input path may be specified"
  fi

  if ((${#WATCH_PATHS[@]} > 0)) && (( ! WATCH_MODE )); then
    die "--watch-path requires --watch"
  fi

  INPUT_PATH="${1:-${PWD}}"

  [[ -e "${INPUT_PATH}" ]] ||
    die "input path does not exist: ${INPUT_PATH}"

  INPUT_PATH="$(realpath -- "${INPUT_PATH}")"

  if [[ -d "${INPUT_PATH}" ]]; then
    INPUT_ROOT="${INPUT_PATH}"
  elif [[ -f "${INPUT_PATH}" && "${INPUT_PATH}" == *.adoc ]]; then
    INPUT_ROOT="$(dirname -- "${INPUT_PATH}")"
  else
    die "input path must be a directory or an .adoc file: ${INPUT_PATH}"
  fi

  ADOC_FILES_RESULT="$(
    find "${INPUT_PATH}" \
      \( -type d -path '*/.*' -prune \) -o \
      \( -type f -name '*.adoc' ! -path '*/.*' -print0 \) |
        jq -Rsr 'split("\u0000")[:-1][] | @base64'
  )"

  while IFS= read -r ADOC_FILE_BASE64; do
    [[ -n "${ADOC_FILE_BASE64}" ]] || continue
    ADOC_FILE="$(printf '%s' "${ADOC_FILE_BASE64}" | base64 --decode)"
  done <<< "${ADOC_FILES_RESULT}"

  if ((${#ADOC_FILES[@]} == 0)); then
    die "no .adoc files found below input path: ${INPUT_PATH}"
  fi

  GENERATOR_ARGS+=(--input-root "${INPUT_ROOT}")

  # normal generation does not need watchexec or a dispatcher
  if (( ! WATCH_MODE )); then
    exec "${DOCGEN_PDF_GENERATOR}" \
      "${GENERATOR_ARGS[@]}" \
      "${ADOC_FILES[@]}"
  fi

  #
  # Resolve and classify additional watch paths once. Their type must
  # remain stable even if a later filesystem event removes the path.
  #
  for WATCH_PATH in "${WATCH_PATHS[@]}"; do
    [[ -e "${WATCH_PATH}" ]] ||
      die "watch path does not exist: ${WATCH_PATH}"

    RESOLVED_WATCH_PATH="$(realpath -- "${WATCH_PATH}")"

    if [[ -d "${RESOLVED_WATCH_PATH}" ]]; then
      RESOLVED_WATCH_DIRS+=("${RESOLVED_WATCH_PATH}")
    else
      RESOLVED_WATCH_FILES+=("${RESOLVED_WATCH_PATH}")
    fi
  done

  #
  # In preview mode each document is generated independently. A broken
  # document therefore does not prevent the other documents from being
  # generated.
  #
  INITIAL_BUILD_FAILED=0

  for ADOC_FILE in "${ADOC_FILES[@]}"; do
    if ! "${DOCGEN_PDF_GENERATOR}" \
        "${GENERATOR_ARGS[@]}" \
        "${ADOC_FILE}"
    then
      INITIAL_BUILD_FAILED=1
    fi
  done

  if (( INITIAL_BUILD_FAILED )); then
    printf 'One or more initial preview builds failed; continuing to watch.\n' >&2
  fi

  printf 'Watching %d document(s). Press Ctrl-C to stop.\n' \
    "${#ADOC_FILES[@]}" >&2

  #
  # A single watchexec instance watches every selected input document
  # and every explicitly requested additional path.
  #
  for ADOC_FILE in "${ADOC_FILES[@]}"; do
    WATCH_ARGS+=(
      --watch "${ADOC_FILE}"
    )
  done

  for RESOLVED_WATCH_PATH in "${RESOLVED_WATCH_FILES[@]}"; do
    WATCH_ARGS+=(
      --watch "${RESOLVED_WATCH_PATH}"
    )
  done

  for RESOLVED_WATCH_PATH in "${RESOLVED_WATCH_DIRS[@]}"; do
    WATCH_ARGS+=(
      --watch "${RESOLVED_WATCH_PATH}"
    )
  done

  #
  # The internal dispatcher receives a frozen description of:
  #
  #   - selected input documents
  #   - additional watched files
  #   - additional watched directories
  #   - arguments for docgen-pdf
  #
  # Counts delimit the arrays without introducing separator characters,
  # so argument values may themselves contain whitespace or newlines.
  #
  exec watchexec \
    --postpone \
    --debounce 250ms \
    --on-busy-update queue \
    --ignore-nothing \
    --ignore '**/.*' \
    --ignore '**/.*/**' \
    --ignore '**/*.pdf' \
    --emit-events-to=json-stdio \
    --shell none \
    "${WATCH_ARGS[@]}" \
    --env DOCGEN_WATCH_DISPATCH=1 \
    -- \
    "${DOCGEN_COMMAND}" \
    "${#ADOC_FILES[@]}" \
    "${ADOC_FILES[@]}" \
    "${#RESOLVED_WATCH_FILES[@]}" \
    "${RESOLVED_WATCH_FILES[@]}" \
    "${#RESOLVED_WATCH_DIRS[@]}" \
    "${RESOLVED_WATCH_DIRS[@]}" \
    "${#GENERATOR_ARGS[@]}" \
    "${GENERATOR_ARGS[@]}"
}

function dispatch_watch_events {
  local ARG_COUNT
  local INDEX
  local EVENT_PATH
  local EVENT_PATH_BASE64
  local EVENT_PATHS_RESULT
  local ADOC_FILE
  local WATCH_PATH
  local BUILD_ALL
  local BUILD_FAILED
  local -a ADOC_FILES
  local -a WATCH_FILES
  local -a WATCH_DIRS
  local -a GENERATOR_ARGS
  local -A BUILD_FILES

  ADOC_FILES=()
  WATCH_FILES=()
  WATCH_DIRS=()
  GENERATOR_ARGS=()
  BUILD_FILES=()

  #
  # Read selected input documents.
  #
  ARG_COUNT="${1:-}"

  [[ "${ARG_COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal watch dispatch arguments"

  shift

  for ((INDEX = 0; INDEX < ARG_COUNT; INDEX += 1)); do
    (($# > 0)) ||
      die "incomplete internal watch dispatch arguments"

    ADOC_FILES+=("${1}")
    shift
  done

  #
  # Read explicitly watched files.
  #
  ARG_COUNT="${1:-}"

  [[ "${ARG_COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal watch dispatch arguments"

  shift

  for ((INDEX = 0; INDEX < ARG_COUNT; INDEX += 1)); do
    (($# > 0)) ||
      die "incomplete internal watch dispatch arguments"

    WATCH_FILES+=("${1}")
    shift
  done

  #
  # Read explicitly watched directories.
  #
  ARG_COUNT="${1:-}"

  [[ "${ARG_COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal watch dispatch arguments"

  shift

  for ((INDEX = 0; INDEX < ARG_COUNT; INDEX += 1)); do
    (($# > 0)) ||
      die "incomplete internal watch dispatch arguments"

    WATCH_DIRS+=("${1}")
    shift
  done

  #
  # Read generator arguments.
  #
  ARG_COUNT="${1:-}"

  [[ "${ARG_COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal watch dispatch arguments"

  shift

  for ((INDEX = 0; INDEX < ARG_COUNT; INDEX += 1)); do
    (($# > 0)) ||
      die "incomplete internal watch dispatch arguments"

    GENERATOR_ARGS+=("${1}")
    shift
  done

  (($# == 0)) ||
    die "unexpected internal watch dispatch arguments"

  #
  # Watchexec writes one JSON object per event to stdin and closes stdin
  # afterwards. Extract all absolute filesystem paths from this debounced
  # event batch, deduplicate them, and encode them for line-safe Bash
  # processing.
  #
  EVENT_PATHS_RESULT="$(
    jq -rsc '
      [
        .[]
        | .tags[]?
        | select(.kind == "path")
        | .absolute
      ]
      | unique[]
      | @base64
    '
  )"

  BUILD_ALL=0

  while IFS= read -r EVENT_PATH_BASE64; do
    [[ -n "${EVENT_PATH_BASE64}" ]] || continue

    EVENT_PATH="$(
      printf '%s' "${EVENT_PATH_BASE64}" |
        base64 --decode &&
        printf '\034'
    )"

    EVENT_PATH="${EVENT_PATH%$'\034'}"

    #
    # An explicitly watched file is an unknown dependency. Its change
    # therefore rebuilds every selected document.
    #
    for WATCH_PATH in "${WATCH_FILES[@]}"; do
      if [[ "${EVENT_PATH}" == "${WATCH_PATH}" ]]; then
        BUILD_ALL=1
        break
      fi
    done

    (( BUILD_ALL )) && continue

    #
    # The same applies to everything below an explicitly watched
    # directory, including the directory itself.
    #
    for WATCH_PATH in "${WATCH_DIRS[@]}"; do
      if [[ "${EVENT_PATH}" == "${WATCH_PATH}" ||
            "${EVENT_PATH}" == "${WATCH_PATH}/"* ]]
      then
        BUILD_ALL=1
        break
      fi
    done

    (( BUILD_ALL )) && continue

    #
    # Otherwise only a directly changed selected input document needs
    # to be rebuilt.
    #
    for ADOC_FILE in "${ADOC_FILES[@]}"; do
      if [[ "${EVENT_PATH}" == "${ADOC_FILE}" ]]; then
        BUILD_FILES["${ADOC_FILE}"]=1
        break
      fi
    done
  done <<< "${EVENT_PATHS_RESULT}"

  BUILD_FAILED=0

  if (( BUILD_ALL )); then
    for ADOC_FILE in "${ADOC_FILES[@]}"; do
      if ! "${DOCGEN_PDF_GENERATOR}" \
          "${GENERATOR_ARGS[@]}" \
          "${ADOC_FILE}"
      then
        BUILD_FAILED=1
      fi
    done
  else
    for ADOC_FILE in "${ADOC_FILES[@]}"; do
      if [[ -n "${BUILD_FILES["${ADOC_FILE}"]+x}" ]]; then
        if ! "${DOCGEN_PDF_GENERATOR}" \
            "${GENERATOR_ARGS[@]}" \
            "${ADOC_FILE}"
        then
          BUILD_FAILED=1
        fi
      fi
    done
  fi

  return "${BUILD_FAILED}"
}

function die {
  printf '%s - Error: %s\n' "${APP_NAME}" "$*" >&2
  printf 'Try "%s --help" for usage.\n' "${APP_NAME}" >&2
  exit 1
}

function usage {
  cat <<_EOI_
Usage:
  ${APP_NAME} [OPTIONS] [INPUT_PATH]

INPUT_PATH may be a directory or one .adoc file.
If omitted, the current working directory is used.

Options:
  -f, --failure-level LEVEL
      Failure level. Default: WARN

  -s, --safe-mode MODE
      Safe mode. Default: unsafe

  -i, --images-dir DIR
      Static image directory. Default: ./images

  -a, --attribute ATTRIBUTE
      Pass an attribute to asciidoctor-pdf. Repeatable.

      --watch
      Rebuild PDFs automatically when watched files change.

      Direct changes to selected .adoc documents rebuild only the
      affected documents.

      --watch-path PATH
      Watch an additional file or directory.
      May be specified multiple times. Requires --watch.

      A change to an additional watch path causes all selected
      documents to be rebuilt.

      --no-image-collection
      Do not collect images in a temporary directory.

      --no-theme-discovery
      Do not automatically use INPUT_ROOT/themes/default-theme.yml
      as theme file.

      --keep-temp
      Keep the temporary directory.

  -h, --help
      Show this help.

Extension detection:
  asciidoctor-bibtex
      Enabled by docgen-use-bibtex or any resolved bibtex-* attribute.

  asciidoctor-mathematical
      Enabled by docgen-use-mathematical or a supported stem value.

  asciidoctor-kroki
      Enabled by docgen-use-kroki or any resolved kroki-* attribute.

Watch mode:
  If INPUT_PATH is a directory, the set of input .adoc files is
  determined when the command starts.

  Each input document is watched independently. A change to one input
  document rebuilds only that document.

  Additional --watch-path files or directories are watched by every
  input document. Hidden paths and generated PDF files are ignored.

  A failed preview build does not stop watching. The last successfully
  generated PDF remains unchanged.
_EOI_
}

main "$@"
exit 0
