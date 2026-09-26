# Per-persona prompts

`deploy/bootstrap-slack-identity.sh` installs `<name>.md` from this directory
as the identity's `core_identity_prompt.md` when it creates the identity
named by `SHELLM_SLACK_IDENTITY`. With no file here it falls back to
`../slack-persona.md`, the generic colleague template Audel started from.

The copy happens once, at creation. After that the live prompt is the one
in the identity dir on the box, and it is re-read on every wakeup. Edit
that copy by hand for a running persona; a change here reaches only
personas created after it.

`{{identity_name}}` in the text is replaced with the identity's name.
