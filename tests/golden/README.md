# Golden (parity) tests

Each test compares Nexus output with output captured from the legacy system for the same input:
hierarchy exports, inherited and derived property values, validation results.

Rules:
- Captured outputs are produced inside the organisation's network and **masked** (names, codes, identifiers
  replaced consistently) before they are used here.
- Never commit unmasked data.
- Tag each test with its capability ID so pass rates roll up in the tracker.
