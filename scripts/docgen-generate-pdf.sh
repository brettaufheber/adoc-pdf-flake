#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local WORK_DIR_OPTION
  local WORK_DIR
  local INPUT_FILE
  local RESOLVED_INPUT_FILE
  local INPUT_DIR
  local RELATIVE_INPUT_DIR
  local TEMP_GENERATED_ROOT
  local TEMP_DOCUMENT_DIR
  local -a INPUT_FILES
  local -a USER_ATTRIBUTES

  INPUT_FILES=()
  USER_ATTRIBUTES=()

  WORK_DIR_OPTION="."
  APP_NAME="${0##*/}"
  FAILURE_LEVEL="WARN"
  SAFE_MODE="unsafe"
  DISCOVER_THEME=1
  REMOVE_TEMP_DIR=1

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

  OPTS="$(
    getopt \
      --name "${APP_NAME}" \
      --options 'C:f:s:a:h' \
      --longoptions "$(
        printf '%s' \
          'directory:,' \
          'failure-level:,' \
          'safe-mode:,' \
          'attribute:,' \
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

  if (($# == 0)); then
    die "at least one .adoc input file must be specified"
  fi

  [[ -d "${WORK_DIR_OPTION}" ]] ||
    die "working directory does not exist or is not a directory: ${WORK_DIR_OPTION}"

  WORK_DIR="$(realpath -- "${WORK_DIR_OPTION}")"

  # Resolve all relative input and wrapper-specific paths from the selected
  # working directory, consistently with docgen.
  cd -- "${WORK_DIR}"

  for INPUT_FILE in "${@}"; do
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
  local -a ADOCTOR_ARGS

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  OUTPUT_FILE="${INPUT_FILE%.adoc}.pdf"
  TEMP_OUTPUT_FILE="${TEMP_GEN_DIR}/.docgen-output.pdf"
  DOCUMENT_FAILED=0
  ADOCTOR_ARGS=()

  mkdir -p -- "${TEMP_GEN_DIR}"

  prepare_adoctor_args "${@}"

  (( DOCUMENT_FAILED )) && return 0

  printf 'Generate file: %s\n' "${OUTPUT_FILE}"

  asciidoctor-pdf \
    "--failure-level=${FAILURE_LEVEL}" \
    "--safe-mode=${SAFE_MODE}" \
    "${ADOCTOR_ARGS[@]}" \
    -o "${TEMP_OUTPUT_FILE}" \
    "${INPUT_FILE}" || {
    EXIT_STATUS="${?}"
    warn_document_processing \
      'asciidoctor-pdf' "${INPUT_FILE}" "${EXIT_STATUS}"
    rm -f -- "${TEMP_OUTPUT_FILE}"
    return 0
  }

  mv -- "${TEMP_OUTPUT_FILE}" "${OUTPUT_FILE}"
}

function prepare_adoctor_args {
  local TEMP_GEN_DIR
  local INPUT_FILE
  local ATTRIBUTES_JSON
  local FEATURES_JSON
  local EXIT_STATUS
  local DOCGEN_USE_BIBTEX
  local DOCGEN_USE_MATHEMATICAL
  local DOCGEN_USE_KROKI

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  shift 2

  # ADOCTOR_ARGS and DOCUMENT_FAILED are local to generate_pdf and visible here
  # through Bash's dynamic scoping.
  ADOCTOR_ARGS+=(
    -a "allow-uri-read@"
    -a "compress@"
    -a "source-highlighter@=rouge"
    -a "imagesoutdir@=${TEMP_GEN_DIR}"
  )

  if [[ -n "${ASCIIDOCTOR_PDF_FONTS_DIR:-}" ]]; then
    ADOCTOR_ARGS+=(
      -a "pdf-fontsdir@=${ASCIIDOCTOR_PDF_FONTS_DIR};GEM_FONTS_DIR"
    )
  fi

  if (( DISCOVER_THEME )) && [[ -r "${WORK_DIR}/themes/default-theme.yml" ]]; then
    ADOCTOR_ARGS+=(
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
            "${ADOCTOR_ARGS[@]}" \
            "${@}" \
            "${INPUT_FILE}"
  )" || {
    EXIT_STATUS="${?}"
    warn_document_processing \
      'DOCGEN_ATTRIBUTE_RESOLVE' "${INPUT_FILE}" "${EXIT_STATUS}"
    DOCUMENT_FAILED=1
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
    ADOCTOR_ARGS+=(
      -r "asciidoctor-bibtex"
    )
  fi

  if (( DOCGEN_USE_MATHEMATICAL )); then
    ADOCTOR_ARGS+=(
      -r "asciidoctor-mathematical"
      -a "mathematical-format@=png"
      -a "mathematical-ppi@=600"
    )
  fi

  if (( DOCGEN_USE_KROKI )); then
    ADOCTOR_ARGS+=(
      -r "asciidoctor-kroki"
      -a "kroki-server-url@=https://kroki.io"
    )
  fi

  # explicit user attributes override all soft wrapper defaults
  ADOCTOR_ARGS+=("${@}")
}

# shellcheck disable=SC2317,SC2329
# called indirectly via: trap cleanup EXIT
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

  if [[ "${RELATIVE_PATH}" == .. || "${RELATIVE_PATH}" == ../* ]]; then
    die "${PATH_DESCRIPTION} is outside working directory: ${PATH_TO_CHECK}"
  fi
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
  ${APP_NAME} [OPTIONS] ADOC_FILE [ADOC_FILE ...]

Only .adoc files are accepted as input.
All input files must be located below the working directory after resolving
symbolic links. The working directory is also used for wrapper-specific
discovery, such as themes/default-theme.yml.

Changing the working directory does not set Asciidoctor's --base-dir.

An inaccessible .adoc file is reported as a warning and skipped. Failures from
the attribute resolver or asciidoctor-pdf are reported for the affected
document and skipped as well. Other errors remain fatal. Processing continues
with the next document after a document-specific failure.

Options:
  -C, --directory DIR
      Change to DIR before resolving input files and other relative paths.
      Default: current working directory.

  -f, --failure-level LEVEL
      Failure level. Default: WARN

  -s, --safe-mode MODE
      Safe mode. Default: unsafe

  -a, --attribute ATTRIBUTE
      Pass an attribute to asciidoctor-pdf. Repeatable.

      --no-theme-discovery
      Do not automatically use WORK_DIR/themes/default-theme.yml as theme
      file.

      --keep-temp
      Keep the temporary directory.

  -h, --help
      Show this help.
_EOI_
}

main "$@"
exit 0
