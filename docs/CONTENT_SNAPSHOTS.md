# Content snapshots (v0.2 first slice)

Status: Implemented for explicitly selected files only.

## Selection

- Repeatable `--content <path>` selects files for bounded text capture.
- Paths must resolve under a `--watch` root. There is no blanket config-directory scan.

## Limits

- Maximum captured size: **64 KiB** (`ContentCapture.maxBytes`).
- Oversized, unreadable, or non-UTF-8 / invalid-text files fall back to metadata comparison; a limitation is recorded on the run (not as raw content).

## Lifecycle

1. Capture **before** text (if possible) prior to launching the child.
2. Run the command.
3. Capture **after** text for the same selections.
4. Derive sanitized semantic summaries (starting with literal `PATH` / `export PATH`).
5. Drop temporary before/after text from memory. Do not write raw contents or raw textual diffs into receipts.

## Semantics

- Shell is **not** executed to interpret files.
- Only conservative literal assignments are recognized (`PATH=...`, `export PATH=...`).
- Unsupported expressions remain ordinary `MODIFIED` metadata observations.
- Persisted receipts store `semanticSummaries[]` messages only (e.g. `PATH entry added: /new`), never file bodies.
