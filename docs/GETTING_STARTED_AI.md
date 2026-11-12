# Getting started with an AI coding agent

Order of work: **design first, then build.** Both are session-based protocols with their own state file,
so a new session can always continue. Always review at each stop point.

## 1. Check the environment
```
scripts\check-setup.ps1      # Windows
scripts/check-setup.sh       # macOS / Linux
```

## 2. Design phase (documentation only, no code)
Start, in Plan mode:
```
Read docs/DESIGN_PROTOCOL.md and CLAUDE.md. Follow the design protocol exactly.
This is a documentation-only task: do not change code, migrations, tests or build files.
Do the Orient step, then produce the architecture overview and the first version of the
pattern catalogue, then stop for my review.
```
Continue after each review:
```
Read docs/DESIGN_PROTOCOL.md and docs/design/DESIGN_STATE.md. The last item is approved.
Produce the next phase LLD, then stop for review.
```
Several phases at once:
```
Continue through the Phase 3 LLD without stopping between phases, then stop for review.
```

## 3. Build phase
Start:
```
Read docs/BUILD_PROTOCOL.md and CLAUDE.md. Follow the protocol exactly, starting at Phase 0.
Do Step 1 (Orient) and Step 2 (Plan), then stop and wait for my approval.
```
Continue in a later session:
```
Read docs/BUILD_PROTOCOL.md and docs/BUILD_STATE.md, then continue from the recorded next action.
Stop at the next approval point.
```
After reviewing a phase:
```
Phase N is approved. Proceed to Phase N+1: orient and plan, then stop.
```

## 4. What to review hardest
ADRs marked Proposed · any change to migrations or to a trigger, constraint or guard · anything claimed as
done without passing tests · new dependencies · anything in `OPEN_DECISIONS.md` the agent tried to decide itself.

## 5. Tips
- One conversation per phase or story; rename the tab after the ID.
- Use Plan mode for new work and Manual mode for SQL and migrations.
- `@docs/capabilities.md`, `@docs/design/...` to point the agent at context; `@terminal:name` to share test output.
- `/compact` on long sessions; the state files mean nothing is lost when you start fresh.
