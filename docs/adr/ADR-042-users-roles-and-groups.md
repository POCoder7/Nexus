# ADR-042: Users, roles and groups

- **Status:** Accepted by the repository owner (2026-11-17), with every recommended choice C-1 to C-5 of Phase 5 LLD
  §19.10 (approved the same day). The workflow override (D4) needs Audit-Risk confirmation (OD-49a) before it merges
  to `main`.
- **Date:** 2026-11-17
- **Deciders:** Repository owner; Audit-Risk (D4)
- **Capabilities:** SEC-01, SEC-02, SEC-03, GOV-01, GOV-06, PROG
- **Amends:** ADR-022 (roles and grants), ADR-029 (governed grants), the Phase 2 workflow groups (`wf.user_group`,
  governed membership changes in V9). Replaces Phase 5 increment 5-4.

## Context
Today a user gets access through grants made to them directly (`mdm.user_role`: role + all hierarchies, one hierarchy or
a sub-tree, optionally limited to property categories). There are seven roles (`VIEWER`, `STEWARD`, `APPROVER`,
`WORKFLOW_ADMIN`, `POLICY_ADMIN`, `SYSTEM_ADMIN`, `VERSION_ADMIN`). Groups exist only in the workflow layer
(`wf.user_group`): they say who decides each workflow stage and who approves commit policies.

On 2026-11-17 the repository owner asked for a users, roles and groups model in which:
- users belong to groups, and a group gives its members one role over a set of hierarchies (for example
  `ORG_EDITORS` = EDITOR on `ORGTL` and `ORGTP`);
- there are five roles: VIEWER, EDITOR, APPROVER, ADMIN and CONSUMER;
- ADMIN does everything, including overriding a workflow with a reason, and publishing;
- CONSUMER, for a downstream service account, reads published output only.

The owner then decided:
1. the ADMIN override of a workflow is allowed;
2. CONSUMER and service identities are added now, and read nothing until Phase 8 publishes output;
3. groups are generic: one group concept for access and for workflow approval;
4. groups keep the optional sub-tree and property-category limits;
5. this is built for Nexus generally, and `ORGTL`, `ORGTP` and `AMBUS` are invented names.

## Decision
- **D1. Five roles.** `VIEWER`, `EDITOR` (today's `STEWARD`, renamed), `APPROVER`, `ADMIN` and `CONSUMER`. What each
  may do stays fixed in code (ADR-022). ADMIN holds every permission, including two new ones:
  - `OVERRIDE_WORKFLOW`;
  - `PUBLISH` (used from Phase 8).

  CONSUMER holds only `READ_PUBLISHED`. The four administration roles fold into ADMIN (choice C-1).
- **D2. Generic groups in `mdm`.** One group concept serves access and workflow:
  - `mdm.user_group` replaces `wf.user_group`;
  - a group may carry a role, which applies over the group's **scopes**: all hierarchies, a hierarchy, or a sub-tree,
    each optionally limited to property categories;
  - membership and scopes keep their history (bitemporal), so who could do what on any past date can be rebuilt;
  - workflow stages and commit policies name these groups. A group with no role (for example `POLICY_APPROVERS`) is a
    pure workflow group.

  The groups live in `mdm` because entitlements need them and `mdm` may never reference `wf`. The workflow layer reads
  them, which the layer rule allows. A user's effective grants are their direct grants plus their groups' scopes;
  direct grants stay for exceptions (choice C-2).
- **D3. Governed changes.** Groups, scopes, memberships and direct grants change only through change requests, with
  new actions applied by the apply function:
  - one ADMIN proposes and a different ADMIN decides (maker-checker);
  - a change to `POLICY_APPROVERS` still needs a decider who is in it;
  - every one of these actions is on the commit-policy hard-limit list.

  This replaces ADR-029's `grant_role` and `revoke_role` and the Phase 2 membership changes (`wf.membership_change`)
  with one path (choice C-4).
- **D4. Workflow override.** An ADMIN for the request's hierarchies may decide a pending workflow stage in place of
  its groups: approve, reject or push back. A reason is required, and the override is recorded as its own action and
  shown on the request.
  - The override passes over group membership, claims and group order.
  - It keeps the guards on who may decide: never one's own request (maker-checker), people only, and separation of
    duties across stages (choice C-3).
  - Audit-Risk confirms this before it merges to `main` (OD-49a).
- **D5. Service identities and CONSUMER.** `app_user.kind` gains `service`.
  - A service account may hold only CONSUMER.
  - It can never raise, decide or apply a change.
  - People may not hold CONSUMER.
  - Until Phase 9 a service signs in locally through the development identity, as people do; Phase 9 gives it a real
    credential (ADR-033).

## Alternatives considered
- **Keep groups in `wf` and add access groups in `mdm`.** Two group concepts with overlapping members. The owner asked
  for one generic concept.
- **Groups only, no direct grants.** Simpler to explain, but a one-off exception would need a one-member group (C-2).
- **Keep the four administration roles beside ADMIN.** Finer separation; the owner's model has one ADMIN (C-1).
- **Override without separation of duties.** Faster in an emergency, but an admin could approve the same request at
  two stages. Rejected in favour of C-3.

## Consequences
- Every check of "who may do what" reads effective grants, so the read filtering of 5-5 covers group scopes from its
  first commit.
- Migrations V1, V4, V6, V7, V8, V9 and V11 are edited (still allowed, OD-44). Tests that name `STEWARD`, the
  administration roles or `wf.user_group` change with them; these are renames, not weakened assertions.
- `docs/data-model.md`, the Phase 2 and Phase 5 LLDs, `CONSISTENCY_REVIEW.md` and `TRACEABILITY.md` are updated with
  the build.
- Local databases are recreated once more (DEVELOPER_SETUP explains how).
