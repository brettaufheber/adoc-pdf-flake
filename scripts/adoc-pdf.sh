#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local INPUT_PATH
  local RELATIVE_INPUT_PATH
  local ADOC_FILE
  local -a GEN_ARGS
  local -a USER_ATTRIBUTES

  APP_NAME="${0##*/}"
  FAILURE_LEVEL="WARN"
  SAFE_MODE="unsafe"
  USE_EXTENSION_BIBTEX=0
  USE_EXTENSION_MATHEMATICAL=1
  USE_EXTENSION_KROKI=1
  COLLECT_IMAGES=1
  DISCOVER_THEME=1
  REMOVE_TEMP_DIR=1
  IMAGES_DIR="${PWD}/images"
  PDF_THEMES_DIR="${PWD}/themes"
  GEN_ARGS=()
  USER_ATTRIBUTES=()

  OPTS="$(
    getopt \
      --name "${APP_NAME}" \
      --options 'f:s:i:t:a:h' \
      --longoptions "$(
        printf '%s' \
          'failure-level:,' \
          'safe-mode:,' \
          'images-dir:,' \
          'themes-dir:,' \
          'attribute:,' \
          'with-bibtex,' \
          'no-mathematical,' \
          'no-kroki,' \
          'no-image-collection,' \
          'no-theme-discovery,' \
          'keep-temp,' \
          'help'
      )" \
      -- "$@"
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
      -i|--images-dir)
        IMAGES_DIR="${2}"
        shift 2
        ;;
      -t|--themes-dir)
        PDF_THEMES_DIR="${2}"
        shift 2
        ;;
      -a|--attribute)
        USER_ATTRIBUTES+=(-a "${2}")
        shift 2
        ;;
      --with-bibtex)
        USE_EXTENSION_BIBTEX=1
        shift
        ;;
      --no-mathematical)
        USE_EXTENSION_MATHEMATICAL=0
        shift
        ;;
      --no-kroki)
        USE_EXTENSION_KROKI=0
        shift
        ;;
      --no-image-collection)
        COLLECT_IMAGES=0
        shift
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

  if (($# > 1)); then
    die "only one input path may be specified"
  fi

  TEMP_DIR="$(mktemp -d -t asciidoctor-assets.XXXXXXXX)"
  trap cleanup EXIT

  INPUT_PATH="${1:-${PWD}}"

  [[ -e "${INPUT_PATH}" ]] ||
    die "input path does not exist: ${INPUT_PATH}"

  INPUT_PATH="$(realpath -- "${INPUT_PATH}")"

  if (( USE_EXTENSION_BIBTEX )); then
    GEN_ARGS+=(
      -r "asciidoctor-bibtex"
    )
  fi

  if (( USE_EXTENSION_MATHEMATICAL )); then
    GEN_ARGS+=(
      -r "asciidoctor-mathematical"
      -a "mathematical-format@=png"
      -a "mathematical-ppi@=600"
    )
  fi

  if (( USE_EXTENSION_KROKI )); then
    GEN_ARGS+=(
      -r "asciidoctor-kroki"
      -a "kroki-fetch-diagram@"
      -a "kroki-server-url@=https://kroki.io"
      -a "kroki-http-method@=adaptive"
    )
  fi

  GEN_ARGS+=(
    -a "allow-uri-read@"
    -a "compress@"
    -a "source-highlighter@=rouge"
  )

  find "${INPUT_PATH}" \
    \( -type d -path '*/.*' -prune \) -o \
    \( -type f -name '*.adoc' ! -path '*/.*' -print0 \) |
      while IFS= read -r -d "" ADOC_FILE; do
        RELATIVE_INPUT_PATH="$(
          realpath \
            --relative-to="${INPUT_PATH}" \
            -- "$(dirname -- "${ADOC_FILE}")"
        )"
        generate_pdf \
          "${TEMP_DIR}/${RELATIVE_INPUT_PATH}" \
          "${ADOC_FILE}" \
          "${GEN_ARGS[@]}" \
          "${USER_ATTRIBUTES[@]}"
      done
}

function generate_pdf {
  local TEMP_GEN_DIR
  local INPUT_FILE
  local OUTPUT_FILE
  local -a ATTRIBUTES

  TEMP_GEN_DIR="${1}"
  INPUT_FILE="${2}"
  OUTPUT_FILE="${INPUT_FILE%.adoc}.pdf"
  ATTRIBUTES=()
  shift 2

  echo "Generate file: ${OUTPUT_FILE}"

  mkdir -p -- "${TEMP_GEN_DIR}"

  if (( COLLECT_IMAGES )) && [[ -d "${IMAGES_DIR}" ]]; then
    ATTRIBUTES+=(
      -a "imagesoutdir@=${TEMP_GEN_DIR}" \
      -a "imagesdir@=${TEMP_GEN_DIR}" \
      )
    cp -a -- "${IMAGES_DIR}/." "${TEMP_GEN_DIR}/"
  fi

  if (( DISCOVER_THEME )) && [[ -d "${PDF_THEMES_DIR}" ]]; then
    ATTRIBUTES+=(
      -a "pdf-themesdir@=${PDF_THEMES_DIR}"
    )
    if [[ -r "${PDF_THEMES_DIR}/default-theme.yml" ]]; then
      ATTRIBUTES+=(
        -a "pdf-theme@=default"
      )
    fi
  fi

  asciidoctor-pdf \
    "--failure-level=${FAILURE_LEVEL}" \
    "--safe-mode=${SAFE_MODE}" \
    "${ATTRIBUTES[@]}" \
    "${@}" \
    -o "${OUTPUT_FILE}" \
    "${INPUT_FILE}"
}

# shellcheck disable=SC2317,SC2329  # Called indirectly via: trap cleanup EXIT
function cleanup {
  local EXIT_STATUS=$?

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
  printf 'Try %s --help" for usage.\n' "${APP_NAME}" >&2
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

  -t, --themes-dir DIR
      PDF theme directory. Default: ./themes

  -a, --attribute ATTRIBUTE
      Pass an attribute to asciidoctor-pdf. Repeatable.

      --no-bibtex
      Do not load asciidoctor-bibtex.

      --no-mathematical
      Do not load asciidoctor-mathematical.

      --no-kroki
      Do not load asciidoctor-kroki.

      --no-image-collection
      Do not collect images in a temporary directory.

      --no-theme-discovery
      Do not provide or discover a PDF theme.

      --keep-temp
      Keep the temporary directory.

  -h, --help
      Show this help.
_EOI_
}

main "$@"
exit 0
