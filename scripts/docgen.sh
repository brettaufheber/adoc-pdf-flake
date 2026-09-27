#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${0##*/}"
SLEF_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
readonly APP_NAME SLEF_PATH

function main {
  local OPTS
  local DEBOUNCE
  local WORK_DIR_OPTION
  local WORK_DIR
  local INPUT_PATH
  local RESOLVED_INPUT_PATH
  local ADOC_FILE
  local ADOC_FILE_BASE64
  local ADOC_FILES_RESULT
  local WATCH_PATH
  local RESOLVED_WATCH_PATH
  local -a INPUT_PATHS
  local -a RESOLVED_INPUT_PATHS
  local -a ADOC_FILES
  local -a WATCH_PATHS
  local -a RESOLVED_WATCH_FILES
  local -a RESOLVED_WATCH_DIRS
  local -a GENERATOR_ARGS
  local -a USER_ATTRIBUTES
  local -a WATCH_ARGS

  DEBOUNCE="250ms"
  WORK_DIR_OPTION="."
  INPUT_PATHS=()
  RESOLVED_INPUT_PATHS=()
  ADOC_FILES=()
  WATCH_PATHS=()
  RESOLVED_WATCH_FILES=()
  RESOLVED_WATCH_DIRS=()
  GENERATOR_ARGS=()
  USER_ATTRIBUTES=()
  WATCH_ARGS=()

  FAILURE_LEVEL="WARN"
  SAFE_MODE="unsafe"
  DISCOVER_THEME=1
  REMOVE_TEMP_DIR=1
  WATCH_MODE=0

  [[ -x "${SLEF_PATH}" ]] ||
    die "docgen command is not executable: ${SLEF_PATH}"

  # Internal mode used at the former docgen/docgen-generate-pdf boundary.
  if [[ "${DOCGEN_GENERATE:-0}" == 1 ]]; then
    generate_documents "${@}"
    return
  fi

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
      --options 'C:d:f:s:a:h' \
      --longoptions "$(
        printf '%s' \
          'directory:,' \
          'debounce:,' \
          'failure-level:,' \
          'safe-mode:,' \
          'attribute:,' \
          'watch,' \
          'watch-path:,' \
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
      -d|--debounce)
        DEBOUNCE="${2}"
        shift 2
        ;;
      -f|--failure-level)
        FAILURE_LEVEL="${2}"
        shift 2
        ;;
      -s|--safe-mode)
        SAFE_MODE="${2}"
        shift 2
        ;;
      -a|--attribute)
        USER_ATTRIBUTES+=(-a "${2}")
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
      --no-theme-discovery)
        DISCOVER_THEME=0
        shift
        ;;
      --keep-temp)
        REMOVE_TEMP_DIR=0
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
  # Serialize the normalized generator configuration for the internal
  # self-invocation. The element count keeps repeated attributes unambiguous.
  #
  GENERATOR_ARGS=(
    "${WORK_DIR}"
    "${FAILURE_LEVEL}"
    "${SAFE_MODE}"
    "${DISCOVER_THEME}"
    "${REMOVE_TEMP_DIR}"
    "${#USER_ATTRIBUTES[@]}"
    "${USER_ATTRIBUTES[@]}"
  )

  #
  # Preserve the former process boundary by invoking this script in its
  # internal generator mode.
  #
  if (( ! WATCH_MODE )); then
    run_pdf_generator \
      "${GENERATOR_ARGS[@]}" \
      "${ADOC_FILES[@]}"
    return
  fi

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
  # Initial preview build. Any generator failure aborts before the watcher
  # starts so its exit status is not hidden.
  #
  run_pdf_generator \
    "${GENERATOR_ARGS[@]}" \
    "${ADOC_FILES[@]}"

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
  # Watchexec starts this script in internal dispatch mode for each
  # debounced event batch and supplies that batch as JSON on stdin.
  #
  exec watchexec \
    --postpone \
    --exit-on-error \
    --debounce="${DEBOUNCE}" \
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
    "${SLEF_PATH}" \
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
  local -a ADOC_FILES
  local -a BUILD_ADOC_FILES
  local -a WATCH_FILES
  local -a WATCH_DIRS
  local -a GENERATOR_ARGS
  local -A BUILD_FILES

  ADOC_FILES=()
  BUILD_ADOC_FILES=()
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
        for ADOC_FILE in "${ADOC_FILES[@]}"; do
          BUILD_FILES["${ADOC_FILE}"]=1
        done

        continue 2
      fi
    done

    #
    # The same applies to the directory itself and every path below an
    # explicitly watched directory.
    #
    for WATCH_PATH in "${WATCH_DIRS[@]}"; do
      if [[ "${EVENT_PATH}" == "${WATCH_PATH}" ||
            "${EVENT_PATH}" == "${WATCH_PATH}/"* ]]
      then
        for ADOC_FILE in "${ADOC_FILES[@]}"; do
          BUILD_FILES["${ADOC_FILE}"]=1
        done

        continue 2
      fi
    done

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

  # Preserve the original document order when turning the selected set into
  # arguments for one generator invocation.
  for ADOC_FILE in "${ADOC_FILES[@]}"; do
    if [[ -n "${BUILD_FILES["${ADOC_FILE}"]+x}" ]]; then
      BUILD_ADOC_FILES+=("${ADOC_FILE}")
    fi
  done

  if ((${#BUILD_ADOC_FILES[@]} > 0)); then
    run_pdf_generator \
      "${GENERATOR_ARGS[@]}" \
      "${BUILD_ADOC_FILES[@]}"
  fi
}

function run_pdf_generator {
  DOCGEN_GENERATE=1 "${SLEF_PATH}" "${@}"
}

function generate_documents {
  local ARG_COUNT
  local INDEX
  local INPUT_FILE
  local RESOLVED_INPUT_FILE
  local INPUT_DIR
  local RELATIVE_INPUT_DIR
  local TEMP_GENERATED_ROOT
  local TEMP_DOCUMENT_DIR
  local -a INPUT_FILES
  local -a REQUESTED_INPUT_FILES
  local -a USER_ATTRIBUTES

  INPUT_FILES=()
  USER_ATTRIBUTES=()

  (($# >= 6)) ||
    die "incomplete internal generator arguments"

  WORK_DIR="${1}"
  FAILURE_LEVEL="${2}"
  SAFE_MODE="${3}"
  DISCOVER_THEME="${4}"
  REMOVE_TEMP_DIR="${5}"
  ARG_COUNT="${6}"
  shift 6

  [[ "${DISCOVER_THEME}" =~ ^[01]$ &&
     "${REMOVE_TEMP_DIR}" =~ ^[01]$ &&
     "${ARG_COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal generator arguments"

  ((ARG_COUNT % 2 == 0)) ||
    die "invalid internal generator attribute arguments"

  (($# >= ARG_COUNT + 1)) ||
    die "incomplete internal generator arguments"

  for ((INDEX = 0; INDEX < ARG_COUNT; INDEX += 1)); do
    USER_ATTRIBUTES+=("${1}")
    shift
  done

  REQUESTED_INPUT_FILES=("${@}")

  [[ -d "${WORK_DIR}" ]] ||
    die "working directory does not exist or is not a directory: ${WORK_DIR}"

  WORK_DIR="$(realpath -- "${WORK_DIR}")"
  cd -- "${WORK_DIR}"

  : "${DOCGEN_ATTRIBUTE_RESOLVE:?DOCGEN_ATTRIBUTE_RESOLVE is not set}"
  : "${DOCGEN_FEATURE_CHECK:?DOCGEN_FEATURE_CHECK is not set}"
  : "${DOCGEN_ASCIIDOCTOR_GEMFILE:?DOCGEN_ASCIIDOCTOR_GEMFILE is not set}"
  : "${DOCGEN_BUNDLE_COMMAND:?DOCGEN_BUNDLE_COMMAND is not set}"
  : "${DOCGEN_RUBY_COMMAND:?DOCGEN_RUBY_COMMAND is not set}"

  [[ -r "${DOCGEN_ATTRIBUTE_RESOLVE}" ]] ||
    die "attribute resolver is not readable: ${DOCGEN_ATTRIBUTE_RESOLVE}"

  [[ -r "${DOCGEN_FEATURE_CHECK}" ]] ||
    die "feature check is not readable: ${DOCGEN_FEATURE_CHECK}"

  [[ -r "${DOCGEN_ASCIIDOCTOR_GEMFILE}" ]] ||
    die "Asciidoctor Gemfile is not readable: ${DOCGEN_ASCIIDOCTOR_GEMFILE}"

  command -v "${DOCGEN_BUNDLE_COMMAND}" >/dev/null 2>&1 ||
    die "bundle command is not executable: ${DOCGEN_BUNDLE_COMMAND}"

  command -v "${DOCGEN_RUBY_COMMAND}" >/dev/null 2>&1 ||
    die "Ruby command is not executable: ${DOCGEN_RUBY_COMMAND}"

  command -v asciidoctor-pdf >/dev/null 2>&1 ||
    die "asciidoctor-pdf command is not executable"

  for INPUT_FILE in "${REQUESTED_INPUT_FILES[@]}"; do
    [[ "${INPUT_FILE}" == *.adoc ]] ||
      die "input must be an .adoc file: ${INPUT_FILE}"

    if [[ ! -e "${INPUT_FILE}" ]]; then
      warn_document_access "${INPUT_FILE}"
      continue
    fi

    [[ -f "${INPUT_FILE}" ]] ||
      die "input must be a regular .adoc file: ${INPUT_FILE}"

    if [[ ! -r "${INPUT_FILE}" ]]; then
      warn_document_access "${INPUT_FILE}"
      continue
    fi

    if ! RESOLVED_INPUT_FILE="$(realpath -- "${INPUT_FILE}" 2>/dev/null)"; then
      warn_document_access "${INPUT_FILE}"
      continue
    fi

    INPUT_FILE="${RESOLVED_INPUT_FILE}"

    require_below_work_dir \
      "${WORK_DIR}" \
      "${INPUT_FILE}" \
      "input file"

    INPUT_FILES+=("${INPUT_FILE}")
  done

  if ((${#INPUT_FILES[@]} == 0)); then
    return 0
  fi

  TEMP_DIR="$(mktemp -d -t asciidoctor-assets.XXXXXXXX)"
  trap cleanup EXIT

  TEMP_GENERATED_ROOT="${TEMP_DIR}/generated"
  mkdir -p -- "${TEMP_GENERATED_ROOT}"

  for INPUT_FILE in "${INPUT_FILES[@]}"; do
    INPUT_DIR="$(dirname -- "${INPUT_FILE}")"

    RELATIVE_INPUT_DIR="$(
      realpath \
        --relative-to="${WORK_DIR}" \
        -- "${INPUT_DIR}"
    )"

    TEMP_DOCUMENT_DIR="${TEMP_GENERATED_ROOT}"

    if [[ "${RELATIVE_INPUT_DIR}" != "." ]]; then
      TEMP_DOCUMENT_DIR+="/${RELATIVE_INPUT_DIR}"
    fi

    generate_pdf \
      "${TEMP_DOCUMENT_DIR}" \
      "${INPUT_FILE}" \
      "${USER_ATTRIBUTES[@]}"
  done
}

function generate_pdf {
  local TEMP_GEN_DIR
  local INPUT_FILE
  local OUTPUT_FILE
  local TEMP_OUTPUT_FILE
  local EXIT_STATUS
  local DOCUMENT_FAILED
  local -a ASCIIDOCTOR_ARGS

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  OUTPUT_FILE="${INPUT_FILE%.adoc}.pdf"
  TEMP_OUTPUT_FILE="${TEMP_GEN_DIR}/.docgen-output.pdf"
  DOCUMENT_FAILED=0
  ASCIIDOCTOR_ARGS=()

  mkdir -p -- "${TEMP_GEN_DIR}"

  prepare_asciidoctor_args \
    ASCIIDOCTOR_ARGS \
    DOCUMENT_FAILED \
    "${@}"

  (( DOCUMENT_FAILED )) && return 0

  printf 'Generate file: %s\n' "${OUTPUT_FILE}"

  asciidoctor-pdf \
    "--failure-level=${FAILURE_LEVEL}" \
    "--safe-mode=${SAFE_MODE}" \
    "${ASCIIDOCTOR_ARGS[@]}" \
    -o "${TEMP_OUTPUT_FILE}" \
    "${INPUT_FILE}" \
    || {
      EXIT_STATUS="${?}"
      warn_document_processing \
        'asciidoctor-pdf' "${INPUT_FILE}" "${EXIT_STATUS}"
      rm -f -- "${TEMP_OUTPUT_FILE}"
      return 0
    }

  mv -- "${TEMP_OUTPUT_FILE}" "${OUTPUT_FILE}"
}

function prepare_asciidoctor_args {
  local -n RESULT_ARGS="${1}"
  local -n RESULT_FAILED="${2}"
  local TEMP_GEN_DIR="${3}"
  local INPUT_FILE="${4}"
  local ATTRIBUTES_JSON
  local FEATURES_JSON
  local EXIT_STATUS
  local DOCGEN_USE_BIBTEX
  local DOCGEN_USE_MATHEMATICAL
  local DOCGEN_USE_KROKI
  shift 4

  RESULT_ARGS+=(
    -a "allow-uri-read@"
    -a "compress@"
    -a "source-highlighter@=rouge"
    -a "imagesoutdir@=${TEMP_GEN_DIR}"
  )

  if [[ -n "${ASCIIDOCTOR_PDF_FONTS_DIR:-}" ]]; then
    RESULT_ARGS+=(
      -a "pdf-fontsdir@=${ASCIIDOCTOR_PDF_FONTS_DIR};GEM_FONTS_DIR"
    )
  fi

  if (( DISCOVER_THEME )) && [[ -r "${WORK_DIR}/themes/default-theme.yml" ]]; then
    RESULT_ARGS+=(
      -a "pdf-theme@=${WORK_DIR}/themes/default-theme.yml"
    )
  fi

  ATTRIBUTES_JSON="$(
    BUNDLE_GEMFILE="${DOCGEN_ASCIIDOCTOR_GEMFILE}" \
      "${DOCGEN_BUNDLE_COMMAND}" exec \
        "${DOCGEN_RUBY_COMMAND}" \
          "${DOCGEN_ATTRIBUTE_RESOLVE}" \
            --backend 'pdf' \
            --safe-mode "${SAFE_MODE}" \
            "${RESULT_ARGS[@]}" \
            "${@}" \
            "${INPUT_FILE}"
  )" || {
    EXIT_STATUS="${?}"
    warn_document_processing \
      'DOCGEN_ATTRIBUTE_RESOLVE' "${INPUT_FILE}" "${EXIT_STATUS}"
    # ShellCheck cannot trace assignments through a nameref parameter.
    # shellcheck disable=SC2034
    RESULT_FAILED=1
    return 0
  }

  FEATURES_JSON="$(
    jq -cf "${DOCGEN_FEATURE_CHECK}" \
      <<< "${ATTRIBUTES_JSON}"
  )"

  DOCGEN_USE_BIBTEX="$(
    jq -r '.bibtex | if . then 1 else 0 end' \
      <<< "${FEATURES_JSON}"
  )"

  DOCGEN_USE_MATHEMATICAL="$(
    jq -r '.mathematical | if . then 1 else 0 end' \
      <<< "${FEATURES_JSON}"
  )"

  DOCGEN_USE_KROKI="$(
    jq -r '.kroki | if . then 1 else 0 end' \
      <<< "${FEATURES_JSON}"
  )"

  if (( DOCGEN_USE_BIBTEX )); then
    RESULT_ARGS+=(
      -r "asciidoctor-bibtex"
    )
  fi

  if (( DOCGEN_USE_MATHEMATICAL )); then
    RESULT_ARGS+=(
      -r "asciidoctor-mathematical"
      -a "mathematical-format@=png"
      -a "mathematical-ppi@=600"
    )
  fi

  if (( DOCGEN_USE_KROKI )); then
    RESULT_ARGS+=(
      -r "asciidoctor-kroki"
      -a "kroki-server-url@=https://kroki.io"
    )
  fi

  # Explicit user attributes override all soft wrapper defaults.
  RESULT_ARGS+=("${@}")
}

# shellcheck disable=SC2317,SC2329
# Called indirectly via: trap cleanup EXIT
function cleanup {
  local EXIT_STATUS="${?}"

  trap - EXIT

  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
    if (( REMOVE_TEMP_DIR )); then
      rm -rf -- "${TEMP_DIR}"
    else
      printf 'Keep temporary directory: %s\n' "${TEMP_DIR}" >&2
    fi
  fi

  exit "${EXIT_STATUS}"
}

function warn_document_access {
  printf \
    '%s - Warning: cannot access .adoc document; skipping: %s\n' \
    "${APP_NAME}" "${1}" >&2
}

function warn_document_processing {
  local COMMAND_NAME="${1}"
  local INPUT_FILE="${2}"
  local EXIT_STATUS="${3}"

  printf \
    '%s - Warning: %s failed for .adoc document with status %s; skipping: %s\n' \
    "${APP_NAME}" "${COMMAND_NAME}" "${EXIT_STATUS}" "${INPUT_FILE}" >&2
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

  -d, --debounce DURATION
      Wait for changes to settle before rebuilding. Passed to watchexec.
      Default: 250ms. Examples: 500ms, 2s

  -f, --failure-level LEVEL
      Failure level. Default: WARN

  -s, --safe-mode MODE
      Safe mode. Default: unsafe

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

  Document-specific failures from the attribute resolver or asciidoctor-pdf
  are reported and skipped. Any other failed initial or watched build stops
  the watcher and is returned as an error by docgen.
_EOI_
}

main "$@"
exit 0
