# ADR-033: Authentication — API as OIDC resource server; identities mapped, roles kept in Nexus

- **Status:** Proposed (Phase 9 LLD). The identity provider and its Angular library (OD-06) are **not** decided here
- **Date:** 2026-11-11
- **Deciders:** <names / roles>
- **Capabilities:** SEC-05 (pending decision), SEC-01, SEC-02

## Context
Since Phase 1 the API resolves identity through `CurrentActor` and refuses to start outside `local`/`test` without a real
adapter. Roles and scopes are Nexus data, governed by maker-checker (ADR-022, ADR-029). The organisation's identity provider is not chosen.

## Options
| | A: OIDC resource server in the API | B: SAML 2 in the API | C: Gateway authenticates, API trusts headers |
|---|---|---|---|
| UI | Authorization Code + PKCE through the organisation's library | SAML redirect flow, session cookie | Gateway login |
| API | Validates JWTs itself (JWKS, issuer, audience) | Spring SAML 2 service provider, server sessions | Reads identity headers |
| Integrations | Client credentials | Separate mechanism needed | Gateway-specific |
| Risk | Standard, stateless | Stateful sessions, CSRF to manage | A misrouted request bypasses identity |
**Recommendation:** A. If the provider supports only SAML, put an OIDC bridge in front (the provider's or the platform's) and keep A in the API.

## Decision (proposed, with option A)
- `OidcActor` maps `(issuer, subject)` to `mdm.app_user` through `mdm.app_user_identity`; linking is a governed request; unknown subjects get 403, no auto-provisioning.
- Token claims never grant roles; IdP groups may only propose grants (ADR-029).
- Integrations use client credentials and system-feed users with read-only roles.

## Consequences
- New dependency: `spring-boot-starter-oauth2-resource-server` (Boot-managed), approved in the Phase 9 plan.
- The first shared environment can be created once this is implemented with the chosen provider.
