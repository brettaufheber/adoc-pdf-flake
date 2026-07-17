#!/usr/bin/env bash
set -euo pipefail

function main {
  local INPUT_PATH
  local ADOC_FILE

  INPUT_PATH="${1:-${PWD}}"
  INPUT_PATH="$(realpath -- "${INPUT_PATH}")"
  (($# == 0)) || shift

  find "${INPUT_PATH}" \
    \( -type d -path '*/.*' -prune \) -o \
    \( -type f -name '*.adoc' ! -path '*/.*' -print0 \) |
    while IFS= read -r -d "" ADOC_FILE; do
      generate_pdf "${ADOC_FILE}" "${@}"
    done
}

function generate_pdf {
  local INPUT_FILE
  local OUTPUT_FILE
  local TEMP_IMG_OUTPUT_DIR

  INPUT_FILE="${1}"
  OUTPUT_FILE="${INPUT_FILE%.adoc}.pdf"
  TEMP_IMG_OUTPUT_DIR="$(mktemp -d -t asciidoctor-assets.XXXXXXXX)"
  shift

  echo "Generate file: ${OUTPUT_FILE}"

  asciidoctor-pdf \
    "--failure-level=${ASCIIDOCTOR_FAILURE_LEVEL:-WARN}" \
    "--safe-mode=${ASCIIDOCTOR_SAFE_MODE:-unsafe}" \
    -r "asciidoctor-mathematical" \
    -r "asciidoctor-kroki" \
    -a "allow-uri-read" \
    -a "compress" \
    -a "imagesoutdir=${TEMP_IMG_OUTPUT_DIR}" \
    -a "pdf-themesdir=${ASCIIDOCTOR_PDF_THEMESDIR:-${PWD}/themes}" \
    -a "pdf-theme=${ASCIIDOCTOR_PDF_THEME:-custom}" \
    -a "mathematical-format=png" \
    -a "mathematical-ppi=${MATHEMATICAL_PPI:-600}" \
    -a "kroki-fetch-diagram" \
    -a "kroki-server-url=${KROKI_SERVER_URL:-https://kroki.io}" \
    -a "kroki-http-method=${KROKI_HTTP_METHOD:-adaptive}" \
    -a "source-highlighter=rouge" \
    -o "${OUTPUT_FILE}" \
    "${@}" \
    "${INPUT_FILE}"

  rm -rf "${TEMP_IMG_OUTPUT_DIR}"
}

main "$@"
exit 0
