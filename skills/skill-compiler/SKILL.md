---
name: skill-compiler
description: Generate and run validation cases for a trusted skill, then inspect a saved report of results and assertion provenance.
---

# skill-compiler

Use this when developing a skill or checking its documented behavior. It calls
`llm` to propose cases, runs each through `shellm`, and saves results. It does
not train an adapter, alter the skill, or add examples to `skills show`.

## Requirements and invocation

Requires Bash, Python 3, jq, and the existing `llm`, `shellm`, and `skills`
commands. Model calls use your normal llm configuration and can incur charges.
`--teacher-model` overrides only the teacher model; otherwise llm resolves its
model and provider normally, including `SHELLM_MODEL` and `LLM_PROVIDER`.

The installer copies this directory but does not add its executable to PATH.
For a standard installation:

```bash
sc="$HOME/.skills/core-skills/skill-compiler/skill-compiler"
"$sc" compile --skill shellm --num-tests 3 --max-iterations 5
"$sc" pool --skill shellm
"$sc" list
"$sc" show --skill shellm
"$sc" clean --skill shellm
```

From a source checkout, use `sc="$PWD/skills/skill-compiler/skill-compiler"`.
`SKILLS_DIR` defaults to the directory containing this skill;
`SKILLS_KERNEL_DIR` selects a second search root. An existing `SKILLS_DIR`
setting takes precedence. Test count defaults to 8, maximum iterations to 15.

Only run trusted skills. Both `compile` and `pool` can execute a skill script
with no arguments and with `--help`, in scratch with a 15-second deadline.
Tests use separate work, memory and trajectory directories. This is not an OS
sandbox and does not revoke inherited credentials or other filesystem access.
The fixed refusal list excludes known messaging, credential and live-store
skills. It rejects path spellings and aliases that bypass those names; installed
directory symlinks must retain the name, and files must remain inside the
resolved skill directory. This does not detect equivalent behavior in arbitrary
new skill code. Use an isolated environment for skills with side effects.

## Results and limits

Reports live in `<state-home>/skill-compiler/compiled`, independently of skill
reinstallation. State home follows `HEADLONG_HOME`, then `SHELLM_HOME`, then
`~/.headlong` (or existing `~/.shellm` if `~/.headlong` is absent).
`SKILL_COMPILED_DIR` overrides the report directory.

Each skill has a Markdown summary, JSON results, a `.json.prov` provenance
sidecar, and `pool-<skill>.json` containing offered and dropped vocabulary.
`clean` removes all four. Invocation scratch and completed test runs are removed
on exit. Set `SC_KEEP_RUNS=1` to retain them for debugging; their location is
printed to stderr. `SC_TMP_BASE` and `SC_RUNS_BASE` override scratch locations.

`pass` checks the expected terminal step and all requested literals in recorded
output or the final answer. Arbitrary workdir files are not evidence. A harness
setup failure records a failed case, retains preceding results, and returns a
nonzero status. Ordinary failed assertions are recorded in the report; compile
can still exit zero, so inspect `summary.fail`.

Literal labels are `POOL-EXACT`, `POOL-FRAGMENT`, `POOL-DROPPED` (eligible
vocabulary omitted by a cap), or `INVENTED` (not found in the collected pool).
Only passes with at least one literal and exclusively exact/fragment labels
are `VERIFIED`. Other statuses are `GREEN-ON-DROPPED`, `GREEN-ON-INVENTED`,
`GREEN-NO-LITERALS`, and `FAIL`. Counts are separate in the JSON summary.

VERIFIED means vocabulary attestation, not meaningful behavioral coverage.
Short or common phrases can be weak assertions. Review generated cases and
include negative cases that should fail. No literal length proves test quality.
`literal_sources` distinguishes actual captured `TOOL-OUTPUT` from script text,
documentation, metadata, and unattested strings. Static text alone does not
prove that a tool emitted it.

## Pool controls

`SKILL_POOL_SRC_CAP` (200 per static source), `SKILL_POOL_LIVE_CAP` (80),
`SKILL_HARVEST_MAX_ENTRIES` (300), and `SKILL_POOL_CAP` (400 combined) limit
offered vocabulary while retaining eligible omitted entries for provenance.
History is a sample of up to 300 matching trajectory files, not exhaustive output.
`SKILL_AUTO_HARVEST=0` disables history reads; otherwise it uses
`SKILL_HARVEST_TRAJ_DIR`, `TRAJ_DIR`, or `<state-home>/trajectories`.
`SKILL_HISTORY_POOL` supplies captured history explicitly, and
`SKILL_REAL_OUTPUT` supplies output for source classification. History JSON uses
`entries[].line`; metadata fields are never treated as output.

History caches live under `<state-home>/skill-compiler/history`, overridden by
`SKILL_HARVEST_CACHE`. TTL is `SKILL_HARVEST_TTL` seconds (3600);
`SKILL_HARVEST_REFRESH=1` rebuilds. `SKILL_HARVEST_ECHO_FILTER=music` optionally
filters note/interval echoes; it is off for general skills.

Generated tests contain `name`, `prompt`, `expect` (`final`, `observation`,
`shell-output`, or `error`), and optional `expect_contains` strings.
