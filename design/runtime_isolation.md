# Runtime isolation for a persona box

Status: all three layers built 2026-09-15 (layer 0 as a bind mount; Harris migrated the same day, Audel next).

## The problem

One Unix user, `shellm`, owns the runtime checkout, the dispatcher, the
web server, the Slack bridge, the root `.env` with every key, and the
identity directory the mind's shell commands run in. The identity
directory sits inside the checkout and the working directory inside
that. So a wake can edit `bin/`, install units, read the bridge tokens,
create identities and start servers with the permissions it was born
with. Five incidents in five weeks used one of those doors: the feeder
killed by the mind's own tests (08-14), fake goals from a nested
skill-compiler run (09-08), the `default` symlink repointed by a nested
run (09-09), the trajectory rewritten in place (09-12), and a second
identity plus two web servers that wedged the wake loop for seven hours
(09-14, `monolith_run_health.md` Issue D).

## Layers

1. **Read-only runtime from inside the wake** (built). A drop-in on
   `headlong-thinkers@.service` (`deploy/thinkers-sandbox.sh`,
   `HEADLONG_SANDBOX`, default on): `ProtectSystem=strict`, the shellm
   home writable, the app checkout read-only, the identity directory
   writable inside it, `/tmp` and `/var/tmp` shared and writable,
   `.env.bridge` inaccessible. Mount rules on the
   unit's namespace, so they cover everything a wake backgrounds. The
   mind keeps its identity directory (memories, prompts, thinker copies,
   workdir, its own clone) and loses in-place edits of the shared
   runtime, so box commits end and contributions go through its clone
   and pull requests, which it already does.
2. **Secret split** (built). `deploy/split-bridge-env.sh` moves the
   Slack bot and app tokens to `.env.bridge`, loaded only by the bridge
   unit. Alerts post with `HEADLONG_ALERT_TOKEN`, seeded as a copy of the
   bot token and meant to be replaced by a dedicated alert-only app.
   Telegram already had this shape.
3. **Identities out of the checkout** (built). The real directory is
   `/var/lib/headlong/identities`, bind-mounted at `app/.identities` via
   fstab (`deploy/setup.sh` provisions it; `deploy/update.sh` re-mounts it
   if dropped). Every tool keeps saying `.identities` and sees a plain
   directory. A symlink was tried first and rejected: systemd does not
   resolve symlinks in ReadWritePaths, the web scan treated the linked root
   as a candidate identity and never walked it (the bridges deliver inbound
   messages through that API, so Harris went deaf to Slack for a minute),
   and `find`/`tar` would not follow it either. The scan now walks a linked
   root one level anyway (belt and braces), and the sandbox installer
   resolves a link if one is ever used. Migration of an existing box is a
   deliberate step: stop thinkers, web and bridges; move the directory;
   mount; re-render the sandbox drop-in; start; verify from inside the
   unit. Twelve seconds of downtime on Harris.

Not chosen: a Unix user per persona (most of the value comes from the
namespace for far less migration; personas already live on separate
boxes) and a container per wake (no Docker on the box, and it would kill
the long background jobs the detach design has to make room for first).

## Verified

On Ubuntu 24.04 (systemd 255) with a transient unit carrying the same
directives, as user `shellm`: writes to `app/bin`, `app/.env`, a new
`app/.identities/<x>`, `/etc` and `/run` denied; writes to the identity
directory (by name and through the `default` symlink), `~/.cache`,
`/tmp` and `/var/tmp` allowed; `.env.bridge` unreadable; the sudo
wrapper (`headlong-thinkersctl`) still works, generic sudo is refused by
sudoers as before. Tests: `tests/test_thinkers_sandbox.sh`,
`tests/test_split_bridge_env.sh`.
