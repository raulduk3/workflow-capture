#!/bin/sh

set -eu

usage() {
  cat <<'EOF'
Usage: sh ./scripts/build-complete-training-packet.sh [options]

Options:
  --packet-date YYYY-MM-DD     Output packet date. Defaults to latest end-user packet date.
  --end-user-date YYYY-MM-DD   End-user course packet date. Defaults to packet date.
  --per-user-date YYYY-MM-DD   Per-user packet date. Defaults to latest per-user packet date.
  --help                       Show this help text.
EOF
}

latest_date() {
  directory="$1"
  pattern="$2"

  find "$directory" -maxdepth 1 -type f -name "$pattern" \
    | sed -E 's/.*_([0-9]{4}-[0-9]{2}-[0-9]{2})\.md$/\1/' \
    | sort \
    | tail -n 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
REPORTS_DIR="$REPO_ROOT/docs/reports"
LEARNING_DIR="$REPORTS_DIR/learning_modules"
PER_USER_DIR="$REPORTS_DIR/per_user_training"

PACKET_DATE=""
END_USER_DATE=""
PER_USER_DATE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --packet-date)
      PACKET_DATE="$2"
      shift 2
      ;;
    --end-user-date)
      END_USER_DATE="$2"
      shift 2
      ;;
    --per-user-date)
      PER_USER_DATE="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v pandoc >/dev/null 2>&1; then
  printf 'pandoc is required but not installed or not on PATH.\n' >&2
  exit 1
fi

if ! command -v xelatex >/dev/null 2>&1; then
  printf 'xelatex is required but not installed or not on PATH.\n' >&2
  exit 1
fi

if [ -z "$PACKET_DATE" ]; then
  PACKET_DATE=$(latest_date "$REPORTS_DIR" 'BULLEY_ANDREWS_END_USER_COURSE_PACKET_*.md')
fi

if [ -z "$PACKET_DATE" ]; then
  printf 'Unable to determine packet date from end-user course packet files.\n' >&2
  exit 1
fi

if [ -z "$END_USER_DATE" ]; then
  END_USER_DATE="$PACKET_DATE"
fi

if [ -z "$PER_USER_DATE" ]; then
  PER_USER_DATE=$(latest_date "$PER_USER_DIR" '*_training_*.md')
fi

if [ -z "$PER_USER_DATE" ]; then
  printf 'Unable to determine per-user packet date from per-user training files.\n' >&2
  exit 1
fi

END_USER_FILE="$REPORTS_DIR/BULLEY_ANDREWS_END_USER_COURSE_PACKET_${END_USER_DATE}.md"
OUTPUT_MD="$REPORTS_DIR/BULLEY_ANDREWS_COMPLETE_TRAINING_PACKET_${PACKET_DATE}.md"
OUTPUT_PDF="$REPORTS_DIR/BULLEY_ANDREWS_COMPLETE_TRAINING_PACKET_${PACKET_DATE}.pdf"

if [ ! -f "$END_USER_FILE" ]; then
  printf 'End-user course packet not found: %s\n' "$END_USER_FILE" >&2
  exit 1
fi

set -- "$PER_USER_DIR"/*_training_"$PER_USER_DATE".md
if [ ! -e "$1" ]; then
  printf 'No per-user training packets found for date %s\n' "$PER_USER_DATE" >&2
  exit 1
fi

if [ -f "$REPO_ROOT/build/pandoc-packet-header.tex" ]; then
  HEADER_FILE="$REPO_ROOT/build/pandoc-packet-header.tex"
else
  HEADER_FILE="$REPO_ROOT/build/pandoc-wrap-header.tex"
fi

TMP_MD=$(mktemp)
trap 'rm -f "$TMP_MD"' EXIT

{
  printf '# Bulley & Andrews Complete Training Packet\n\n'
  printf '**Generated:** %s\n\n' "$PACKET_DATE"
  printf 'This packet contains the end-user course packet, the full learning module library, and the per-user training documents in one combined file.\n\n'
  printf '\\newpage\n\n'
  cat "$END_USER_FILE"
  printf '\n\\newpage\n\n# Learning Modules Library\n\n'
  cat "$LEARNING_DIR/README.md"
  for file in "$LEARNING_DIR"/shared_foundation/*.md; do
    printf '\n\\newpage\n\n'
    cat "$file"
  done
  for file in "$LEARNING_DIR"/cohort_modules/*.md; do
    printf '\n\\newpage\n\n'
    cat "$file"
  done
  for file in "$LEARNING_DIR"/user_labs/*.md; do
    printf '\n\\newpage\n\n'
    cat "$file"
  done
  printf '\n\\newpage\n\n# Per-User Training Documents\n\n'
  cat "$PER_USER_DIR/README.md"
  for file in "$PER_USER_DIR"/*_training_"$PER_USER_DATE".md; do
    printf '\n\\newpage\n\n'
    cat "$file"
  done
} > "$TMP_MD"

awk '
BEGIN { seen = 0; in_code = 0 }
/^```/ { in_code = !in_code; print; next }
{
  if (!seen && /^# /) {
    seen = 1
    print
    next
  }
  if (seen && !in_code && /^#{1,5} /) {
    $0 = "#" $0
  }
  if ($0 == "## Learning Modules Library" || $0 == "## Per-User Training Documents") {
    next
  }
  print
}
' "$TMP_MD" > "$OUTPUT_MD"

pandoc "$OUTPUT_MD" \
  -o "$OUTPUT_PDF" \
  --pdf-engine=xelatex \
  --toc \
  --toc-depth=3 \
  --number-sections \
  --include-in-header="$HEADER_FILE" \
  -V geometry:margin=0.8in \
  -V colorlinks=true \
  -V linkcolor=blue \
  -V urlcolor=blue

printf 'Built %s and %s\n' "$OUTPUT_MD" "$OUTPUT_PDF"