# Legacy metadata analysis (internal use only)

Scripts here run **inside the organisation's network** against legacy metadata exports and transaction logs.
They must output **aggregate counts only** (object counts, usage in the last 12 months, unused definitions,
formula complexity) — never names, values, formulas or personal data.

Planned:
- `strip_structure` — reduces a metadata export to element/attribute names only, for format discovery.
- `inventory` — produces the counts for the Inventory sheet of the capability matrix.

Do not commit any input or output files; `.gitignore` excludes common data paths.
