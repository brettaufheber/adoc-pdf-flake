#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${0##*/}"
SLEF_PATH="$(realpath -- "${BASH_SOURCE[0]}")"
readonly APP_NAME SLEF_PATH

function main {
  # Internal processes inherit the validated runtime environment and working
  # directory from the public invocation.
  if [[ "${DOCGEN_GENERATE:-0}" == 1 ]]; then
    generate_documents "${@}"
    return
  fi

  if [[ "${DOCGEN_WATCH_DISPATCH:-0}" == 1 ]]; then
    dispatch_watch_events "${@}"
    return
  fi

  local OPTS
  local DEBOUNCE
  local WORK_DIR_OPTION
  local WORK_DIR
  local FAILURE_LEVEL
  local SAFE_MODE
  local DISCOVER_THEME
  local REMOVE_TEMP_DIR
  local WATCH_MODE
  local -a ADOC_FILES
  local -a WATCH_PATHS=()
  # Nameref target passed to resolve_watch_paths and start_watcher.
  # shellcheck disable=SC2034
  local -a RESOLVED_WATCH_FILES
  # shellcheck disable=SC2034
  local -a RESOLVED_WATCH_DIRS
  local -a GENERATOR_CONFIG
  local -a USER_ATTRIBUTES=()

  DEBOUNCE="250ms"
  WORK_DIR_OPTION="."
  FAILURE_LEVEL="WARN"
  SAFE_MODE="unsafe"
  DISCOVER_THEME=1
  REMOVE_TEMP_DIR=1
  WATCH_MODE=0

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

  validate_runtime_environment

  [[ -d "${WORK_DIR_OPTION}" ]] ||
    die "working directory does not exist or is not a directory: ${WORK_DIR_OPTION}"

  WORK_DIR="$(realpath -- "${WORK_DIR_OPTION}")"

  #
  # From this point on all relative paths are interpreted relative to
  # the selected working directory, similar to "git -C DIR".
  #
  cd -- "${WORK_DIR}"

  resolve_input_documents \
    "${WORK_DIR}" \
    ADOC_FILES \
    "${@}"

  # Serialize the normalized generator configuration. The generator inherits
  # the already selected working directory from this process.
  GENERATOR_CONFIG=(
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
      "${GENERATOR_CONFIG[@]}" \
      "${ADOC_FILES[@]}"
    return
  fi

  resolve_watch_paths \
    "${WORK_DIR}" \
    RESOLVED_WATCH_FILES \
    RESOLVED_WATCH_DIRS \
    "${WATCH_PATHS[@]}"

  start_watcher \
    "${DEBOUNCE}" \
    "${WORK_DIR}" \
    ADOC_FILES \
    RESOLVED_WATCH_FILES \
    RESOLVED_WATCH_DIRS \
    GENERATOR_CONFIG
}

function resolve_input_documents {
  local WORK_DIR="${1}"
  local -n OUTPUT_DOCUMENTS="${2}"
  local INPUT_PATH
  local RESOLVED_INPUT_PATH
  local ADOC_FILE
  local ADOC_FILE_BASE64
  local ADOC_FILES_RESULT
  local -a RESOLVED_INPUT_PATHS=()
  shift 2
  # ShellCheck cannot trace assignments through a nameref parameter.
  # shellcheck disable=SC2034
  OUTPUT_DOCUMENTS=()

  if (($# == 0)); then
    set -- "${WORK_DIR}"
  fi

  for INPUT_PATH in "${@}"; do
    [[ -e "${INPUT_PATH}" ]] ||
      die "input path does not exist: ${INPUT_PATH}"

    RESOLVED_INPUT_PATH="$(realpath -- "${INPUT_PATH}")"

    require_project_path \
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

  # Base64 provides a line-safe representation without hiding failures from
  # find or jq behind a process substitution.
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
    # ShellCheck cannot trace assignments through a nameref parameter.
    # shellcheck disable=SC2034
    OUTPUT_DOCUMENTS+=("${ADOC_FILE}")
  done <<< "${ADOC_FILES_RESULT}"

  if ((${#ADOC_FILES[@]} == 0)); then
    die "no .adoc files found in selected input paths"
  fi
}

function resolve_watch_paths {
  local WORK_DIR="${1}"
  local -n OUTPUT_WATCH_FILES="${2}"
  local -n OUTPUT_WATCH_DIRS="${3}"
  local WATCH_PATH
  local RESOLVED_WATCH_PATH
  shift 3

  # ShellCheck cannot trace assignments through nameref parameters.
  # shellcheck disable=SC2034
  OUTPUT_WATCH_FILES=()
  # shellcheck disable=SC2034
  OUTPUT_WATCH_DIRS=()

  for WATCH_PATH in "${@}"; do
    [[ -e "${WATCH_PATH}" ]] ||
      die "watch path does not exist: ${WATCH_PATH}"

    RESOLVED_WATCH_PATH="$(realpath -- "${WATCH_PATH}")"

    require_project_path \
      "${WORK_DIR}" \
      "${RESOLVED_WATCH_PATH}" \
      "watch path"

    if [[ -d "${RESOLVED_WATCH_PATH}" ]]; then
      # shellcheck disable=SC2034
      OUTPUT_WATCH_DIRS+=("${RESOLVED_WATCH_PATH}")
    else
      # shellcheck disable=SC2034
      OUTPUT_WATCH_FILES+=("${RESOLVED_WATCH_PATH}")
    fi
  done
}

function start_watcher {
  local DEBOUNCE="${1}"
  local WORK_DIR="${2}"
  local -n DOCUMENTS_REF="${3}"
  local -n WATCH_FILES_REF="${4}"
  local -n WATCH_DIRS_REF="${5}"
  local -n GENERATOR_CONFIG_REF="${6}"
  local WATCH_PATH
  local -a WATCH_ARGS

  # A failed initial build must prevent the watcher from starting.
  run_pdf_generator \
    "${GENERATOR_CONFIG_REF[@]}" \
    "${DOCUMENTS_REF[@]}"

  printf 'Watching %d document(s) below %s. Press Ctrl-C to stop.\n' \
    "${#DOCUMENTS_REF[@]}" \
    "${WORK_DIR}" >&2

  # Input directories are intentionally absent. The selected document set
  # remains fixed until docgen is restarted.
  for WATCH_PATH in \
    "${DOCUMENTS_REF[@]}" \
    "${WATCH_FILES_REF[@]}" \
    "${WATCH_DIRS_REF[@]}"
  do
    WATCH_ARGS+=(--watch "${WATCH_PATH}")
  done

  # Replace docgen with one watchexec process. Each debounced event batch
  # starts this script in internal dispatch mode and is supplied as JSON.
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
      "${#DOCUMENTS_REF[@]}" \
      "${DOCUMENTS_REF[@]}" \
      "${#WATCH_FILES_REF[@]}" \
      "${WATCH_FILES_REF[@]}" \
      "${#WATCH_DIRS_REF[@]}" \
      "${WATCH_DIRS_REF[@]}" \
      "${#GENERATOR_CONFIG_REF[@]}" \
      "${GENERATOR_CONFIG_REF[@]}"
}

function validate_runtime_environment {
  : "${DOCGEN_ATTRIBUTE_RESOLVE:?DOCGEN_ATTRIBUTE_RESOLVE is not set}"
  : "${DOCGEN_PDF_LINE_WRAP:?DOCGEN_PDF_LINE_WRAP is not set}"
  : "${DOCGEN_FEATURE_CHECK:?DOCGEN_FEATURE_CHECK is not set}"
  : "${DOCGEN_ASCIIDOCTOR_GEMFILE:?DOCGEN_ASCIIDOCTOR_GEMFILE is not set}"
  : "${DOCGEN_BUNDLE_COMMAND:?DOCGEN_BUNDLE_COMMAND is not set}"
  : "${DOCGEN_RUBY_COMMAND:?DOCGEN_RUBY_COMMAND is not set}"

  [[ -x "${SLEF_PATH}" ]] ||
    die "docgen command is not executable: ${SLEF_PATH}"

  [[ -r "${DOCGEN_ATTRIBUTE_RESOLVE}" ]] ||
    die "attribute resolver is not readable: ${DOCGEN_ATTRIBUTE_RESOLVE}"

  [[ -r "${DOCGEN_PDF_LINE_WRAP}" ]] ||
    die "line wrap extension is not readable: ${DOCGEN_PDF_LINE_WRAP}"

  [[ -r "${DOCGEN_FEATURE_CHECK}" ]] ||
    die "feature check is not readable: ${DOCGEN_FEATURE_CHECK}"

  [[ -r "${DOCGEN_ASCIIDOCTOR_GEMFILE}" ]] ||
    die "Asciidoctor Gemfile is not readable: ${DOCGEN_ASCIIDOCTOR_GEMFILE}"

  [[ -x "${DOCGEN_BUNDLE_COMMAND}" ]] ||
    die "bundle command is not executable: ${DOCGEN_BUNDLE_COMMAND}"

  [[ -x "${DOCGEN_RUBY_COMMAND}" ]] ||
    die "Ruby command is not executable: ${DOCGEN_RUBY_COMMAND}"

  command -v asciidoctor-pdf >/dev/null 2>&1 ||
    die "asciidoctor-pdf command is not executable"
}

function require_project_path {
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

  if [[ "${RELATIVE_PATH}" != "." &&
        ( "${RELATIVE_PATH}" == .* ||
          "${RELATIVE_PATH}" == */.* ) ]]
  then
    die \
      "${PATH_DESCRIPTION} contains a hidden path component: ${PATH_TO_CHECK}"
  fi
}

function consume_counted_array {
  local -n RESULT_REF="${1}"
  local -n SOURCE_REF="${2}"
  local CONTEXT="${3}"
  local COUNT="${SOURCE_REF[0]:-}"

  [[ "${COUNT}" =~ ^[0-9]+$ ]] ||
    die "invalid internal ${CONTEXT} arguments"

  ((${#SOURCE_REF[@]} >= COUNT + 1)) ||
    die "incomplete internal ${CONTEXT} arguments"

  # ShellCheck cannot trace assignments through nameref parameters.
  # shellcheck disable=SC2034
  RESULT_REF=("${SOURCE_REF[@]:1:COUNT}")
  # shellcheck disable=SC2034
  SOURCE_REF=("${SOURCE_REF[@]:COUNT + 1}")
}

function dispatch_watch_events {
  local EVENT_PATH
  local EVENT_PATH_BASE64
  local EVENT_PATHS_RESULT
  local ADOC_FILE
  local WATCH_PATH
  local -a INTERNAL_ARGS
  local -a ADOC_FILES
  local -a BUILD_ADOC_FILES=()
  local -a WATCH_FILES
  local -a WATCH_DIRS
  local -a GENERATOR_CONFIG
  local -A BUILD_FILES=()

  INTERNAL_ARGS=("${@}")

  consume_counted_array ADOC_FILES INTERNAL_ARGS "watch dispatch"
  consume_counted_array WATCH_FILES INTERNAL_ARGS "watch dispatch"
  consume_counted_array WATCH_DIRS INTERNAL_ARGS "watch dispatch"
  consume_counted_array GENERATOR_CONFIG INTERNAL_ARGS "watch dispatch"

  ((${#INTERNAL_ARGS[@]} == 0)) ||
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
      "${GENERATOR_CONFIG[@]}" \
      "${BUILD_ADOC_FILES[@]}"
  fi
}

function run_pdf_generator {
  DOCGEN_GENERATE=1 "${SLEF_PATH}" "${@}"
}

function generate_documents {
  local INPUT_FILE
  local INPUT_DIR
  local RELATIVE_INPUT_DIR
  local TEMP_GENERATED_ROOT
  local TEMP_DOCUMENT_DIR
  local -a INTERNAL_ARGS
  local -a INPUT_FILES=()
  local -a REQUESTED_INPUT_FILES
  local -a USER_ATTRIBUTES

  (($# >= 5)) ||
    die "incomplete internal generator arguments"

  WORK_DIR="${PWD}"
  FAILURE_LEVEL="${1}"
  SAFE_MODE="${2}"
  DISCOVER_THEME="${3}"
  REMOVE_TEMP_DIR="${4}"
  shift 4

  INTERNAL_ARGS=("${@}")
  consume_counted_array USER_ATTRIBUTES INTERNAL_ARGS "generator"

  [[ "${DISCOVER_THEME}" =~ ^[01]$ &&
     "${REMOVE_TEMP_DIR}" =~ ^[01]$ ]] ||
    die "invalid internal generator arguments"

  ((${#USER_ATTRIBUTES[@]} % 2 == 0)) ||
    die "invalid internal generator attribute arguments"

  ((${#INTERNAL_ARGS[@]} > 0)) ||
    die "incomplete internal generator arguments"

  REQUESTED_INPUT_FILES=("${INTERNAL_ARGS[@]}")

  for INPUT_FILE in "${REQUESTED_INPUT_FILES[@]}"; do
    # Selected files were fully validated by the public invocation. Only their
    # current accessibility can change while the watcher is running.
    if [[ ! -f "${INPUT_FILE}" || ! -r "${INPUT_FILE}" ]]; then
      warn_document_access "${INPUT_FILE}"
      continue
    fi

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

  DOCGEN_USE_BIBTEX="$(jq -r '.bibtex | if . then 1 else 0 end' <<< "${FEATURES_JSON}")"
  DOCGEN_USE_MATHEMATICAL="$(jq -r '.mathematical | if . then 1 else 0 end' <<< "${FEATURES_JSON}")"
  DOCGEN_USE_KROKI="$(jq -r '.kroki | if . then 1 else 0 end' <<< "${FEATURES_JSON}")"

  RESULT_ARGS+=(
    -r "${DOCGEN_PDF_LINE_WRAP}"
  )

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
