# ADR-045: Build cross-hierarchy search (5-14) before the formula increments, and let it find hierarchies and requests

- **Status:** Accepted (repository owner, 2026-11-20: asked for the search to find hierarchies too, then "1 - both
  2. yes" to hierarchies and requests, and to building 5-14 next)
- **Date:** 2026-11-20
- **Deciders:** Repository owner
- **Capabilities:** QRY-03 (decided by ADR-038; designed in Phase 5 LLD §17.6, approved 2026-11-14)
- **Amends:** the Phase 5 order (LLD §17.14) and the scope of §17.6

## Context
§17.6 designs a node search across hierarchies, built as 5-14 after the formula increments 5-10 and 5-11. The header search
box (LLD §21.1) searches one hierarchy until then. The owner asked for the search box to find hierarchies as well, and
agreed to requests too.

Search does not depend on 5-10 or 5-11: it matches names, descriptions and identifiers, never derived values.

## Decision
1. **Order.** Build 5-14 now; 5-5 and the formula increments follow as before.
2. **Scope.** The search returns three groups: hierarchies (code, name, purpose), nodes (as §17.6) and requests (title),
   each limited to what the user can see. A request id still opens the request directly.
3. **Read scope.** Hierarchy-level until 5-5, as every read (ADR-041, ADR-043, ADR-044); 5-5 adds `/search`.

## Alternatives considered
- **Nodes only, as designed.** Hierarchies and requests are what users type most after node names; leaving them out
  sends people to two other pages.

## Consequences
- §17.6 gains §17.6.1 (hierarchies and requests); a trigram index on request titles is added.
- The Phase 5 gate is unchanged.
