#!/usr/bin/env bash
# Run every reach corpus against bin/lesson-overreach-lint and the fold
# regression against the folded bin/lesson-derive-gate. Exit 0 only if all
# recorded expectations hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
B="$ROOT/scratch/lesson-derive-gate-2026-10-10"
L="$ROOT/bin/lesson-overreach-lint"
G="$ROOT/bin/lesson-derive-gate"
pass=0; fail=0
chk() {
  name=$1; want=$2; shift 2
  out=$("$@" 2>&1); got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok   %-28s want=%s\n' "$name" "$want"; pass=$((pass+1))
  else
    printf 'FAIL %-28s want=%s got=%s\n' "$name" "$want" "$got"
    printf '%s\n' "$out" | head -2 | sed 's/^/     /'
    fail=$((fail+1))
  fi
}
echo "=== edge corpus (pre-registered 2026-10-10) ==="
while read -r want name; do
  [ -z "$want" ] && continue
  chk "edge/$name" "$want" "$L" "$B/edge/$name.md"
done < "$B/edge/exp.txt"
echo "=== reachgap corpus (recorded 10 refused / 6 pass) ==="
for f in "$B"/reachgap/m-*.md; do chk "reachgap/$(basename "$f" .txt)" 1 "$L" "$f"; done
for f in "$B"/reachgap/a-*.md; do chk "reachgap/$(basename "$f" .txt)" 0 "$L" "$f"; done
chk "reachgap/lesson-draft" 0 "$L" "$B/reachgap/lesson-draft.md"
echo "=== overreach/fix corpus (recorded 11) ==="
for f in "$B"/overreach/fix/accept-*.txt; do chk "over/$(basename "$f" .txt)" 0 "$L" "$f"; done
for f in "$B"/overreach/fix/refuse-*.txt; do chk "over/$(basename "$f" .txt)" 1 "$L" "$f"; done
echo "=== fold regression through the folded gate (recorded 35) ==="
# Adjudication 2026-10-11: recorded.txt paths are workdir-relative, so the
# harness must run from $ROOT or every recorded fixture reads as missing.
fold_out=$(cd "$ROOT" && bash "$B/fold/harness.sh" "$B/fold" "$G" x 2>&1); fold_rc=$?
printf '%s\n' "$fold_out" | tail -3 | sed 's/^/     /'
if [ "$fold_rc" -eq 0 ]; then
  printf 'ok   fold/harness (35 recorded)\n'; pass=$((pass+1))
else
  printf 'FAIL fold/harness\n'; fail=$((fail+1))
fi
echo "=== corpora the runner was blind to (added 2026-10-10) ==="
# Widenedge pass finding: run-all.sh covered only edge/reachgap/overreach/fix/
# fold, so softspot, seam, counttrail, barewidening, sothat and widenedge never
# ran in it. A regression to softspot/a-andverb landed in the seam pass and sat
# unseen because of this. Expectations resolve per corpus: expect.txt (name
# verdict), expected.tsv (tab), else the m-* refuse / a-* accept prefix rule
# (barewidening names files a1.md/m1.md; draft controls expect accept).
corpus_run() {
  cname=$1
  cdir="$B/$cname"
  # Recurse so fixtures in corpus subdirs are graded too (maxdepth-1 glob
  # silently skipped edge/labelbreak, irrtail/probes and relcl/gate).
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    rel=${f#"$cdir"/}
    base=$(basename "$f")
    want=""
    if [ -f "$cdir/expect.txt" ]; then
      # exact subpath first, then basename fallback
      want=$(awk -v n="$rel" '$1==n{print $2}' "$cdir/expect.txt")
      [ -n "$want" ] || want=$(awk -v n="$base" '$1==n{print $2}' "$cdir/expect.txt")
    elif [ -f "$cdir/expected.tsv" ]; then
      want=$(awk -F'\t' -v n="$rel" '$1==n{print $2}' "$cdir/expected.tsv")
      [ -n "$want" ] || want=$(awk -F'\t' -v n="$base" '$1==n{print $2}' "$cdir/expected.tsv")
    fi
    if [ -z "$want" ]; then
      case "$base" in
        m*|m-*) want=refuse ;;
        *draft*) want=accept ;;
        a*|a-*) want=accept ;;
      esac
    fi
    case "$want" in
      accept) w=0 ;;
      refuse) w=1 ;;
      *) continue ;;
    esac
    chk "$cname/$rel" "$w" "$L" "$f"
  done < <(find "$cdir" -type f -name '*.md' | sort)
}
# Vbshape pass finding 2026-10-11: adjrel, lexedge and sharedvp also sat
# outside the runner (relcl flips in them were only ever seen by the ad-hoc
# tree sweep), and the vbshape corpus joins here.
# Enumerate .md fixture dirs so no corpus drops out when a name is added.
# The four special corpora above (edge, reachgap, overreach, fold) are skipped.
for d in "$B"/*/; do
  cname=$(basename "$d")
  case "$cname" in
    edge|reachgap|overreach|fold) continue ;;
  esac
  if find "$d" -type f -name '*.md' -print -quit | grep -q .; then
    corpus_run "$cname"
  fi
done

echo "---"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
