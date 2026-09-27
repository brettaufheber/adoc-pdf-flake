#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local INPUT_ROOT_OPTION
  local INPUT_ROOT
  local INPUT_FILE
  local INPUT_DIR
  local RELATIVE_INPUT_PATH
  local TEMP_GENERATED_ROOT
  local -a INPUT_FILES
  local -a USER_ATTRIBUTES

  INPUT_FILES=()
  USER_ATTRIBUTES=()

  APP_NAME="${0##*/}"
  FAILURE_LEVEL="WARN"
  SAFE_MODE="unsafe"
  DISCOVER_THEME=1
  REMOVE_TEMP_DIR=1
  INPUT_ROOT_OPTION=""

  : "${DOCGEN_ATTRIBUTE_RESOLVE:?DOCGEN_ATTRIBUTE_RESOLVE is not set}"
  : "${DOCGEN_FEATURE_CHECK:?DOCGEN_FEATURE_CHECK is not set}"
  : "${DOCGEN_ASCIIDOCTOR_GEMFILE:?DOCGEN_ASCIIDOCTOR_GEMFILE is not set}"
  : "${DOCGEN_BUNDLE_COMMAND:?DOCGEN_BUNDLE_COMMAND is not set}"
  : "${DOCGEN_RUBY_COMMAND:?DOCGEN_RUBY_COMMAND is not set}"

  OPTS="$(
    getopt \
      --name "${APP_NAME}" \
      --options 'f:s:a:h' \
      --longoptions "$(
        printf '%s' \
          'failure-level:,' \
          'safe-mode:,' \
          'input-root:,' \
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
      -f|--failure-level)
        FAILURE_LEVEL="${2}"
        shift 2
        ;;
      -s|--safe-mode)
        SAFE_MODE="${2}"
        shift 2
        ;;
      --input-root)
        INPUT_ROOT_OPTION="${2}"
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

  if [[ -n "${INPUT_ROOT_OPTION}" ]]; then
    if [[ ! -d "${INPUT_ROOT_OPTION}" ]]; then
      die "input root does not exist or is not a directory: ${INPUT_ROOT_OPTION}"
    fi

    INPUT_ROOT_OPTION="$(realpath -- "${INPUT_ROOT_OPTION}")"
  fi

  for INPUT_FILE in "${@}"; do
    [[ -f "${INPUT_FILE}" && "${INPUT_FILE}" == *.adoc ]] ||
      die "input must be an .adoc file: ${INPUT_FILE}"

    INPUT_FILE="$(realpath -- "${INPUT_FILE}")"

    if [[ -n "${INPUT_ROOT_OPTION}" && "${INPUT_FILE}" != "${INPUT_ROOT_OPTION}/"* ]]; then
      die "input file is outside input root: ${INPUT_FILE}"
    fi

    INPUT_FILES+=("${INPUT_FILE}")
  done

  TEMP_DIR="$(mktemp -d -t asciidoctor-assets.XXXXXXXX)"
  trap cleanup EXIT

  TEMP_GENERATED_ROOT="${TEMP_DIR}/generated"

  mkdir -p -- "${TEMP_GENERATED_ROOT}"

  for INPUT_FILE in "${INPUT_FILES[@]}"; do
    INPUT_DIR="$(dirname -- "${INPUT_FILE}")"

    if [[ -n "${INPUT_ROOT_OPTION}" ]]; then
      INPUT_ROOT="${INPUT_ROOT_OPTION}"
    else
      INPUT_ROOT="${INPUT_DIR}"
    fi

    RELATIVE_INPUT_PATH="$(
      realpath \
        --relative-to="${INPUT_ROOT}" \
        -- "${INPUT_DIR}"
    )"

    generate_pdf \
      "${TEMP_GENERATED_ROOT}/${RELATIVE_INPUT_PATH}" \
      "${INPUT_FILE}" \
      "${USER_ATTRIBUTES[@]}"
  done
}

function generate_pdf {
  local TEMP_GEN_DIR
  local INPUT_FILE
  local OUTPUT_FILE
  local TEMP_OUTPUT_FILE
  local -a ADOCTOR_ARGS

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  OUTPUT_FILE="${INPUT_FILE%.adoc}.pdf"
  TEMP_OUTPUT_FILE="${TEMP_GEN_DIR}/.docgen-output.pdf"
  ADOCTOR_ARGS=()

  mkdir -p -- "${TEMP_GEN_DIR}"

  prepare_adoctor_args "${@}"

  printf 'Generate file: %s\n' "${OUTPUT_FILE}"

  asciidoctor-pdf \
    "--failure-level=${FAILURE_LEVEL}" \
    "--safe-mode=${SAFE_MODE}" \
    "${ADOCTOR_ARGS[@]}" \
    -o "${TEMP_OUTPUT_FILE}" \
    "${INPUT_FILE}"

  mv -- "${TEMP_OUTPUT_FILE}" "${OUTPUT_FILE}"
}

function prepare_adoctor_args {
  local TEMP_GEN_DIR
  local INPUT_FILE
  local ATTRIBUTES_JSON
  local FEATURES_JSON
  local DOCGEN_USE_BIBTEX
  local DOCGEN_USE_MATHEMATICAL
  local DOCGEN_USE_KROKI

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  shift 2

  # ADOCTOR_ARGS is local to generate_pdf and visible here through dynamic scoping
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

  if (( DISCOVER_THEME )) && [[ -r "${INPUT_ROOT}/themes/default-theme.yml" ]]; then
    ADOCTOR_ARGS+=(
      -a "pdf-theme@=${INPUT_ROOT}/themes/default-theme.yml"
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
  )"

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
If --input-root is omitted, each document uses its own directory as input root.
The Asciidoctor base directory is not changed.

Options:
  -f, --failure-level LEVEL
      Failure level. Default: WARN

  -s, --safe-mode MODE
      Safe mode. Default: unsafe

      --input-root DIR
      Root used by docgen for wrapper-specific discovery, such as
      themes/default-theme.yml. The root must contain every input file.

      This does not set Asciidoctor's --base-dir.

  -a, --attribute ATTRIBUTE
      Pass an attribute to asciidoctor-pdf. Repeatable.

      --no-theme-discovery
      Do not automatically use INPUT_ROOT/themes/default-theme.yml
      as theme file.

      --keep-temp
      Keep the temporary directory.

  -h, --help
      Show this help.
_EOI_
}

main "$@"
exit 0
