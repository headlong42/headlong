# Mid-Run Interruption — Run-Scoped Design

Status: PROPOSAL — building on append-only trajectory discipline and HMAC verification foundation

## Motivation

The dispatcher currently supports mid-run message injection via `feedback` steps (commit d8df6ce): when a human message queues behind a busy agentic run, a `feedback` step lands in the trajectory the run is reading, carrying a one-shot `chat reply --reply-to` instruction. The model can answer inline without stopping its work.

This works for *inbound human messages only*. It does not cover:
- **Self-initiated interruption**: the mind deciding mid-run to pause, reflect, or change course
- **Structured preemption**: a higher-priority trigger (scheduled wake, goal deadline, external signal) that should interrupt the current run cleanly
- **Run-scoped checkpointing**: the ability to resume the interrupted run from a known-good point, not from scratch

The invitation from Nick (Sep 13, trajectory-corruption fallout discussion): *"agreed to keep trajectories append-only, drop the FAKE-step injection test script, stop killing/restarting services during self-diagnosis... leaving an open invitation to write a run-scoped design for mid-run interruption if I still think it matters."*

This design proposes a run-scoped interruption mechanism that:
1. Respects append-only trajectories (no in-place rewrites)
2. Uses the existing HMAC verification foundation (`traj verify`) for integrity
3. Works within the dispatcher's existing subscription/pending queue model
4. Allows clean resume from a checkpoint step

---

## Core Concept: Interruption Checkpoint Step

A new step type `interruption` (family: machinery, writer: shellm run loop) that marks a deliberate pause point in a run.

```json
{
  "type": "interruption",
  "step_id": "<uuid>",
  "ts": "...",
  "run_id": "<run-header-step-id>",
  "reason": "scheduled-wake|goal-deadline|self-reflection|external-signal",
  "trigger_step": "<step-id-that-caused-interruption>",
  "checkpoint": {
    "context_hash": "<sha256-of-relevant-context-at-pause>",
    "pending_tools": [],
    "partial_reasoning": "<truncated reasoning up to this point>",
    "resume_hint": "continue|replan|abort"
  }
}
```

**Key properties:**
- Written by the shellm run loop itself when it decides to yield (not by the dispatcher)
- Carries `run_id` so it's tied to the run, not the trajectory
- `context_hash` enables verification on resume that the trajectory wasn't corrupted
- `resume_hint` guides the resumed run's behavior

---

## Trigger Paths

### 1. Scheduled Wake (existing backoff timer)
The monolith already uses `trigger_self:false` + timer for scheduled wakes (monolith_backoff.md). When a scheduled wake fires *during* an active run:
- Dispatcher sees the timer trigger as a new step matching the monolith's subscription
- Since the monolith is busy, the trigger goes to the pending queue (coalesced, last-wins)
- **New**: the run loop checks for pending scheduled-wake triggers at safe yield points (between tool calls, after reasoning blocks) and writes an `interruption` step with `reason: "scheduled-wake"`

### 2. Goal Deadline
Goals with `--until` dates (mem add --type todo --until) can register a deadline trigger. Same pending-queue path as scheduled wake.

### 3. Self-Reflection (model-driven)
The monolith's prompt already includes: *"A wakeup with no message to answer is a chance to think, not a reason to go dormant."* The model can decide mid-reasoning to pause and write an `interruption` step with `reason: "self-reflection"`.

### 4. External Signal (SIGHUP, operator command)
A `thinkers step <name>` manual trigger or operator signal follows the same pending-queue path.

---

## Dispatcher Integration

The dispatcher already has the machinery:
- Pending queue with coalescing for non-message/action types
- Per-thinker busy tracking (`_thinker_busy`)
- Feedback injection for inbound messages

**Changes needed:**
1. **Yield-point protocol**: The run loop (shellm) exposes a `--yield-check` flag or environment variable that makes it check for pending triggers at safe points and write an `interruption` step if found.
2. **Pending trigger inspection**: A lightweight way for the run to ask "is there a pending trigger for me?" without full dispatcher round-trip. Could read `$run_dir/pending/<thinker>.coalesced` directly.
3. **Interruption step type**: Add to trajectory spec, recognized by `traj` and context assembly.

---

## Resume Protocol

When the dispatcher later dispatches the same thinker again (after the interruption step is processed and the thinker is no longer busy):

1. **Context assembly** includes the `interruption` step and its `checkpoint` fields
2. **Verification**: The resumed run computes `sha256(context_at_resume_start)` and compares to `checkpoint.context_hash`. Mismatch → trajectory corruption detected → run aborts with observation, dispatcher alert.
3. **Resume behavior** guided by `resume_hint`:
   - `continue`: Pick up reasoning where it left off (partial_reasoning provides continuity)
   - `replan`: Discard partial work, start fresh with new context (default for scheduled-wake)
   - `abort`: End run with `final` summarizing what was done, why interrupted

---

## HMAC Verification Integration

The `traj verify` command (27 passing tests, commit 1adc15c) provides HMAC-SHA256 integrity for the trajectory. The interruption design leverages this:

- `checkpoint.context_hash` = HMAC of the trajectory prefix up to the interruption step (using the same key as `traj verify`)
- On resume, the run verifies the trajectory prefix still matches the HMAC
- If `traj verify` would fail on the prefix, the resume aborts immediately

This makes interruption checkpoints **cryptographic witnesses** to trajectory integrity at the pause point.

---

## Append-Only Discipline

No in-place rewrites anywhere:
- The `interruption` step is appended like any other step
- The original run's `final` step is **not written** when interrupted (the run ends without final)
- On resume, a new `shellm-run` header is written with a new `run_id`, linked via `trigger_step` to the interruption step
- The trajectory shows the full history: run A → interruption → run B (resume) → final

---

## Failure Modes & Handling

| Scenario | Behavior |
|----------|----------|
| Run crashes before writing interruption | No interruption step; next dispatch starts fresh (existing behavior) |
| Interruption written, dispatcher dies before resuming | `thinkers start` wake-gap note detects downtime; resume on next dispatch |
| Trajectory corrupted between interruption and resume | HMAC mismatch on resume → abort with observation, alert dispatcher |
| Multiple interruptions before resume | Each writes its own interruption step; resume sees the latest |
| Run ignores interruption (bug) | Watchdog (THINKERS_WATCHDOG_SECS) eventually fires synthetic idle trigger |

---

## Implementation Sketch

### 1. Trajectory Spec Addition
Add `interruption` to step types registry in `design/trajectory_spec.md`.

### 2. Shellm Run Loop Changes (`bin/shellm`)
- New env var `SHELLM_YIELD_CHECK=1` enables yield-point checking
- At each safe point (after tool, after reasoning block), if enabled:
  - Check `$run_dir/pending/<thinker>.coalesced` for pending trigger
  - If found, write `interruption` step via `traj append` with checkpoint data
  - Exit run loop cleanly (rc=0, no `final` step)

### 3. Dispatcher Changes (`bin/thinkers`)
- When a thinker becomes unbusy, the pending coalesced trigger (if any) fires naturally
- No new logic needed — the existing pending queue handles it
- The resumed run sees the interruption step in its context

### 4. Context Assembly (`bin/context`)
- Include `interruption` steps in recent stream
- Surface `checkpoint.resume_hint` in wake prompt when present

### 5. Verification Helper (`bin/traj`)
- `traj verify --prefix <step_id>` to verify trajectory prefix up to a step
- Used by resumed run to validate `checkpoint.context_hash`

---

## Example Flow

```
T=0    Run A starts (run_id=aaa), writes shellm-run header
T=10   Run A reasoning, tool calls...
T=30   Scheduled wake fires → pending queue (monolith busy)
T=35   Run A yield point → sees pending → writes interruption (reason=scheduled-wake, resume_hint=replan)
T=35   Run A exits cleanly (no final)
T=36   Dispatcher processes interruption step, marks monolith unbusy
T=36   Pending scheduled-wake trigger fires → dispatches monolith again
T=37   Run B starts (run_id=bbb), trigger_step=interruption-step-id
T=37   Run B context includes interruption step + checkpoint
T=37   Run B verifies HMAC prefix → OK
T=37   Run B reads resume_hint=replan → starts fresh reasoning
T=50   Run B completes → writes final step
```

Trajectory shows:
```
shellm-run (aaa) → reasoning → tool → reasoning → interruption → shellm-run (bbb, trigger_step=interruption) → reasoning → final
```

---

## Open Questions

1. **Yield point granularity**: After every tool call? After reasoning blocks? Configurable?
2. **Checkpoint size**: How much partial_reasoning to store? Token budget?
3. **Concurrent interruptions**: If two triggers fire before yield point, which wins? (Coalesced queue says last-wins)
4. **Human-in-the-loop**: Should an interruption ever wait for human confirmation before resume? (Probably not — runs are fast)
5. **Skill integration**: Can a skill request an interruption? (Via `action` step with special type?)

---

## Next Steps

1. Add `interruption` step type to trajectory spec
2. Implement yield-check in shellm run loop (behind `SHELLM_YIELD_CHECK`)
3. Wire pending-trigger check at yield points
4. Update context assembly to surface interruption checkpoints
5. Add `traj verify --prefix` for resume verification
6. Test with monolith scheduled-wake path first
7. Extend to goal deadlines and manual triggers

---

## Related Work

- `design/trajectory_spec.md` — step format, append-only discipline
- `design/monolith_run_health.md` — run health, SIGPIPE fixes, context bloat
- `design/monolith_backoff.md` — scheduled wake, trigger_self:false + timer
- `design/monolith_thinker.md` — monolith architecture, single thinker
- `bin/traj` — `verify` command (HMAC-SHA256), append locking
- `bin/thinkers` — dispatcher, pending queue, feedback injection
- Commit d8df6ce — mid-run message injection via feedback steps
- Commit 1adc15c — traj verify HMAC implementation (27 tests)
