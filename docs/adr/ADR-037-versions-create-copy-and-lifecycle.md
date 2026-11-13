# ADR-037: Versions: create, copy and status lifecycle (VER-01, VER-02)

- **Status:** Accepted (repository owner, 2026-11-12: every recommendation, D1 to D5); D4 Audit-Risk confirmation pending (OD-45a). Refinements R1 to R4 from the detailed design were approved by the owner with the Phase 3 LLD section "Third scope extension: versions" on 2026-11-12 ("Build it as designed") and built in Phase 3 increments 3-23 to 3-27
- **Date:** 2026-11-12
- **Deciders:** Repository owner (D1, D2, D3, D5); repository owner, then Audit-Risk confirmation (D4)
- **Capabilities:** VER-01, VER-02 (VER-03 to VER-07 are placed, not built)

## Context
The repository owner asked to implement versioning ("lets implement the versioning"). Today:

- `mdm.version` exists (V1): name (unique), `status` (`working`, `submitted`, `finalized`, `expired`), `base_version_id`,
  `business_as_of`, `recorded_as_of` (NULL while working), `finalized_at`, `finalized_by`, and one CHECK: a finalized
  version has a `recorded_as_of`. The table is audited (`audit_log`). Nothing else guards it.
- Every change request names a version (`change_request.version_id`; the API takes `versionName`). A draft may change its
  version; a submitted request may not (`N2102`). Nothing checks the version's status.
- There is no API to list, create or change versions. `/me.workingVersion` is the latest `working` version, and the UI shows
  it in the context bar as text. The demo and test seed create one version, `E2E working`.
- Reads take any business date and recorded time (`asOf`, `recordedAsOf`, Phase 1), so a version's picture can already be
  read (VER-03). Export runs record the version they ran against (V3).
- The VER capabilities are "—" in the catalogue: a Product decision under OD-09 (Parity · Improve · Retire). The Phase 5
  LLD §15.1 holds only an outline. Building them now changes scope, which the build protocol leaves to the owner (§4).

**The difference from DRM that drives every option.** In DRM a version is a separate copy of the data: copy last period's
version, edit the copy, and the original never changes. Nexus keeps **one bitemporal store**. Every committed change is
recorded once, with the business date it takes effect (`valid_period`) and the time it was recorded (`recorded_period`).
A version is a named point in that store: a business date plus, once frozen, a recorded time. Two consequences:

1. Editing next period cannot change last period's finalized picture: the edit is effective at a later business date, and
   the finalized version is pinned to a recorded time before the edit. Corrections recorded later stay out of it too.
2. Two **working** versions are not isolated. A committed change effective from 1 December shows in every version whose
   business date is on or after 1 December and whose picture is not pinned, whichever version the request named.
   Isolated "what-if" editing is the sandbox feature (NEW-08, ADR-028; scenarios BLD-03, OD-12), not a version.

## Decisions to take

### D1: Capability decisions (OD-09) for the VER rows

| ID | Recommendation | Why |
|---|---|---|
| VER-01 Create and copy | **Improve**, build now (with D5) | Same outcome for users (a new period starts from the base's data) without copying rows |
| VER-02 Lifecycle | **Parity**, build now (with D5) | The four statuses and read-only finalized versions are what downstream users rely on |
| VER-03 As-of versions | **Parity**; reads built in Phase 1, exports in Phase 8 | No rebuild needed |
| VER-04 Baseline versions | **Parity**, Phase 5 | Needs the compare service (QRY-02) |
| VER-05 Version variables | **Parity**, Phase 8 | Aliases matter to exports and jobs, which arrive in Phase 8 |
| VER-06 Load, unload, backup | **Retire as a feature** | Database backup and point-in-time recovery (OD-15) |
| VER-07 Version properties | Confirm use in discovery, then Phase 5 | Unknown whether anyone uses them |

### D2: What a version is

| Option | What it means | Cost and risk |
|---|---|---|
| **A. Named slice (recommended)** | A version row is a business date and, once frozen, a recorded time over the one store. "Copy" records the base (`base_version_id`); the new version shows its base's data at creation when it has the same business date, and the base's data rolled forward to its own date otherwise | No data copied; works at any size; matches the catalogue's target design and the Phase 5 outline. Risk: users expect two working versions to be isolated (see Context 2), so training and the version page must say so |
| B. Physical copy | Every fact table gains a `version_id`; creating a version copies every row | Rewrites the data model, every read, every guard, apply, validation, exports and all pgTAP and JUnit tests; storage grows with each version; contradicts P-02 and the rejected physical-copy sandbox (Phase 5 LLD Alt-1) |
| C. Slice, plus a private sandbox per working version | As A, and edits in a working version go to a sandbox overlay until the version is submitted | Gives DRM-like isolation, but needs NEW-08 sandboxes (Phase 5) first and merges many requests at submit; larger than both D5 options below |

### D3: Lifecycle, and when a version's picture freezes

Transitions in every option: `working → submitted`, `submitted → working` (reopen), `submitted → finalized`,
`finalized → expired`. Nothing else; `expired` is final. No version is deleted (the request foreign key already prevents
it for any version that has requests; the guard would refuse it for the rest, and an unwanted version is expired instead).

| Option | Freeze point | Effect |
|---|---|---|
| **A. Freeze at submit (recommended)** | Submit sets `recorded_as_of` to the submit time; reopen clears it; finalize keeps it and sets `finalized_at` and `finalized_by` | Reviewers of a submitted version see a picture that cannot move while other versions keep committing. A correction during review means reopen, fix, submit again (a new freeze time) |
| B. Freeze at finalize (Phase 5 outline) | Only finalize sets `recorded_as_of` | Simpler, but a submitted version's picture keeps moving under the reviewers until it is finalized, so what was reviewed may not be what is finalized |

In both options, the database (not the API) refuses:
- a status change outside the four transitions above, and any change to a finalized or expired version except `finalized → expired`;
- a change to `business_as_of` or `base_version_id` after the version leaves `working`; a name change after finalize;
- a request created in, moved to, submitted in or applied in a version that is not `working` (the apply check catches a
  request approved before its version was submitted);
- submitting a version while any request in it is still open (draft, submitted, in a workflow, or approved and not yet
  applied). The message gives the count by status. A draft can be moved to another working version (drafts may already change version).

The existing V1 CHECK stays. A new, stricter CHECK in a new migration (`V11`; V1 to V10 are not edited) adds:
`working` has no `recorded_as_of`; `submitted`, `finalized` and `expired` have one. Every transition is also written to an
append-only `mdm.version_transition` table (who, when, from, to, reason) next to the existing `audit_log` rows.

### D4: Who may create, submit and finalize (a control: Audit-Risk to confirm)

| Option | Who | Notes |
|---|---|---|
| **A. New role `VERSION_ADMIN`; finalize by a second person (recommended)** | `VERSION_ADMIN` creates, copies, renames, submits, reopens and expires. Finalize needs a `VERSION_ADMIN` other than the person who submitted it. People only, never an AI agent | Same pattern as workflow-model activation by a second administrator (`N1014`). The role-to-permission matrix stays in code (ADR-022); the four-eyes rule and "people only" are database guards |
| B. `SYSTEM_ADMIN` does everything | One existing role, no four eyes | Mixes user administration with closing a reporting period (a separation-of-duties concern) |
| C. Transitions as governed change requests | A request with a new item type `set_version_status` goes through a workflow model (approve, commit) | Strongest control and reuses the worklist, but needs a new action, bridge path, workflow model and policy coverage; roughly twice the build of A |

### D5: Where and how much to build now

| Option | Scope | Notes |
|---|---|---|
| **A. VER-01 and VER-02 as a third Phase 3 scope extension (recommended)** | V11 migration and guards; API: list (paged), get, create or copy, rename while working, transition; `/me.workingVersion` becomes the user's chosen working version (a preference) with the latest working version as the fallback; UI: a Versions page (list by status, create, copy from, transitions with the reason a transition is refused, from `whyNot` as elsewhere), a version picker in the context bar, and opening a non-working version shows its frozen picture read-only, like the historical view. A warning on Review when a request's effective date is after its version's business date (the change would not show in that version) | Follows the Phase 3 pattern for the earlier extensions: the LLD gains a section, the plan gains increments, then build and test. Golden parity (version list and node counts against DRM) waits for Phase 4 and masked extracts (OD-31, OD-32) |
| B. Keep it in Phase 5 | As designed | Nothing built now; you cannot create a version in the demo until Phase 5 |
| C. All of VER-01 to VER-07 now | Adds baseline compare, aliases and version properties | VER-04 needs QRY-02 compare, VER-05 belongs with exports (Phase 8), VER-07 needs discovery first; not recommended |

## Decision
The repository owner chose every recommendation on 2026-11-12: **D1** as tabled, **D2 A** (named slice), **D3 A** (freeze at
submit), **D4 A** (`VERSION_ADMIN`, finalize by a second person, people only), **D5 A** (VER-01 and VER-02 as a third Phase 3
scope extension). The detailed design (Phase 3 LLD, "Third scope extension: versions") is written before any code and stops for
the owner's approval.

### Refinements found in the detailed design (for the owner's approval with the LLD section)
- **R1. Drafts do not block a version submit.** D3 above said every open request blocks it, drafts included. A draft belongs
  to its requester and nobody else may change or withdraw it, so one abandoned draft could stop a period close. Requests that
  are submitted, in review or approved still block the submit. A draft left in a submitted version cannot be submitted (the
  database refuses it); its requester moves it to a working version or withdraws it. Moving needs the API role to update
  `change_request.version_id` (a new column privilege, ADR-014). The existing draft-only trigger (`N2102`) still limits it to drafts.
- **R2. A frozen picture never gains rows afterwards.** A recorded time is a transaction's start time. So an apply that began
  before a freeze and commits after it would show in the frozen picture. The freeze takes an exclusive lock and pins
  `clock_timestamp()` under it; an apply that finds a pin later than its own start is refused with `40001`, which
  `ApplyService` already retries in a new transaction.
- **R3. What a working version shows.** A version's picture is (business date, recorded time, or now while working), which is
  what exports already use (V3). The steward workspace stays the live, editable view (today, as now). "Open picture" on the
  Versions page shows any version's picture read-only.
- **R4. One guard for "the request's version is working".** A trigger on `change_request` checks the request when it is
  created, moved, submitted, put into review, approved or applied. This covers the core and the workflow paths with one rule
  and leaves `apply_change_request` (V1) unchanged, in place of the separate check inside apply named in D3.

## Consequences (if the recommendations are adopted)
- The Phase 3 LLD gains a section "Third scope extension: versions" and the Phase 3 plan gains increments 3-23 onward, before
  any code (CLAUDE.md: a plan follows its LLD). The Phase 5 LLD §15.1 VER-01 and VER-02 rows point to it.
- New: `V11__versions.sql` (guards, the stricter CHECK, `mdm.version_transition`, the request and apply checks, security-definer
  transition function), one pgTAP file, JUnit API tests, unit tests and one end-to-end journey. New error codes in the `N2xxx`
  range, listed in `CONSISTENCY_REVIEW.md`.
- Known limitation (D-08): definitions (`hierarchy`, `property_definition`, `node`) are updated in place, so a finalized
  version is read with today's definitions. A renamed property or a changed inheritance rule changes how an old picture reads.
  Values and structure stay frozen. Definition history is not in this scope; it is a risk for VER-03 and export parity.
- Context point 2 (working versions are not isolated) is a behaviour change from DRM that users and the parity tests must know.
  Golden tests on version contents must compare at the version's (business date, recorded time).
- Version transitions touch a period-close control, so the Audit-Risk review (OD-18a) covers this ADR before it is merged to `main`.
