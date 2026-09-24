# aftersh Roadmap

Status: v0.1 Minimal Receipt — release gate complete. Next feature work is v0.2.

## v0.1 — Minimal Receipt

```text
Validate → Before snapshot → Command → After snapshot → Diff → Receipt → History / Inspect
```

### 0. Repository setup

- [x] Write README.md
- [x] Write docs/ARCHITECTURE.md
- [x] Write docs/ROADMAP.md
- [x] Initialize Swift executable package and test target
- [x] Add Swift Argument Parser
- [x] Add source folders and .gitignore
- [ ] Select a license before public distribution (MIT is a candidate)

Acceptance: `swift run af --help` prints working help.

### 1. Transparent command execution

- [x] Provide primary executable `af` and equivalent `aftersh` executable alias
- [x] Default to `run`; retain explicit `run`, `history`, and `inspect`
- [x] Require `--` before the child command and preserve all following tokens
- [x] Support `-h` / `--help`; bare `af` shows help
- [x] Verify both names, both execution forms, and child-option/subcommand collisions
- [x] Implement RunCommand, ProcessRunner, and RunManager
- [x] Preserve argv, PATH resolution, working directory, and environment
- [x] Inherit stdin/stdout/stderr
- [x] Capture timestamps, duration, exit code, and termination signal
- [x] Return child status; define launch and usage errors
- [x] Handle Ctrl-C and SIGTERM without leaving ordinary children running
- [x] Handle repeat interruption promptly
- [ ] Verify foreground terminal reads and interactive commands (manual / terminal session)
- [x] Route wrapper UI with `-r` / `--receipt-output auto|stderr|none`
- [x] Keep receipt output out of child stdout

Acceptance: wrapped echo, stdin consumption, pipelines, nonzero exits, and interactive interruption behave according to the [execution contract](ARCHITECTURE.md#command-execution-contract). Observation/save errors must not overwrite child exit status.

### 2. Scoped snapshots and coverage

- [x] Require repeatable `-w` / `--watch <path>`; support repeatable `-e` / `--exclude <path>`
- [x] Normalize paths and overlapping roots without following symlinks outside scope
- [x] Automatically exclude aftersh storage and record exclusions
- [x] Capture file type, size, mtime, permissions, and symlink target
- [x] Record before/after scan intervals and successful/absent/unknown regions
- [x] Record scan failures with path, phase, operation, and reason
- [x] Distinguish COMPLETE, PARTIAL, and FAILED coverage

Start with isolated temporary directories. Do not add broad system defaults or hash/content snapshots here.

### 3. Diff and first receipt

- [x] Detect CREATE / MODIFY / DELETE from comparable endpoint observations
- [x] Never turn failed enumeration into inferred creation/deletion
- [x] Show scope, exclusions, failures, and observation status
- [x] Display command outcome independently from observation outcome
- [x] Use qualified empty-result wording; report unusable coverage explicitly
- [x] Document metadata and non-atomic snapshot limitations

Planned demo, using a fresh test directory:

```bash
mkdir -p /tmp/aftersh-test
af -w /tmp/aftersh-test -- touch /tmp/aftersh-test/hello
```

Acceptance: the new file is reported as CREATED, with complete coverage for the selected root. A failed scan yields partial/failed observation rather than an unqualified claim that nothing changed.

### 4. Persistence and retrieval

- [x] Versioned JSON receipt model and unique IDs
- [x] Atomic writes under ~/.local/share/aftersh/receipts/
- [x] Owner-only storage permissions
- [x] Omit argv values, environment, child output, and raw file contents from stored receipts
- [x] Explicit omitted-argument indicator in history/inspect
- [x] `af history`
- [x] `af inspect <id>` and `af inspect last`
- [x] Handle corrupt receipts, unknown schemas, ambiguous IDs, and concurrent runs
- [x] Report save failure separately from command status

Acceptance: inspection after a new CLI invocation reproduces stored observations and coverage. Failed saves never produce a false `Receipt saved` message.

### v0.1 release gate

- [x] All four implementation stages pass their acceptance checks
- [x] Tests cover core diffs and incomplete scans without false CREATE/DELETE
- [x] Tests cover execution streams, status, and signal behavior
- [x] Tests cover persistence failures and reload
- [x] Tested on Apple Silicon macOS; minimum supported macOS/Swift versions documented
- [x] Measure scan overhead on representative scoped directories
- [x] README includes installation/build instructions and a real, reproducible demo
- [x] README clearly states observation, privacy, and detached-process limitations

Notes:

- Automated tests live in `Tests/aftershTests`. ProcessRunner covers echo / nonzero exit / signal exit-code mapping; DiffEngine covers CREATE/MODIFY/DELETE and unknown-subtree non-invention; RunStore covers save/reload, ambiguous prefix, and corrupt/unsupported skip.
- Interactive Ctrl-C / tty ownership remains a manual check (unchecked item under stage 1).
- `swift test` requires Xcode’s Testing macros; Command Line Tools alone may only support `swift build`.
- Scan overhead (Apple Silicon, ~2000-file fixture, ~2040 entries): about **350–360 ms per endpoint metadata scan**; child `/usr/bin/true` about 65 ms. See README.

Not required: FSEvents, content hashes or content snapshots, semantic shell inspection, noise ranking, Launchd, pkgutil, automatic rollback, GUI, perfect attribution, or an Intel support guarantee.

## v0.2 — Useful Receipt

Goal: explain meaningful changes without overwhelming the reader.

- [ ] Implement explicitly selected hashed/content snapshot strategies
- [ ] Capture original hashes/content before command execution
- [ ] Define content size limits and fallback behavior
- [ ] Separate temporary comparison data from persistent receipt models
- [ ] Clean up temporary originals on normal completion and handled failures
- [ ] Persist only sanitized semantic summaries; omit sensitive values
- [ ] Recognize conservative shell patterns, starting with literal PATH changes
- [ ] Add importance ranking and noise filtering
- [ ] Preserve access to underlying metadata observations

Demo: a controlled shell-config fixture changes a literal PATH value from `/old` to `/old:/new`; the receipt explains the addition of `/new`. Unsupported shell expressions remain generic modifications.

Acceptance: representative setup scripts yield readable summaries; selected-file comparison does not leak raw content or secret values into stored receipts.

## v0.3 — macOS Awareness

- [ ] Add FSEvents as supplemental evidence
- [ ] Define watcher readiness, draining, timing gaps, and dropped-event handling
- [ ] Parse LaunchAgent/LaunchDaemon definitions and relevant plist fields
- [ ] Distinguish observed service definitions from verified runtime state
- [ ] Compare macOS package receipts through pkgutil
- [ ] Document new-ID detection versus same-ID package updates
- [ ] Broaden supported scopes gradually, with performance and permission measurements

Acceptance: receipts explain observed service definitions and package receipts without implying proven command attribution. Runtime monitoring gaps remain visible.

## Later, only when justified

- Package ecosystem inspectors such as Homebrew, npm, or Cargo
- Machine-readable exports and receipt comparison
- Advisory cleanup plans; no automatic deletion
- Stronger process-level provenance
- SQLite if real query needs outgrow JSON
- Optional GUI or other operating systems after the CLI proves useful

## Definition of success

The tool succeeds when you regularly wrap unfamiliar setup commands because the resulting receipt is useful. Evaluate speed, relevance, and trustworthiness on real installations within explicit scopes—not just whether the tool can print thousands of changed paths.
