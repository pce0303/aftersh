# aftersh Roadmap

Status: Design / Pre-implementation. Only documentation exists today; unchecked items are planned. The first release is deliberately limited to command execution, scoped metadata comparison, and trustworthy saved receipts.

## v0.1 — Minimal Receipt

```text
Validate → Before snapshot → Command → After snapshot → Diff → Receipt → History / Inspect
```

### 0. Repository setup

- [x] Write README.md
- [x] Write docs/ARCHITECTURE.md
- [x] Write docs/ROADMAP.md
- [ ] Initialize Swift executable package and test target
- [ ] Add Swift Argument Parser
- [ ] Add source folders and .gitignore
- [ ] Select a license before public distribution (MIT is a candidate)

Acceptance: `swift run aftersh --help` prints working help.

### 1. Transparent command execution

- [ ] Implement RunCommand, ProcessRunner, and RunManager
- [ ] Preserve argv, PATH resolution, working directory, and environment
- [ ] Inherit stdin/stdout/stderr
- [ ] Capture timestamps, duration, exit code, and termination signal
- [ ] Return child status; define launch and usage errors
- [ ] Handle Ctrl-C and SIGTERM without leaving ordinary children running
- [ ] Handle repeat interruption promptly
- [ ] Verify foreground terminal reads and interactive commands
- [ ] Route wrapper UI with `--receipt-output auto|stderr|none`
- [ ] Keep receipt output out of child stdout

Acceptance: wrapped echo, stdin consumption, pipelines, nonzero exits, and interactive interruption behave according to the [execution contract](ARCHITECTURE.md#command-execution-contract). Observation/save errors must not overwrite child exit status.

### 2. Scoped snapshots and coverage

- [ ] Require repeatable `--watch <path>`; support repeatable `--exclude <path>`
- [ ] Normalize paths and overlapping roots without following symlinks outside scope
- [ ] Automatically exclude aftersh storage and record exclusions
- [ ] Capture file type, size, mtime, permissions, and symlink target
- [ ] Record before/after scan intervals and successful/absent/unknown regions
- [ ] Record scan failures with path, phase, operation, and reason
- [ ] Distinguish COMPLETE, PARTIAL, and FAILED coverage

Start with isolated temporary directories. Do not add broad system defaults or hash/content snapshots here.

### 3. Diff and first receipt

- [ ] Detect CREATE / MODIFY / DELETE from comparable endpoint observations
- [ ] Never turn failed enumeration into inferred creation/deletion
- [ ] Show scope, exclusions, failures, and observation status
- [ ] Display command outcome independently from observation outcome
- [ ] Use qualified empty-result wording; report unusable coverage explicitly
- [ ] Document metadata and non-atomic snapshot limitations

Planned demo, using a fresh test directory:

```bash
mkdir -p /tmp/aftersh-test
aftersh run --watch /tmp/aftersh-test -- touch /tmp/aftersh-test/hello
```

Acceptance: the new file is reported as CREATED, with complete coverage for the selected root. A failed scan yields partial/failed observation rather than an unqualified claim that nothing changed.

### 4. Persistence and retrieval

- [ ] Versioned JSON receipt model and unique IDs
- [ ] Atomic writes under ~/.local/share/aftersh/receipts/
- [ ] Owner-only storage permissions
- [ ] Omit argv values, environment, child output, and raw file contents from stored receipts
- [ ] Explicit omitted-argument indicator in history/inspect
- [ ] `aftersh history`
- [ ] `aftersh inspect <id>` and `aftersh inspect last`
- [ ] Handle corrupt receipts, unknown schemas, ambiguous IDs, and concurrent runs
- [ ] Report save failure separately from command status

Acceptance: inspection after a new CLI invocation reproduces stored observations and coverage. Failed saves never produce a false `Receipt saved` message.

### v0.1 release gate

- [ ] All four implementation stages pass their acceptance checks
- [ ] Tests cover core diffs and incomplete scans without false CREATE/DELETE
- [ ] Tests cover execution streams, status, and signal behavior
- [ ] Tests cover persistence failures and reload
- [ ] Tested on Apple Silicon macOS; minimum supported macOS/Swift versions documented
- [ ] Measure scan overhead on representative scoped directories
- [ ] README includes installation/build instructions and a real, reproducible demo
- [ ] README clearly states observation, privacy, and detached-process limitations

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

## First coding session

1. Initialize the executable package and Argument Parser.
2. Implement argument/stream forwarding and child status.
3. Verify stdin, pipelines, and interruption.
4. Commit the execution skeleton.
5. Add a scoped metadata snapshot and coverage model.
6. Build the first receipt, then persistence and inspection.

Keep commits small and independently understandable. Do not let later inspectors delay the minimal release.

## Definition of success

The tool succeeds when you regularly wrap unfamiliar setup commands because the resulting receipt is useful. Evaluate speed, relevance, and trustworthiness on real installations within explicit scopes—not just whether the tool can print thousands of changed paths.
