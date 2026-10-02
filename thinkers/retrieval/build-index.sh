#!/usr/bin/env bash
# retrieval/build-index.sh — word index over an identity's memories.
#
# Usage: build-index.sh [MEM_DIR] [OUT]
#   defaults: $MEM_DIR, $RETRIEVAL_INDEX or $IDENTITY_DIR/retrieval/index.tsv
#
# One row per (word, memory): word<TAB>mem_id<TAB>summary, sorted and
# unique. Words come from the memory's summary line and body (lowercase,
# 3+ chars, stopwords out). The step rebuilds this whenever a memory file is
# newer than the index, so it is rarely run by hand. Prints the row count.
set -euo pipefail
here="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
mem_dir="${1:-${MEM_DIR:?MEM_DIR not set}}"
out="${2:-${RETRIEVAL_INDEX:-${IDENTITY_DIR:?IDENTITY_DIR not set}/retrieval/index.tsv}}"
mkdir -p "$(dirname "$out")"
tmp=$(mktemp); trap 'rm -f "$tmp"' EXIT
for f in "$mem_dir"/*.md; do
    [[ -f "$f" ]] || continue
    mid=$(sed -n 's/^id:[[:space:]]*//p' "$f" | head -1 || true)
    [[ -n "$mid" ]] || continue
    summary=$(sed -n 's/^summary:[[:space:]]*//p' "$f" | head -1 | tr '\t' ' ' || true)
    # body lines plus the summary line; the rest of the frontmatter is skipped
    awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {f=0; next} !f || /^summary:/' "$f" \
        | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '\n' \
        | grep -E '^[a-z0-9]{3,}$' | grep -vxF -f "$here/stopwords" | sort -u \
        | awk -v m="$mid" -v s="$summary" '{print $0 "\t" m "\t" s}' >> "$tmp" || true
done
sort -u "$tmp" > "$out"
wc -l < "$out" | tr -d ' '
