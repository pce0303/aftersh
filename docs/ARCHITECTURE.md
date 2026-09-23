# aftersh Architecture

Status: Design / Pre-implementation. This document defines intended contracts, not implemented capabilities. See [ROADMAP.md](ROADMAP.md) for release boundaries.

## Product principles

The human-readable receipt is the product. Collect data only when it makes the receipt more useful.

- Observation is not causation. Snapshot differences cannot identify the writer.
- Incomplete observation must remain visible in stored data and rendered output.
- Command failure, observation failure, and persistence failure are independent outcomes.
- A small, trustworthy scope is preferable to an unexplained whole-system scan.

## v0.1 execution flow

```text
CLI → RunManager
        1. Validate arguments, command, and observation scope
        2. Capture before snapshot and scan coverage
        3. Execute child with inherited streams
        4. Wait for termination and record status
        5. Capture after snapshot and scan coverage
        6. Diff comparable observations
        7. Construct and atomically save receipt
        8. Render summary outside child stdout
        9. Return child status
```

Scan errors do not prevent an otherwise valid command from running. Invalid CLI options or an invalid scope specification fail before execution. The scan window includes snapshot traversal; it is not identical to the child's execution window. Store both snapshot intervals and command timestamps.

v0.1 has no runtime watcher or inspectors. Classification and selected content comparison arrive in v0.2; FSEvents and macOS inspectors arrive in v0.3.

## Components

| Component | Responsibility |
| --- | --- |
| CLI | Parse options, call services, choose output destination |
| RunManager | Coordinate a run and its independent outcomes |
| ProcessRunner | Execute argv, preserve streams, handle signals and termination |
| Snapshotter | Capture selected metadata and explicit coverage |
| DiffEngine | Compare known states without inventing changes from scan errors |
| ReceiptRenderer | Summarize changes and observation limits |
| RunStore | Atomically persist versioned receipts and read history |

Use one Swift package with modular folders. Foundation.Process is the initial execution candidate; verify its behavior against the execution contract before relying on it. Add lower-level process control where tests require it.

## Command execution contract

- Preserve argv boundaries. Never silently wrap a command in `sh -c`.
- Resolve executable names through the inherited PATH; preserve explicit executable paths.
- Inherit the working directory and environment without persisting environment values.
- Inherit stdin/stdout/stderr descriptors. Do not capture, rewrite, or buffer child output for receipts.
- Never write wrapper UI or diagnostics to child stdout.
- `--receipt-output auto` uses `/dev/tty` if it can be opened, otherwise stderr. `stderr` and `none` are explicit alternatives. `none` suppresses the summary; wrapper errors still go to stderr.
- Render the summary after child termination. Automatic fallback to stderr may mix wrapper text with redirected child stderr; `none` suppresses receipt text in that case.
- `history` and `inspect` use stdout for their explicitly requested output.

### Exit and signal handling

For normal child termination, `run` returns the child's exit code. For signal termination, return `128 + signalNumber` and store the signal separately. Before child launch, use exit 2 for invalid CLI usage, 127 for a missing executable, and 126 for an executable that cannot be launched.

Scan, rendering, or save failures after launch must not replace the child's termination status. Report them through the wrapper diagnostic channel; do not claim a receipt was saved when persistence failed.

Handle SIGINT and SIGTERM so the wrapper can wait for the child and attempt a final snapshot and receipt. The process-group design must cover ordinary descendants without signaling unrelated processes or delivering a terminal-generated signal twice. Verify terminal foreground ownership and interactive reads, not just output forwarding.

On a second interrupt, abandon final observation promptly and terminate/reap the managed command group as appropriate. If a receipt can be saved, mark it interrupted with incomplete coverage. SIGKILL or abrupt host termination cannot guarantee cleanup or a final receipt.

Full shell job control and tracking intentionally detached background processes are outside v0.1. The observation window ends with the direct child; later background writes are outside the contract. These limits do not excuse leaving ordinary foreground children running after Ctrl-C.

## Scope and path rules

v0.1 requires one or more `--watch <path>` options. There is no default broad scan. `--exclude <path>` is repeatable and applies to that path and descendants.

Normalize relative paths against the launch working directory; deduplicate overlapping roots. Resolve existing ancestor aliases consistently (including `/tmp` versus `/private/tmp`) while preserving user-facing paths. Do not follow leaf symlinks recursively: record their type and target. Avoid traversing outside the selected scope through symlinks.

A missing watch root is a valid absent state only when its absence can be established from a readable parent. Permission errors or ambiguous lookup failures are unknown states, not absence.

Always exclude aftersh's own receipt and temporary snapshot storage from watched trees, and include these automatic exclusions in coverage. This avoids self-generated observations during overlapping runs.

## Coverage and uncertainty

Proposed model:

```text
ObservationScope
  watchedPaths[]
  excludedPaths[]           # path and reason, including automatic exclusions
  beforeCoverage
  afterCoverage
  failures[]
  status                   # complete | partial | failed

ScanFailure
  path
  phase                    # before | after
  operation
  reason                   # readable message and stable error code

SnapshotCoverage
  startedAt
  endedAt
  successfullyScannedPaths[]
  knownAbsentPaths[]
  unknownSubtrees[]
```

The implementation may compact coverage records, but must preserve which regions are comparable. Failure records alone are insufficient if they cannot distinguish successful enumeration from unobserved descendants.

- `COMPLETE`: all non-excluded selected paths have comparable endpoint observations.
- `PARTIAL`: some comparable coverage exists, but some observations are unknown or interrupted.
- `FAILED`: no comparable coverage exists.

An inaccessible directory makes its unobserved descendants unknown. Do not emit DELETE for entries merely missing from a failed after scan, or CREATE for entries missing from a failed before scan. Emit changes only where both endpoint states (including verified absence) are known.

With usable coverage and no changes, render `No changes detected in successfully observed paths.` With failed coverage, render `Changes could not be determined: no comparable observation coverage.` Always show partial failures even when other changes were found.

`COMPLETE` describes scan coverage, not exhaustive detection. Traversals are not atomic snapshots; concurrent changes and races may make individual observations uncertain. Record encountered race failures rather than fabricating certainty.

## Snapshot strategies and before-state

```swift
enum SnapshotStrategy {
    case metadata
    case hashed
    case content
}
```

v0.1 implements metadata only:

```text
path, type, size, modificationTime, permissions, symlinkTarget?
```

Compare metadata for CREATE / MODIFY / DELETE; moves may appear as delete plus create. Metadata equality is not proof of byte equality. Same-size rewrites with unchanged timestamps and changes restored before the after snapshot may be missed.

For future strategies:

| Strategy | Before execution | After execution | Intended use |
| --- | --- | --- | --- |
| metadata | Metadata | Metadata | General and large files |
| hashed | Metadata and digest | Metadata and digest | Explicitly selected byte comparisons |
| content | Metadata, digest, bounded content | Same | Selected small text configuration files |

A before hash must be computed before execution. Hashing a changed file afterwards cannot reconstruct its original state. Textual or semantic diffs require original content captured before execution too.

v0.2 will use explicit file selection and a documented size limit for content capture, not blanket configuration-directory collection. Oversized, unreadable, or invalid-text files fall back to metadata with the content-comparison limitation recorded. Never execute shell configuration to interpret it; unsupported expressions receive a conservative generic summary.

## Privacy and ephemeral content

Comparison snapshots and persistent receipts are separate data models.

- Keep selected raw content in memory where practical; any spill files require owner-only permissions and cleanup on success, failure, and handled cancellation.
- Do not serialize raw before/after contents or raw textual diffs into receipts by default.
- Derive sanitized semantic results, then release temporary content. Cleanup does not promise secure erasure or recovery after SIGKILL.
- Do not persist exported secret values. Even PATH strings and semantic summaries need a privacy policy; ambiguous sensitive changes can be recorded as `environment variable changed` without values.
- v0.1 persists the executable identity but omits argv values by default. Mark omitted arguments explicitly in history/inspect. Keep argv in memory only to launch the child; avoid echoing raw arguments in diagnostics.
- Do not persist environment variables or child output. Paths and metadata themselves can be sensitive; receipts remain local with restricted permissions.

Argument recording, redaction overrides, and raw content export are future explicit opt-ins, not prerequisites for v0.1.

## Receipt and storage

```text
Receipt
  schemaVersion
  aftershVersion
  id
  commandExecutable
  argumentsOmitted
  workingDirectory
  startedAt / endedAt / commandDuration
  termination              # exited(code) | signaled(number)
  observationScope
  changes[]                # type, path, beforeMetadata?, afterMetadata?
  interrupted
```

Use unique IDs, schema versioning from the first release, and atomic writes under `~/.local/share/aftersh/receipts/`. Create storage directories with mode 0700 and files with mode 0600. Use unique temporary files and atomic rename to prevent concurrent runs from overwriting each other.

A save error is a live persistence outcome, not proof of command failure. Report it without claiming durable history. Corrupt or unsupported receipt versions must produce useful diagnostics; history should continue listing readable entries.

Define `inspect last` as the most recently completed saved run, with the receipt ID as a deterministic tie-breaker. `inspect <id>` may accept an unambiguous prefix; reject ambiguous matches. Store structured observations and render them on inspection. JSON is sufficient until actual query requirements justify SQLite.

## v0.2 — Useful Receipt

Add selected content snapshots, conservative shell-config semantic diffs, noise filtering, and importance ranking. Keep raw metadata observations available even when the default view groups low-value changes. Do not preserve sensitive content merely to support a verbose view.

First meaningful demo: turn a literal PATH addition into `PATH entry added`, without claiming to understand arbitrary shell programs.

## v0.3 — macOS Awareness

- FSEvents supplements endpoint snapshots. Define startup readiness, draining, dropped-event handling, and timing gaps before claiming runtime coverage. Events still do not establish causation.
- Launchd inspection parses changed plist files. Report a service definition observed; a plist alone does not prove the service is loaded or running.
- Package inspection compares `pkgutil` receipts. New receipt IDs are evidence of package receipts appearing; version changes under existing IDs require separate comparison. Do not imply Homebrew awareness from `pkgutil` alone.

Broaden watch defaults only after measuring cost and noise. Do not automatically elevate privileges to bypass observation failures.

## Validation

Use isolated temporary fixtures, never the developer's actual shell configuration or system service directories.

v0.1 checks must cover argv and PATH resolution, stdin and pipelines, separate stderr, working directory/environment inheritance, exit codes, interactive terminal behavior, Ctrl-C/SIGTERM with ordinary descendants, and repeat interruption.

Diff fixtures cover creation/modification/deletion, missing roots, exclusions, symlinks, overlapping roots, and partial before/after failures without false changes. Persistence checks cover reload, permissions, concurrent saves, corrupt input, and save failures independent of child status.

Measure before/after scan time separately from command duration, memory use, receipt size, and readability on representative scoped trees. Record the measured scope and limitations; do not claim performance from the trivial touch demo alone.
