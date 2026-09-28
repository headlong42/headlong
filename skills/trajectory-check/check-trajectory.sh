#!/usr/bin/env bash
# check-trajectory.sh — audit recent trajectory steps for idle loops,
# repeated thoughts, and unverified claims.
# Extended with --deep mode for environment-quality auditing.
# Extended with --quality mode for quality sampling (retrieval relevance, skill success, semantic navigability).
set -euo pipefail

DEEP=0
QUALITY=0
N="${1:-30}"
TRAJ_FILE="${TRAJ_FILE:-/opt/shellm/app/.identities/audel/trajectories/455a2181-root/trajectory.jsonl}"

while [ $# -gt 0 ]; do
  case "$1" in
    --deep) DEEP=1; shift ;;
    --quality) QUALITY=1; shift ;;
    --help|-h) echo "Usage: check-trajectory.sh [N] [--deep] [--quality]"; echo "  TRAJ_FILE=/path/to/trajectory.jsonl check-trajectory.sh [N] [--deep] [--quality]"; exit 0 ;;
    *) [[ "$1" =~ ^[0-9]+$ ]] && N="$1"; shift ;;
  esac
done

# count_lines_matching: count lines in input that match positive patterns
# but do NOT match negative patterns
count_lines_matching() {
  local input="$1"
  shift
  local positives=()
  local negatives=()
  for p in "$@"; do
    if [[ "$p" =~ ^! ]]; then
      negatives+=("${p#!}")
    else
      positives+=("$p")
    fi
  done
  [ ${#positives[@]} -eq 0 ] && { echo 0; return; }
  [ -z "$input" ] && { echo 0; return; }
  
  local pos_pattern=$(printf '%s|' "${positives[@]}" | sed 's/|$//')
  local neg_pattern=""
  if [ ${#negatives[@]} -gt 0 ]; then
    neg_pattern=$(printf '%s|' "${negatives[@]}" | sed 's/|$//')
  fi
  
  # Use awk to avoid broken pipes
  if [ -n "$neg_pattern" ]; then
    printf '%s\n' "$input" | awk -v pos="$pos_pattern" -v neg="$neg_pattern" '
      BEGIN {IGNORECASE=1; split(pos, pa, "|"); split(neg, na, "|")}
      {
        match_pos=0
        for (i in pa) if ($0 ~ pa[i]) {match_pos=1; break}
        if (!match_pos) next
        match_neg=0
        for (i in na) if ($0 ~ na[i]) {match_neg=1; break}
        if (!match_neg) count++
      }
      END {print count+0}'
  else
    printf '%s\n' "$input" | awk -v pos="$pos_pattern" '
      BEGIN {IGNORECASE=1; split(pos, pa, "|")}
      {
        for (i in pa) if ($0 ~ pa[i]) {count++; break}
      }
      END {print count+0}'
  fi
}

# count_commands_matching: count commands in trajectory JSON that match patterns
count_commands_matching() {
  local json_input="$1"
  shift
  [ $# -eq 0 ] && { echo 0; return; }
  [ -z "$json_input" ] && { echo 0; return; }
  
  local pattern=$(printf '%s|' "$@" | sed 's/|$//')
  printf '%s\n' "$json_input" | jq -r 'select(.type=="reasoning") | .cmd' 2>/dev/null | grep -iEc "$pattern" 2>/dev/null || true
}

# count_shell_outputs: count shell-output steps matching patterns by exit code
count_shell_outputs() {
  local json_input="$1"
  shift
  [ -z "$json_input" ] && { echo 0; return; }
  
  local pattern=$(printf '%s|' "$@" | sed 's/|$//')
  printf '%s\n' "$json_input" | jq -r 'select(.type=="shell-output") | "\(.stdout) \(.stderr)"' 2>/dev/null | grep -iEc "$pattern" 2>/dev/null || true
}

# count_shell_success: count successful shell-output steps (exit 0)
count_shell_success() {
  local json_input="$1"
  [ -z "$json_input" ] && { echo 0; return; }
  printf '%s\n' "$json_input" | jq -r 'select(.type=="shell-output" and .exit==0) | .run_id' 2>/dev/null | wc -l
}

# read_valid_json: read last N valid JSON lines from trajectory file
read_valid_json() {
  local file="$1"
  local n="$2"
  [ -f "$file" ] || { echo ""; return; }
  
  awk '/^\{.*\}$/ { print }' "$file" | tail -n "$n"
}

# ===== QUALITY SAMPLING FUNCTIONS =====

# Sample mem search results for relevance quality
# Returns: JSON with total_searches, samples_analyzed, relevant_count, relevance_rate
# Normalize reasoning/shell-output steps for quality sampling. jq reads each
# stdout whole (a line regex stopped at the first JSON backslash and truncated
# what the checks saw). The exclusion is a no-result SHAPE test, not a word
# blacklist: on 2026-09-28 the word list was narrowed away after it scored
# genuinely relevant hits irrelevant whenever their text used an excluded word
# (one of three real mem searches flipped on the phrase "empty or zero"). A row
# is excluded only when the output is blank or its first line is a bare
# no-result phrase such as "No matches found." or "No memories stored."
# DEEPEN 2026-09-28: the no-result phrase test now scans every line after a
# tool-prefix strip and is vetoed by a memory-entry marker line. The earlier
# first-line-only test leaked when a zero-hit output began with a blank line
# or a warning/tool preamble (3 of 6 adversarial zero-hit rows counted as
# relevant), and this closes those without reopening word over-exclusion:
# a hit whose text leads a line with such a phrase is kept when it shows an
# entry marker (==== header or a name.md line).
quality_rows() {
  local json_input="$1"
  printf '%s\n' "$json_input" | jq -c '
    def norm: gsub("[[:space:]]+"; " ") | ascii_downcase | sub("[[:punct:]]+$"; "");
    def no_result_shape:
      (((. // "") | gsub("[[:space:]]"; "") | length) == 0)
      or ( ((. // "") | split("\n")
             | map(sub("^[a-z][a-z0-9 ]*:[[:space:]]*"; "") | norm
                   | test("^(no (matches|memories|results?|result)( found| stored| were found)?|nothing (was )?found|none found|not found|0 results?|no (semantically )?matching (memories|results)( were)? found|(memory|entry|file|path|record|id) not found)"))
             | any)
           and (((. // "") | split("\n")
                 | map(select(test("^[[:space:]]*=+.*=+[[:space:]]*$")
                              or test("^[0-9A-Za-z._-]+\\.md\\b")))
                 | length) == 0) );
    select(.type=="reasoning" or .type=="shell-output")
    | if .type=="reasoning" then
        {t:"r", run:(.run_id // ""), cmd:(.cmd // "")}
      else
        (.stdout // "") as $s
        | {t:"o", run:(.run_id // ""), exit:(.exit // 0), len:($s | length),
           keep:(($s | no_result_shape) | not)}
      end
  ' 2>/dev/null
}

# Count sampled outputs that pair with a trigger command and pass the bar:
# exit 0, output is not a no-result shape, longer than minlen.
# Prints "analyzed relevant total".
count_relevant_rows() {
  local json_input="$1"
  local trigger="$2"
  local minlen="$3"
  local sample_n="$4"
  quality_rows "$json_input" | awk -v trig="$trigger" -v minlen="$minlen" -v sample_n="$sample_n" '
    BEGIN { last=""; total=0; analyzed=0; relevant=0 }
    /"t":"r"/ {
      if ($0 ~ trig) {
        total++
        if (match($0, /"run":"([^"]+)"/, a)) last=a[1]; else last=""
      } else last=""
      next
    }
    /"t":"o"/ && last != "" {
      if (match($0, /"run":"([^"]+)"/, a) && a[1]==last && analyzed < sample_n) {
        analyzed++
        exit_code=0; if (match($0, /"exit":([0-9]+)/, a)) exit_code=a[1]
        outlen=0; if (match($0, /"len":([0-9]+)/, a)) outlen=a[1]
        if (exit_code==0 && $0 ~ /"keep":true/ && outlen > minlen) relevant++
      }
      last=""
    }
    END { printf("%d %d %d", analyzed, relevant, total) }
  '
}

rate_of() {
  awk -v r="$1" -v a="$2" 'BEGIN { v = 0; if (a > 0) v = r * 100 / a; printf "%.1f", v }'
}

sample_mem_relevance() {
  local json_input="$1"
  local sample_size="${2:-10}"
  local counts
  counts=$(count_relevant_rows "$json_input" "mem search" 50 "$sample_size")
  set -- $counts
  printf '{"total_searches":%d,"samples_analyzed":%d,"relevant_count":%d,"relevance_rate":%s}' \
    "$3" "$1" "$2" "$(rate_of "$2" "$1")"
}


# Sample skill load/execution success rates
# Returns: JSON with total_calls, samples_analyzed, success_count, success_rate
sample_skill_quality() {
  local json_input="$1"
  local sample_size="${2:-10}"
  
  # Extract skills commands with run_id
  local skills_calls=$(printf '%s\n' "$json_input" | jq -c '
    select(.type=="reasoning" and .cmd and (.cmd | contains("skills ")))
    | {step_id, run_id, cmd}
  ' 2>/dev/null)
  
  [ -z "$skills_calls" ] && { echo '{"total_calls":0,"samples_analyzed":0,"success_count":0,"success_rate":0}'; return; }
  
  local total=$(printf '%s\n' "$skills_calls" | wc -l)
  local sample_n=$(( total < sample_size ? total : sample_size ))
  
  # Analyze shell outputs for skills commands by run_id
  printf '%s\n' "$json_input" | jq -c 'select(.type=="reasoning" or .type=="shell-output")' 2>/dev/null | \
  awk -v sample_n="$sample_n" -v total="$total" '
    BEGIN { 
      last_skill_run=""; last_skill_cmd=""; 
      success=0; analyzed=0; 
    }
    /"type":"reasoning"/ {
      if ($0 ~ /skills /) {
        match($0, /"run_id":"([^"]+)"/, arr); last_skill_run=arr[1]
        match($0, /"cmd":"([^"]+)"/, arr); last_skill_cmd=arr[1]
      } else {
        last_skill_run=""; last_skill_cmd=""
      }
    }
    /"type":"shell-output"/ && last_skill_run != "" {
      match($0, /"run_id":"([^"]+)"/, arr); out_run=arr[1]
      if (out_run == last_skill_run && analyzed < sample_n) {
        analyzed++
        exit_code=0
        match($0, /"exit":([0-9]+)/, arr); exit_code=arr[1]
        if (exit_code == 0) success++
      }
      last_skill_run=""; last_skill_cmd=""
    }
    END {
      printf("{\"total_calls\":%d,\"samples_analyzed\":%d,\"success_count\":%d,\"success_rate\":%.1f}", 
        total, analyzed, success, analyzed>0 ? (success*100/analyzed) : 0)
    }
  '
}

# Sample trajectory navigability for semantic coherence
# Check if traj search/tail/show commands are followed by meaningful results
# Returns: JSON with total_nav, samples_analyzed, coherent_count, coherence_rate
sample_navigability_quality() {
  local json_input="$1"
  local sample_size="${2:-10}"
  local counts
  counts=$(count_relevant_rows "$json_input" "traj (search|tail|show|cat)" 100 "$sample_size")
  set -- $counts
  printf '{"total_nav":%d,"samples_analyzed":%d,"coherent_count":%d,"coherence_rate":%s}' \
    "$3" "$1" "$2" "$(rate_of "$2" "$1")"
}


ISSUES=0
DEEP_ISSUES=0
# ===== MAIN CHECKS =====

# Read last N valid JSON lines
RAW="$(read_valid_json "$TRAJ_FILE" "$N")"

# 1. Idle loop check
IDLE_MAX=$(printf '%s\n' "$RAW" | jq -r 'select(.type=="idle") | .type' 2>/dev/null | awk '{c++; if(c>m)m=c} END{print m+0}')

if [ "$IDLE_MAX" -ge 3 ]; then
  echo "✗ Idle loop: $IDLE_MAX consecutive idle steps — you may be stuck."
  ISSUES=$((ISSUES+1))
else
  echo "✓ No idle loop ($IDLE_MAX consecutive)."
fi

# 2. Repeated thoughts
THOUGHTS=$(printf '%s\n' "$RAW" | jq -r 'select(.type=="thought") | .content' 2>/dev/null)
REPEAT_COUNT=0
if [ -n "$THOUGHTS" ]; then
  REPEAT_COUNT=$(printf '%s\n' "$THOUGHTS" | sort | uniq -c | awk '$1>1 {sum+=$1} END{print sum+0}')
fi

if [ "$REPEAT_COUNT" -gt 0 ]; then
  echo "✗ Repeated thoughts: $REPEAT_COUNT duplicate thought(s) in recent history."
  ISSUES=$((ISSUES+1))
else
  echo "✓ No repeated thoughts."
fi

# 3. Unverified claims (outbound chat messages with factual claims about repo/code)
OUTBOUND=$(printf '%s\n' "$RAW" | jq -r 'select(.type=="message" and .from=="audel") | .content' 2>/dev/null)
CLAIM_ISSUES=0
if [ -n "$OUTBOUND" ]; then
  CLAIM_ISSUES=$(printf '%s\n' "$OUTBOUND" | while IFS= read -r msg; do
    if printf '%s\n' "$msg" | grep -qiE 'deployed|merged|fixed|passing|failing|works|broken|commit|push|pull|branch|PR|issue|test.*pass|test.*fail|build.*pass|build.*fail'; then
      echo "1"
    fi
  done | wc -l)
fi

if [ "$CLAIM_ISSUES" -gt 0 ]; then
  echo "✗ Unverified claims: $CLAIM_ISSUES outbound message(s) with factual claims but no prior verification."
  ISSUES=$((ISSUES+1))
else
  echo "✓ No outbound claims to verify."
fi

ISSUES=${ISSUES:-0}

# --- Deep Mode: Environment Quality Audit ---
if [ "$DEEP" -eq 1 ]; then
  echo ""
  echo "=== Deep Mode: Environment Quality Audit ==="
  
  # Read baseline (2*N steps before the recent N)
  BASELINE_N=$((N * 2))
  BASELINE_RAW="$(read_valid_json "$TRAJ_FILE" "$BASELINE_N")"
  # Keep only the first N lines (older half) - use awk to avoid broken pipe
  BASELINE_RAW=$(printf '%s\n' "$BASELINE_RAW" | awk 'NR <= n' n="$N")
  
  # Dim 1: Memory Retrieval
  R_HITS=$(count_lines_matching "$RAW" 'hit' 'found' 'retrieved' 'matched' 'result' '!miss' '!no result' '!empty' '!not found' '!zero')
  R_MISSES=$(count_lines_matching "$RAW" 'miss' 'no result' 'empty' 'not found' 'zero')
  B_HITS=$(count_lines_matching "$BASELINE_RAW" 'hit' 'found' 'retrieved' 'matched' 'result' '!miss' '!no result' '!empty' '!not found' '!zero')
  B_MISSES=$(count_lines_matching "$BASELINE_RAW" 'miss' 'no result' 'empty' 'not found' 'zero')
  
  echo ""
  echo "--- Memory Retrieval ---"
  echo "  Recent: hits=$R_HITS misses=$R_MISSES"
  echo "  Baseline: hits=$B_HITS misses=$B_MISSES"
  if [ "$((R_HITS + R_MISSES))" -gt 0 ] && [ "$((B_HITS + B_MISSES))" -gt 0 ]; then
    R_RATE=$(( R_HITS * 100 / (R_HITS + R_MISSES) ))
    B_RATE=$(( B_HITS * 100 / (B_HITS + B_MISSES) ))
    echo "  Recent: ${R_RATE}%  Baseline: ${B_RATE}%"
    if [ "$R_RATE" -gt "$B_RATE" ]; then echo "  ✓ IMPROVED";
    elif [ "$R_RATE" -eq "$B_RATE" ]; then echo "  → STABLE";
    else echo "  ⚠ DECLINED"; ISSUES=$((ISSUES+1)); fi
  else
    echo "  → Insufficient data"
  fi
  
  # Dim 2: Skill Adaptation
  R_SKILL_CALLS=$(count_commands_matching "$RAW" 'skills install' 'skills show' 'skills init' 'skills list' 'skills update')
  R_SKILL_OUTPUTS=$(count_shell_outputs "$RAW")
  R_SKILL_SUCCESS=$(count_shell_success "$RAW")
  
  B_SKILL_CALLS=$(count_commands_matching "$BASELINE_RAW" 'skills install' 'skills show' 'skills init' 'skills list' 'skills update')
  B_SKILL_OUTPUTS=$(count_shell_outputs "$BASELINE_RAW")
  B_SKILL_SUCCESS=$(count_shell_success "$BASELINE_RAW")
  
  echo ""
  echo "--- Skill Adaptation ---"
  echo "  Recent: calls=$R_SKILL_CALLS shell-outputs=$R_SKILL_OUTPUTS success=$R_SKILL_SUCCESS"
  echo "  Baseline: calls=$B_SKILL_CALLS shell-outputs=$B_SKILL_OUTPUTS success=$B_SKILL_SUCCESS"
  if [ "$R_SKILL_OUTPUTS" -gt 0 ] && [ "$B_SKILL_OUTPUTS" -gt 0 ]; then
    R_RATE=$(( R_SKILL_SUCCESS * 100 / R_SKILL_OUTPUTS ))
    B_RATE=$(( B_SKILL_SUCCESS * 100 / B_SKILL_OUTPUTS ))
    echo "  Recent: ${R_RATE}%  Baseline: ${B_RATE}%"
    if [ "$R_RATE" -gt "$B_RATE" ]; then echo "  ✓ IMPROVED";
    elif [ "$R_RATE" -eq "$B_RATE" ]; then echo "  → STABLE";
    else echo "  ⚠ DECLINED"; ISSUES=$((ISSUES+1)); fi
  else
    echo "  → Insufficient data"
  fi
  
  # Dim 3: Trajectory Navigability
  R_NAV=$(count_commands_matching "$RAW" 'traj search' 'traj tail' 'traj show' 'mem search' 'grep ' 'find ')
  B_NAV=$(count_commands_matching "$BASELINE_RAW" 'traj search' 'traj tail' 'traj show' 'mem search' 'grep ' 'find ')
  
  echo ""
  echo "--- Trajectory Navigability ---"
  echo "  Recent: $R_NAV  Baseline: $B_NAV"
  if [ "$R_NAV" -gt "$B_NAV" ]; then echo "  ✓ IMPROVED";
  elif [ "$R_NAV" -eq "$B_NAV" ]; then echo "  → STABLE";
  else echo "  ⚠ DECREASED"; ISSUES=$((ISSUES+1)); fi
  
  DEEP_ISSUES=$((ISSUES-3))
  echo ""
  echo "=== Deep Mode Summary ==="
  [ $DEEP_ISSUES -gt 0 ] && echo "✗ DECLINING across $DEEP_ISSUES dimension(s)" || echo "✓ STABLE or IMPROVING"
fi

# --- Quality Mode: Semantic Quality Sampling ---
if [ "$QUALITY" -eq 1 ]; then
  echo ""
  echo "=== Quality Mode: Semantic Quality Sampling ==="
  QUALITY_ISSUES=0
  
  # Sample memory retrieval relevance
  echo ""
  echo "--- Memory Retrieval Relevance ---"
  MEM_QUALITY=$(sample_mem_relevance "$RAW" 10)
  echo "$MEM_QUALITY" | jq -r '
    "  Total searches: \(.total_searches)",
    "  Samples analyzed: \(.samples_analyzed)",
    "  Relevant: \(.relevant_count)",
    "  Relevance rate: \(.relevance_rate)%"
  '
  RELEVANCE_RATE=$(echo "$MEM_QUALITY" | jq -r '.relevance_rate')
  if (( $(echo "$RELEVANCE_RATE < 50" | bc -l 2>/dev/null || echo "0") )); then
    echo "  ⚠ LOW RELEVANCE - mem searches returning garbage"
    QUALITY_ISSUES=$((QUALITY_ISSUES+1))
  elif (( $(echo "$RELEVANCE_RATE < 75" | bc -l 2>/dev/null || echo "0") )); then
    echo "  → MODERATE RELEVANCE"
  else
    echo "  ✓ HIGH RELEVANCE"
  fi
  
  # Sample skill execution success
  echo ""
  echo "--- Skill Execution Quality ---"
  SKILL_QUALITY=$(sample_skill_quality "$RAW" 10)
  echo "$SKILL_QUALITY" | jq -r '
    "  Total skill calls: \(.total_calls)",
    "  Samples analyzed: \(.samples_analyzed)",
    "  Successful: \(.success_count)",
    "  Success rate: \(.success_rate)%"
  '
  SKILL_RATE=$(echo "$SKILL_QUALITY" | jq -r '.success_rate')
  if (( $(echo "$SKILL_RATE < 50" | bc -l 2>/dev/null || echo "0") )); then
    echo "  ⚠ LOW SUCCESS RATE - skills failing frequently"
    QUALITY_ISSUES=$((QUALITY_ISSUES+1))
  elif (( $(echo "$SKILL_RATE < 75" | bc -l 2>/dev/null || echo "0") )); then
    echo "  → MODERATE SUCCESS RATE"
  else
    echo "  ✓ HIGH SUCCESS RATE"
  fi
  
  # Sample trajectory navigability coherence
  echo ""
  echo "--- Trajectory Navigability Coherence ---"
  NAV_QUALITY=$(sample_navigability_quality "$RAW" 10)
  echo "$NAV_QUALITY" | jq -r '
    "  Total nav commands: \(.total_nav)",
    "  Samples analyzed: \(.samples_analyzed)",
    "  Coherent results: \(.coherent_count)",
    "  Coherence rate: \(.coherence_rate)%"
  '
  COHERENCE_RATE=$(echo "$NAV_QUALITY" | jq -r '.coherence_rate')
  if (( $(echo "$COHERENCE_RATE < 50" | bc -l 2>/dev/null || echo "0") )); then
    echo "  ⚠ LOW COHERENCE - traj navigation returning noise"
    QUALITY_ISSUES=$((QUALITY_ISSUES+1))
  elif (( $(echo "$COHERENCE_RATE < 75" | bc -l 2>/dev/null || echo "0") )); then
    echo "  → MODERATE COHERENCE"
  else
    echo "  ✓ HIGH COHERENCE"
  fi
  
  echo ""
  echo "=== Quality Mode Summary ==="
  [ $QUALITY_ISSUES -gt 0 ] && echo "✗ QUALITY ISSUES across $QUALITY_ISSUES dimension(s)" || echo "✓ QUALITY HEALTHY"
  
  ISSUES=$((ISSUES + QUALITY_ISSUES))
fi

echo ""
echo "=== Summary ==="
[ $ISSUES -gt 0 ] && { echo "✗ $ISSUES issue(s) found."; exit 1; } || { echo "✓ Healthy."; exit 0; }
