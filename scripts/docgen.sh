#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local WORK_DIR_OPTION
  local WORK_DIR
  local INPUT_PATH
  local RESOLVED_INPUT_PATH
  local ADOC_FILE
  local ADOC_FILE_BASE64
  local ADOC_FILES_RESULT
  local WATCH_PATH
  local RESOLVED_WATCH_PATH
  local INITIAL_BUILD_FAILED
  local -a INPUT_PATHS
  local -a RESOLVED_INPUT_PATHS
  local -a ADOC_FILES
  local -a WATCH_PATHS
  local -a RESOLVED_WATCH_FILES
  local -a RESOLVED_WATCH_DIRS
  local -a GENERATOR_ARGS
  local -a WATCH_ARGS

  WORK_DIR_OPTION="."
  INPUT_PATHS=()
  RESOLVED_INPUT_PATHS=()
  ADOC_FILES=()
  WATCH_PATHS=()
  RESOLVED_WATCH_FILES=()
  RESOLVED_WATCH_DIRS=()
  GENERATOR_ARGS=()
  WATCH_ARGS=()

  APP_NAME="${0##*/}"
  WATCH_MODE=0

  : "${DOCGEN_COMMAND:?DOCGEN_COMMAND is not set}"
  : "${DOCGEN_PDF_GENERATOR:?DOCGEN_PDF_GENERATOR is not set}"

  [[ -x "${DOCGEN_PDF_GENERATOR}" ]] ||
    die "PDF generator is not executable: ${DOCGEN_PDF_GENERATOR}"

  #
  # Internal mode used by watchexec.
  #
  if [[ "${DOCGEN_WATCH_DISPATCH:-0}" == 1 ]]; then
    dispatch_watch_events "${@}"
    return
  fi

  OPTS="$(
    getopt \
      --name "${APP_NAME}" \
      --options 'C:f:s:i:a:h' \
      --longoptions "$(
        printf '%s' \
          'directory:,' \
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
      -C|--directory)
        WORK_DIR_OPTION="${2}"
        shift 2
        ;;
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

  if ((${#WATCH_PATHS[@]} > 0)) && (( ! WATCH_MODE )); then
    die "--watch-path requires --watch"
  fi

  [[ -d "${WORK_DIR_OPTION}" ]] ||
    die "working directory does not exist or is not a directory: ${WORK_DIR_OPTION}"

  WORK_DIR="$(realpath -- "${WORK_DIR_OPTION}")"

  #
  # From this point on all relative paths are interpreted relative to
  # the selected working directory, similar to "git -C DIR".
  #
  cd -- "${WORK_DIR}"

  if (($# == 0)); then
    INPUT_PATHS=("${PWD}")
  else
    INPUT_PATHS=("${@}")
  fi

  #
  # Validate and resolve all input selections.
  #
  for INPUT_PATH in "${INPUT_PATHS[@]}"; do
    [[ -e "${INPUT_PATH}" ]] ||
      die "input path does not exist: ${INPUT_PATH}"

    RESOLVED_INPUT_PATH="$(realpath -- "${INPUT_PATH}")"

    require_below_work_dir \
      "${WORK_DIR}" \
      "${RESOLVED_INPUT_PATH}" \
      "input path"

    require_non_hidden_path \
      "${WORK_DIR}" \
      "${RESOLVED_INPUT_PATH}" \
      "input path"

    if [[ -d "${RESOLVED_INPUT_PATH}" ]]; then
      :
    elif [[ -f "${RESOLVED_INPUT_PATH}" &&
            "${RESOLVED_INPUT_PATH}" == *.adoc ]]
    then
      :
    else
      die "input path must be a directory or an .adoc file: ${INPUT_PATH}"
    fi

    RESOLVED_INPUT_PATHS+=("${RESOLVED_INPUT_PATH}")
  done

  #
  # Resolve all selected documents.
  #
  # find emits NUL-separated paths so whitespace and newlines in path
  # names do not delimit entries. jq turns them into line-safe Base64
  # values and also removes duplicates caused by overlapping selections.
  #
  ADOC_FILES_RESULT="$(
    find "${RESOLVED_INPUT_PATHS[@]}" \
      \( -type d -name '.*' -prune \) -o \
      \( -type f -name '*.adoc' ! -name '.*' -print0 \) |
        jq -Rsr 'split("\u0000")[:-1] | unique[] | @base64'
  )"

  while IFS= read -r ADOC_FILE_BASE64; do
    [[ -n "${ADOC_FILE_BASE64}" ]] || continue
    ADOC_FILE="$(printf '%s' "${ADOC_FILE_BASE64}" | base64 --decode && printf '\034')"
    ADOC_FILE="${ADOC_FILE%$'\034'}"
    ADOC_FILES+=("${ADOC_FILE}")
  done <<< "${ADOC_FILES_RESULT}"

  if ((${#ADOC_FILES[@]} == 0)); then
    die "no .adoc files found in selected input paths"
  fi

  #
  # The workspace root is also the wrapper-specific input root used by
  # docgen-pdf, e.g. for themes/default-theme.yml.
  #
  # This does not modify Asciidoctor's base directory.
  #
  GENERATOR_ARGS+=(--input-root "${WORK_DIR}")

  #
  # Normal generation: let the PDF generator process the selected
  # documents directly.
  #
  if (( ! WATCH_MODE )); then
    exec "${DOCGEN_PDF_GENERATOR}" \
      "${GENERATOR_ARGS[@]}" \
      "${ADOC_FILES[@]}"
  fi

  : "${DOCGEN_COMMAND:?DOCGEN_COMMAND is not set}"

  [[ -x "${DOCGEN_COMMAND}" ]] ||
    die "docgen command is not executable: ${DOCGEN_COMMAND}"

  #
  # Validate, resolve, and classify explicitly requested watch paths.
  #
  # Their type is remembered now so that a later removal event does not
  # make the dispatcher dependent on the path still existing.
  #
  for WATCH_PATH in "${WATCH_PATHS[@]}"; do
    [[ -e "${WATCH_PATH}" ]] ||
      die "watch path does not exist: ${WATCH_PATH}"

    RESOLVED_WATCH_PATH="$(realpath -- "${WATCH_PATH}")"

    require_below_work_dir \
      "${WORK_DIR}" \
      "${RESOLVED_WATCH_PATH}" \
      "watch path"

    require_non_hidden_path \
      "${WORK_DIR}" \
      "${RESOLVED_WATCH_PATH}" \
      "watch path"

    if [[ -d "${RESOLVED_WATCH_PATH}" ]]; then
      RESOLVED_WATCH_DIRS+=("${RESOLVED_WATCH_PATH}")
    else
      RESOLVED_WATCH_FILES+=("${RESOLVED_WATCH_PATH}")
    fi
  done

  #
  # Initial preview build.
  #
  # Build each document independently so a temporarily invalid document
  # does not prevent the remaining previews from being generated.
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
    printf \
      'One or more initial preview builds failed; continuing to watch.\n' \
      >&2
  fi

  printf 'Watching %d document(s) below %s. Press Ctrl-C to stop.\n' \
    "${#ADOC_FILES[@]}" \
    "${WORK_DIR}" >&2

  #
  # One watchexec instance watches all concrete input documents.
  #
  # Input directories themselves are intentionally not watched. The set
  # of selected documents therefore remains fixed until docgen is
  # restarted.
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
  # docgen is replaced by watchexec. Bash therefore does not supervise
  # any long-running child processes.
  #
  # Watchexec starts DOCGEN_COMMAND in internal dispatch mode for each
  # debounced event batch and supplies that batch as JSON on stdin.
  #
  exec watchexec \
    --postpone \
    --debounce=250ms \
    --on-busy-update=queue \
    --ignore-nothing \
    --ignore '**/.*' \
    --ignore '**/.*/**' \
    --ignore '**/*.pdf' \
    --emit-events-to=json-stdio \
    --shell=none \
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

function require_below_work_dir {
  local WORK_DIR="${1}"
  local PATH_TO_CHECK="${2}"
  local PATH_DESCRIPTION="${3}"
  local RELATIVE_PATH

  RELATIVE_PATH="$(
    realpath \
      --relative-to="${WORK_DIR}" \
      -- "${PATH_TO_CHECK}"
  )"

  case "${RELATIVE_PATH}" in
    ..|../*)
      die "${PATH_DESCRIPTION} is outside working directory: ${PATH_TO_CHECK}"
      ;;
  esac
}

function require_non_hidden_path {
  local WORK_DIR="${1}"
  local PATH_TO_CHECK="${2}"
  local PATH_DESCRIPTION="${3}"
  local RELATIVE_PATH

  RELATIVE_PATH="$(
    realpath \
      --relative-to="${WORK_DIR}" \
      -- "${PATH_TO_CHECK}"
  )"

  if [[ "${RELATIVE_PATH}" != "." &&
        ( "${RELATIVE_PATH}" == .* ||
          "${RELATIVE_PATH}" == */.* ) ]]
  then
    die \
      "${PATH_DESCRIPTION} contains a hidden path component: ${PATH_TO_CHECK}"
  fi
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
  # Selected input documents.
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
  # Explicitly watched files.
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
  # Explicitly watched directories.
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
  # Arguments forwarded to docgen-pdf.
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
  # Watchexec emits one JSON object per event on stdin.
  #
  # Extract and deduplicate all absolute filesystem paths from the
  # complete debounced event batch.
  #
  EVENT_PATHS_RESULT="$(
    jq -rs -r '
      [
        .[]
        | .tags[]?
        | select(.kind == "path")
        | .absolute?
        | select(type == "string")
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
    # An explicitly watched file represents an unknown dependency.
    # Therefore every selected document must be rebuilt.
    #
    for WATCH_PATH in "${WATCH_FILES[@]}"; do
      if [[ "${EVENT_PATH}" == "${WATCH_PATH}" ]]; then
        BUILD_ALL=1
        break
      fi
    done

    (( BUILD_ALL )) && continue

    #
    # The same applies to the directory itself and every path below an
    # explicitly watched directory.
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
    # Otherwise, an event for a concrete selected input document only
    # rebuilds that document.
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
  ${APP_NAME} [OPTIONS] [INPUT_PATH ...]

INPUT_PATH may be an .adoc file or a directory. Directories are searched
recursively for non-hidden .adoc files. Multiple input paths may be specified.
Overlapping selections are deduplicated.

If no input path is specified, the working directory is used.

All input paths and additional watch paths must be located below the working
directory after resolving symbolic links.

Options:
  -C, --directory DIR
      Change to DIR before resolving input paths, watch paths, and other
      relative paths. Default: current working directory.

  -f, --failure-level LEVEL
      Failure level. Default: WARN

  -s, --safe-mode MODE
      Safe mode. Default: unsafe

  -i, --images-dir DIR
      Static image directory. Relative paths are resolved from the working
      directory.

  -a, --attribute ATTRIBUTE
      Pass an attribute to asciidoctor-pdf. Repeatable.

      --watch
      Rebuild PDFs automatically when watched files change.

      Direct changes to selected .adoc documents rebuild only the affected
      documents.

      --watch-path PATH
      Watch an additional file or directory. May be specified multiple times.
      Requires --watch. Relative paths are resolved from the working directory.

      A change to an additional watch path causes all selected documents to be
      rebuilt.

      --no-image-collection
      Do not collect images in a temporary directory.

      --no-theme-discovery
      Do not automatically use WORK_DIR/themes/default-theme.yml as theme file.

      --keep-temp
      Keep the temporary directory used by the PDF generator.

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
  The set of selected .adoc files is determined when the command starts.
  Input directories themselves are not watched for newly created documents.

  One watchexec process watches all selected input documents and all explicit
  --watch-path entries.

  A direct change to one or more selected input documents rebuilds only those
  documents. A change to an additional --watch-path rebuilds every selected
  document.

  Hidden paths and generated PDF files are ignored.

  Preview builds are independent. A failed document does not prevent other
  affected documents from being generated, and failed builds do not stop
  watching.
_EOI_
}

main "$@"
exit 0
