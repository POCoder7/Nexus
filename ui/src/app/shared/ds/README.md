# Design-system adapters (LLD §3.4)

Thin wrappers between Nexus feature code and the organisation's design system. Until its Angular packages arrive (OD-02 to
OD-04), each adapter renders plain, accessible HTML styled only with Nexus tokens (`src/styles/tokens.css`). When they do,
each adapter's template switches to the design-system component and feature code does not change.

| Adapter | Selector | Becomes |
|---|---|---|
| Button | `ds-button` | design-system button |
| Badge | `ds-badge` | status badge / tag |
| Header | `ds-header` | application shell header (the brand slot comes from the design system; no brand assets here) |
| Tabs | `ds-tabs` | tabs |
| Date input | `ds-date-input` | date picker |
| Field | `ds-field` | form field (label, hint, error) around a native control |
| Dialog | `DsDialog`, `ds-dialog-frame` | modal dialog |
| Toast | `DsToast`, `ds-toast-host` | toast (confirmations only, UI_STANDARD §6) |
| Table | `table[dsTable]` | data table styles |
