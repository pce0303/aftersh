# aftersh

> **Know what changed after `sh`.**

`aftersh` is a macOS CLI that turns changes observed around a shell command into a human-readable receipt.

**Status: v0.1 Minimal Receipt (release gate complete).** Core flow: run → snapshot → diff → save → history/inspect.

## Why aftersh?

After running an unfamiliar installer or setup script, it can be hard to tell what appeared or changed. `aftersh` aims to answer that question without making you dig through your Mac manually.

The product is the receipt: useful information about observed changes, with clear limits on what was actually inspected. Observation is not causation. Other processes can change files during a run, and snapshots do not establish which process made a change.

## Requirements

- Apple Silicon macOS (tested on arm64)
- macOS 13+ (see `Package.swift`)
- Swift 6.4+ / Swift Package Manager (Xcode or Command Line Tools)

Full `swift test` needs the Swift Testing macros from a complete Xcode toolchain. With Command Line Tools alone, `swift build` works; `swift test` may fail to compile the test macros.

## Install / build

```bash
git clone https://github.com/pce0303/aftersh.git
cd aftersh
swift build
# Binaries:
#   .build/debug/af
#   .build/debug/aftersh
```

Optional: copy or symlink `.build/debug/af` onto your `PATH`.

## v0.1 — Minimal Receipt

The first release has one small contract:

- Run a command while preserving its arguments, streams, environment, working directory, exit status, and interrupt behavior.
- Compare before/after metadata for explicitly selected paths.
- Report CREATE / MODIFY / DELETE observations with coverage information.
- Save a JSON receipt and provide `history` and `inspect`.

FSEvents, semantic shell diffs, importance ranking, Launchd inspection, and package inspection are later milestones.

### Usage

The project name remains **aftersh**; the primary executable is **`af`**. An `aftersh` executable alias exposes the same interface. Execution is the default subcommand, so `run` is optional.

```bash
af -w . -e ./node_modules -- npm install
# Equivalent explicit form:
aftersh run --watch . --exclude ./node_modules -- npm install
```

| Short | Long | Purpose |
| --- | --- | --- |
| `-w` | `--watch` | Watch a path; repeatable |
| `-e` | `--exclude` | Exclude a path; repeatable |
| `-r` | `--receipt-output` | Choose auto, stderr, or none |
| `-h` | `--help` | Show help |

Use single-letter short options (`-e`, not `-ec`). The required `--` separates aftersh options from the child command and its arguments. `af history` and `af inspect last` remain explicit subcommands.

### Reproducible demo

```bash
mkdir -p /tmp/aftersh-test
af -w /tmp/aftersh-test -- touch /tmp/aftersh-test/hello
af history
af inspect last
```

A fresh test directory produces a receipt like:

```text
AFTERSH RECEIPT

Command
  /usr/bin/touch
Arguments
  omitted
Command exit
  0
Observation
  COMPLETE

OBSERVATION SCOPE
Watched
  /tmp/aftersh-test
Excluded
  ~/.local/share/aftersh (automatic: aftersh storage)
Failed
  none

Observed between snapshots
CREATED
  /tmp/aftersh-test/hello

Receipt saved
  <receipt-id>
```

Receipts are written under `~/.local/share/aftersh/receipts/` (`0700` / `0600`). Use `af history` and `af inspect last` (or an id / unambiguous prefix) to reload them. A save failure is reported separately and never claims `Receipt saved`.

`COMPLETE` means the selected, non-excluded scope was scanned successfully at both endpoints. It does not mean every system change was captured. Metadata comparison can miss content changes, and transient changes between snapshots may disappear.

If scanning fails, the receipt lists the affected paths and reasons and marks observation `PARTIAL` or `FAILED`, independently of command exit status. Missing observation is never treated as evidence that a file was deleted.

For an empty diff with usable coverage:

```text
No changes detected in successfully observed paths.
```

With no comparable coverage, report that changes could not be determined instead.

### Command transparency

```bash
af -w /tmp/aftersh-test -- echo hello | grep hello
```

**Receipt output must never be written to the child command's stdout stream.** Child stdin, stdout, and stderr retain their normal destinations. Automatic receipt output goes to `/dev/tty` when available, otherwise stderr. Use `-r stderr` or `-r none` (long form: `--receipt-output`) to choose explicitly; the default is `auto`.

`run` returns the child's exit code, or `128 + signal` for signal termination. Ctrl-C must reach the child and must not leave it running because only the wrapper exited. Observation and receipt-save errors are reported separately. See the [execution contract](docs/ARCHITECTURE.md#command-execution-contract) for details and limits.

`history` and `inspect` write their requested output to stdout; they do not wrap a child command.

## Limits (read these)

- **Observation is not causation.** Concurrent processes can change watched paths; snapshots do not attribute writers.
- **Metadata only in v0.1.** Same-size rewrites with unchanged mtime may be missed; moves appear as DELETE+CREATE.
- **Scans are non-atomic.** Races during traversal can leave unknown regions (`PARTIAL` / `FAILED`).
- **No default whole-system watch.** You must pass `-w` / `--watch`.
- **Detached / background writers** after the direct child exits are outside the observation window.
- **Interactive and job-control edge cases** (full shell job control) are outside v0.1; ordinary foreground children should still be waited on across Ctrl-C.
- **Privacy:** argv values, environment, and child output are not stored; paths and metadata in local receipts can still be sensitive.

## Privacy and persistence

Receipts are stored under `~/.local/share/aftersh/receipts/` with schema versioning and restricted permissions. v0.1 stores metadata, not file contents, environment variables, or captured command output. Command arguments are omitted from persisted receipts by default because they can contain secrets.

Future content comparisons will retain selected originals only temporarily and persist only sanitized summaries. A semantic summary can also contain secrets; it is not safe merely because it is shorter.

## Scan overhead (measured)

On Apple Silicon (arm64), watching a fixture of ~2000 small files (~2040 path entries including directories):

- Each endpoint metadata scan took about **350–360 ms** (from receipt coverage `startedAt`/`endedAt`).
- The wrapped `/usr/bin/true` child itself was about **65 ms**; full wall-clock also includes save/render outside those intervals.

Do not extrapolate from the trivial `touch` demo alone; cost scales with the size of the watched trees.

## Architecture and layout

```text
Validate scope and command
  → Before snapshot
  → Execute command and wait
  → After snapshot
  → Diff
  → Save receipt
  → Render summary
```

```text
aftersh/
├── Package.swift
├── Sources/
│   ├── AftershCore/
│   │   ├── CLI/
│   │   ├── Core/
│   │   ├── Monitor/
│   │   ├── Diff/
│   │   ├── Report/
│   │   └── Storage/
│   ├── af/
│   └── aftersh/
├── Tests/
└── docs/
```

Stack: Swift, Swift Package Manager, Swift Argument Parser, Foundation, and JSON storage. Primary executable: `af`; alias: `aftersh`.

## Roadmap

| Version | Goal | Scope |
| --- | --- | --- |
| v0.1 | Minimal Receipt | Transparent execution, scoped metadata diff, coverage, persistence, history/inspect |
| v0.2 | Useful Receipt | Selected content snapshots, semantic shell diffs, noise filtering, importance ranking |
| v0.3 | macOS Awareness | FSEvents, LaunchAgent/LaunchDaemon inspection, `pkgutil` |

Read the [architecture](docs/ARCHITECTURE.md) and [implementation roadmap](docs/ROADMAP.md).

## Non-goals

`aftersh` is not a sandbox, malware scanner, package manager, full system monitor, or automatic rollback tool. Perfect attribution, a GUI, and cross-platform support are outside these initial releases.

Success means receipts stay fast, relevant, and trustworthy during real installations, while making incomplete observation visible.

## License

TBD. MIT is a candidate; no license has been selected yet.
