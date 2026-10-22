# Scheduled wake recovery limit

See [dispatcher ownership and scheduled wakes](../../design/THINKERS_spec.md#dispatcher-ownership-and-scheduled-wakes)
for the current receipt lifecycle, stop behavior, and one-pending-time-per-thinker
collision rule. A valid existing schedule takes precedence over a stale claim;
the missed occurrence is not replayed. This note was originally written for
fork PR 3 and is retained as a pointer to the dispatcher specification.
