---
name: trajectory-check
description: Audit your recent trajectory for idle loops, repeated thoughts, and unverified claims — a self-discipline check to keep your inner life productive. Run periodically when waking up with no message to answer, or when you suspect you've been spinning.
---

# trajectory-check

## When to use

- You wake up with no message to answer and want to make sure you're not stuck in an idle loop.
- You suspect you've been repeating the same thought or action across wakeups.
- You want to check whether recent factual claims (in outbound messages) were preceded by verification commands.
- You want to audit environment quality: memory retrieval relevance, skill execution success, trajectory navigability coherence.
- Periodically, as a self-discipline habit — "am I actually making progress, or just ticking?"

## What it does

Reviews your root trajectory's recent steps and flags:

1. **Idle loops**: 3 or more consecutive `idle` steps — you may be stuck and should pick a concrete task.
2. **Repeated thoughts**: the same (or near-same) thought content appearing 2+ times in recent history — you're re-orienting without acting.
3. **Unverified claims**: outbound chat messages containing factual claims about repo/code/system state that were NOT preceded within the same wakeup by a verification command (git, ls, cat, grep, curl, etc.).

**Deep mode (`--deep`)** adds environment-quality auditing across three dimensions:
- Memory Retrieval: hit/miss rates improving across wake/sleep cycles
- Skill Adaptation: success rates for skill loads/executions
- Trajectory Navigability: command frequency for finding what you need

**Quality mode (`--quality`)** adds semantic quality sampling:
- Memory Retrieval Relevance: samples mem search outputs for actual relevance (not just presence)
- Skill Execution Quality: samples skill calls for true success rates
- Trajectory Navigability Coherence: samples navigation commands for meaningful results

Prints a summary with counts and excerpts so you can course-correct.

## Usage

```bash
bash skills/trajectory-check/check-trajectory.sh [N] [--deep] [--quality]
# N = number of recent steps to review (default: 30)
# --deep = enable environment-quality audit (compares recent vs baseline)
# --quality = enable semantic quality sampling (samples outputs for relevance/success/coherence)
```

Exit code 0 = no issues found (or only minor). Non-zero = issues detected — read the output and adjust.

## Examples

```bash
# Quick health check (last 30 steps)
check-trajectory.sh

# Deep environment audit (last 100 steps vs prior 100)
check-trajectory.sh 100 --deep

# Quality sampling (last 50 steps)
check-trajectory.sh 50 --quality

# Full audit
check-trajectory.sh 200 --deep --quality
```
