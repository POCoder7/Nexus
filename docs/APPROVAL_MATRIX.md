# Approval matrix: who can do what

Who can raise, approve and commit each kind of change in Nexus, and the rules that stop one person doing it all.
Part A lists the rules Nexus enforces for any set of users. Part B applies them to the demo's users, which come from the
hackathon data set (`data/users.csv`, `data/groups.csv`) and the demo workflows (`db/demo/after-load.sql`).

The rules are enforced in the database (guards and `wf.can_act`); the screens only reflect them. Each section names the
error code you get when a rule refuses an action. Recorded 2026-11-21.

---

## Part A — The rules

### A1. Roles and what they allow

A person gets a role through a group (ADR-042), and the group says which hierarchies the role covers. ADMIN can also be
granted directly to a person.

| Role | Allows | Code |
|---|---|---|
| VIEWER | Browse hierarchies, properties, versions and audit | READ |
| EDITOR | VIEWER, plus draft changes, sandboxes and imports, and submit requests | READ, PROPOSE |
| APPROVER | VIEWER, plus decide submitted requests (never their own) | READ, DECIDE |
| ADMIN | Everything except reading published output: users, groups, rules, workflows, versions, workflow override, publish | all but READ_PUBLISHED |
| CONSUMER | Read published output only (service accounts) | READ_PUBLISHED |

Source: `RolePermissions.java`, table `mdm.role`.

### A2. A change request, step by step

Requests raised from the screens (Add a child, Edit, Move, a submitted sandbox) run through a workflow: **Submit, then
Approve, then Commit**. Committing writes the changes to live data.

| Step | Who can do it | Also needed |
|---|---|---|
| Draft and Submit | An EDITOR (or ADMIN) for **every hierarchy** the request changes | The submit runs every validation rule; errors block it |
| Approve | A member of a group assigned to the Approve stage | Can read **every hierarchy** the request changes; did not submit it |
| Commit | A member of a group assigned to the Commit stage | Can read every hierarchy the request changes; did not submit it **and did not approve it** |
| Reject (at Approve or Commit) | The same people who could approve or commit at that stage | The request ends; nothing reaches live data |
| Withdraw / Discard draft | The requester | Only while it is a draft, or through its workflow once submitted |

### A3. Separation of duties: the four-eyes rules

| Rule | What it stops | Code |
|---|---|---|
| No deciding your own request | The requester approving or committing their own change | N1001 |
| Separation of duties on a stage | One person acting at two stages of the same request (for example approving and then committing) | N1016 |
| Only people decide | A service account or system actor approving | N1002 |
| No override of your own request | An ADMIN overriding a stage of a request they raised or submitted | N1031 |

So every request touches **at least three different people**: the requester, the approver and the committer.

### A4. Workflow override (ADMIN)

An ADMIN can decide an open Approve or Commit stage in place of its groups (ADR-042 D4), for example when no approver is
available. Conditions (`wf.override_stage`, code N1031):

- the ADMIN covers **every hierarchy** of the request;
- it is not their own request;
- they have not decided another stage of the same request (separation of duties still applies);
- a reason of at least 10 characters is given; it is shown on the request's timeline.

### A5. Other governed actions

| Action | Who | Four-eyes rule | Code |
|---|---|---|---|
| Propose an access change (add a person to a group, grant or end a role) | An ADMIN for every hierarchy involved | Nobody proposes access for themselves | N1033, N1034 |
| Decide an access change | A **different** ADMIN for every hierarchy involved; not through a workflow | Not the proposer; an approver is not given access by the request they approve | N1001, N1034 |
| Create a version; Submit (freeze) or Reopen it; Expire it | An ADMIN | — | — |
| Finalize a version | An ADMIN | **Not the ADMIN who submitted it** | N1029 |
| Prepare a data load run | An ADMIN | — | N1035 |
| Approve a data load run's manifest | A **different human** ADMIN | Not the preparer | N1001 |
| Apply an approved load run | The ADMIN who approved it | The load's requests are decided as that approver | — |
| Edit a validation rule; relabel a guard | An ADMIN (a guard keeps its logic: only its name, description and external code change) | — | — |
| See the rule catalogue (with its SQL) | An ADMIN or an APPROVER | — | — |
| See a hierarchy's rules in words (Add a child) | Anyone who can read the hierarchy | — | — |
| Create, change and submit a sandbox | Its owner, an EDITOR (or ADMIN). Others can only view it | A submitted sandbox becomes an ordinary request (A2, A3) | — |

---

## Part B — The demo's users

### B1. Groups

| Group | Role | Hierarchies | Members |
|---|---|---|---|
| ORG_EDITORS | EDITOR | ORGNEXUS, ORGNHYD | u_editor1, u_editor3 |
| AM_EDITORS | EDITOR | ORGSPI | u_editor2, u_editor3 |
| ORG_APPROVERS | APPROVER | ORGNEXUS, ORGNHYD | u_approver1, u_approver3 |
| AM_APPROVERS | APPROVER | ORGSPI | u_approver2, u_approver4 |
| ALL_VIEWERS | VIEWER | ORGNEXUS, ORGNHYD, ORGSPI | u_viewer, u_auditor |
| DOWNSTREAM | CONSUMER | ORGNEXUS, ORGNHYD, ORGSPI | svc_dw_consumer |
| *(direct grant)* | ADMIN | all | u_admin, u_admin2 |

`POLICY_APPROVERS` exists but has no members (no commit policy is active).

### B2. Workflows

Both active workflows have the same three stages. Both approver groups are assigned to Approve and Commit, and
separation of duties is on for both stages.

| Workflow | Used for | Submit | Approve | Commit |
|---|---|---|---|---|
| ADD_LEAF — Add a node | Add a child | The requester | ORG_APPROVERS or AM_APPROVERS | ORG_APPROVERS or AM_APPROVERS |
| MAINTAIN — Maintain nodes and properties | Edit, move, remove, properties, submitted sandboxes | The requester | ORG_APPROVERS or AM_APPROVERS | ORG_APPROVERS or AM_APPROVERS |

One approval from either group completes a stage (`any_group`). In practice only the group that can read the
request's hierarchy can act; see B3.

### B3. The matrix: who can act on a request

Read across: for a request that changes the hierarchy on the left, who can do each step.

| Request changes | Raise and submit | Approve | Commit |
|---|---|---|---|
| ORGNEXUS or ORGNHYD | u_editor1, u_editor3 | u_approver1 or u_approver3 | The **other** of u_approver1 / u_approver3 |
| ORGSPI | u_editor2, u_editor3 | u_approver2 or u_approver4 | The **other** of u_approver2 / u_approver4 |
| ORGSPI **and** an ORG hierarchy in one request | u_editor3 only | **Nobody in the groups** (no approver reads all three) | **Nobody in the groups** |
| Any request, when no approver can act | — | ADMIN override: u_admin or u_admin2 (with a reason; not their own request) | ADMIN override, by the other ADMIN if one ADMIN already overrode the Approve stage |

Each hierarchy has exactly two approvers, so a request is approved by one and committed by the other. If either is
away, the request waits, or an ADMIN overrides the stage.

### B4. The matrix: who can do each action

✓ = can do it. ✓¹ = can, with the condition in the note.

| Action | u_editor1 | u_editor2 | u_editor3 | u_approver1 | u_approver3 | u_approver2 | u_approver4 | u_admin | u_admin2 | u_viewer, u_auditor |
|---|---|---|---|---|---|---|---|---|---|---|
| Read ORGNEXUS / ORGNHYD | ✓ | | ✓ | ✓ | ✓ | | | ✓ | ✓ | ✓ |
| Read ORGSPI | | ✓ | ✓ | | | ✓ | ✓ | ✓ | ✓ | ✓ |
| Raise a request / sandbox (ORG) | ✓ | | ✓ | | | | | ✓ | ✓ | |
| Raise a request / sandbox (ORGSPI) | | ✓ | ✓ | | | | | ✓ | ✓ | |
| Approve or commit (ORG) | | | | ✓¹ | ✓¹ | | | | | |
| Approve or commit (ORGSPI) | | | | | | ✓¹ | ✓¹ | | | |
| Override a stage | | | | | | | | ✓¹ | ✓¹ | |
| See the rule catalogue | | | | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | |
| Edit validation rules | | | | | | | | ✓ | ✓ | |
| Submit / Reopen / Expire a version | | | | | | | | ✓ | ✓ | |
| Finalize a version | | | | | | | | ✓¹ | ✓¹ | |
| Propose / decide access changes | | | | | | | | ✓¹ | ✓¹ | |
| Prepare / approve a data load | | | | | | | | ✓¹ | ✓¹ | |

¹ Conditions:
- **Approve or commit:** not their own request, and not if they already approved or committed it at the other stage.
- **Override:** not their own request, and not if they decided another stage of it; a reason is required.
- **Finalize:** not the ADMIN who submitted the version, so one of u_admin / u_admin2 submits and the other finalizes.
- **Access changes:** one ADMIN proposes and the other decides; neither can change their own access.
- **Data load:** one ADMIN prepares and the other approves and applies.

`svc_dw_consumer` reads published output only and takes part in none of these.

---

## Known gaps

| Gap | Effect | Suggested fix |
|---|---|---|
| Approve and Commit are assigned to **both** approver groups, with no hierarchy limit on the stage | A request shows in the worklist of approvers who cannot open it (for example an ORGNHYD request for u_approver2). They cannot act on it: the API answers 404 because they cannot read its hierarchy | In the demo workflows, limit each group's stage to its own hierarchies (stage access scope), as `groups.csv` intends |
| A request that changes both an ORG hierarchy and ORGSPI | No approver can read all its hierarchies, so only an ADMIN override can move it | Keep requests to one hierarchy family, or add a group that approves across both |
| Two approvers and two ADMINs per area | Each step that needs a second person stops when one of the two is away | Add a third approver per hierarchy and a third ADMIN, or rely on override |

## Sources

- Roles: `services/mdm-api/src/main/java/com/mdm/api/security/RolePermissions.java`
- Stage decisions: `wf.can_act`, `wf.sod_violation` (V4, V9), `StageService.java`
- Override: `wf.override_stage` (V15); access changes: V14; versions: `mdm.transition_version` and its trigger (V11);
  load runs: V20
- Demo users and groups: `data/users.csv`, `data/groups.csv`; demo workflows: `db/demo/after-load.sql`
- Decisions: ADR-042 (groups, override), ADR-037 (versions), ADR-046 (data load)
