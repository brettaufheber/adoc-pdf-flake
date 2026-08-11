#!/usr/bin/env bash
set -euo pipefail

function main {
  local OPTS
  local INPUT_PATH
  local INPUT_ROOT
  local ADOC_FILE
  local WATCH_PATH
  local RESOLVED_WATCH_PATH
  local -a ADOC_FILES
  local -a WATCH_PATHS
  local -a GENERATOR_ARGS
  local -a WATCH_ARGS
  local -a WATCH_PIDS

  ADOC_FILES=()
  WATCH_PATHS=()
  GENERATOR_ARGS=()
  WATCH_PIDS=()

  APP_NAME="${0##*/}"
  WATCH_MODE=0

  : "${DOCGEN_PDF_GENERATOR:?DOCGEN_PDF_GENERATOR is not set}"

  [[ -x "${DOCGEN_PDF_GENERATOR}" ]] ||
    die "PDF generator is not executable: ${DOCGEN_PDF_GENERATOR}"

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
        jq -Rsc 'split("\u0000")[:-1][] | @base64'
  )"

  while IFS= read -r ADOC_FILE_BASE64; do
    [[ -n "${ADOC_FILE_BASE64}" ]] || continue
    ADOC_FILE="$(printf '%s' "${ADOC_FILE_BASE64}" | base64 --decode)"
  done <<< "${ADOC_FILES_RESULT}"

  if ((${#ADOC_FILES[@]} == 0)); then
    die "no .adoc files found below input path: ${INPUT_PATH}"
  fi

  GENERATOR_ARGS+=(--input-root "${INPUT_ROOT}")

  if (( ! WATCH_MODE )); then
    exec "${DOCGEN_PDF_GENERATOR}" \
      "${GENERATOR_ARGS[@]}" \
      "${ADOC_FILES[@]}"
  fi

  #
  # Validate and resolve explicitly requested watch paths once before
  # starting any watcher.
  #
  for WATCH_PATH in "${WATCH_PATHS[@]}"; do
    [[ -e "${WATCH_PATH}" ]] ||
      die "watch path does not exist: ${WATCH_PATH}"
  done

  printf 'Watching %d document(s). Press Ctrl-C to stop.\n' \
    "${#ADOC_FILES[@]}" >&2

  #
  # Each document gets one watcher. A direct change rebuilds only that
  # document. Additional --watch-path entries are attached to every
  # watcher, so a change there rebuilds every selected document.
  #
  for ADOC_FILE in "${ADOC_FILES[@]}"; do
    WATCH_ARGS=(
      --watch "${ADOC_FILE}"
    )

    for WATCH_PATH in "${WATCH_PATHS[@]}"; do
      RESOLVED_WATCH_PATH="$(realpath -- "${WATCH_PATH}")"
      WATCH_ARGS+=(
        --watch "${RESOLVED_WATCH_PATH}"
      )
    done

    watchexec \
      --debounce 250ms \
      --on-busy-update queue \
      --ignore-nothing \
      --ignore '**/.*' \
      --ignore '**/.*/**' \
      --ignore '**/*.pdf' \
      --shell none \
      "${WATCH_ARGS[@]}" \
      -- \
      "${DOCGEN_PDF_GENERATOR}" \
      "${GENERATOR_ARGS[@]}" \
      "${ADOC_FILE}" &

    WATCH_PIDS+=("${!}")
  done

  trap cleanup EXIT

  wait "${WATCH_PIDS[@]}"

  trap - INT TERM
}

function cleanup {
  local EXIT_STATUS="${?}"

  trap - EXIT

  if ((${#WATCH_PIDS[@]} > 0)); then
    kill "${WATCH_PIDS[@]}" 2>/dev/null || true
    wait "${WATCH_PIDS[@]}" 2>/dev/null || true
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

      Each selected .adoc document has its own watcher and is rebuilt
      independently.

      --watch-path PATH
      Watch an additional file or directory.
      May be specified multiple times. Requires --watch.

      A change below an additional watch path causes each selected
      document to be rebuilt.

      --no-image-collection
      Do not collect images in a temporary directory.

      --no-theme-discovery
      Do not automatically use INPUT_ROOT/themes/default-theme.yml as theme file.

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
