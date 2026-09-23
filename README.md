# aftersh

> **Know what changed after `sh`.**

`aftersh` is a macOS CLI that turns changes observed around a shell command into a human-readable receipt.

**Status: Implementation in progress.** Transparent command execution (`af` / `aftersh`) works; scoped snapshots, receipts, and persistence are next.

## Why aftersh?

After running an unfamiliar installer or setup script, it can be hard to tell what appeared or changed. `aftersh` aims to answer that question without making you dig through your Mac manually.

The product is the receipt: useful information about observed changes, with clear limits on what was actually inspected. Observation is not causation. Other processes can change files during a run, and snapshots do not establish which process made a change.

## v0.1 — Minimal Receipt

The first release has one small contract:

- Run a command while preserving its arguments, streams, environment, working directory, exit status, and interrupt behavior.
- Compare before/after metadata for explicitly selected paths.
- Report CREATE / MODIFY / DELETE observations with coverage information.
- Save a JSON receipt and provide `history` and `inspect`.

FSEvents, semantic shell diffs, importance ranking, Launchd inspection, and package inspection are later milestones.

### Planned usage

The project name remains **aftersh**; the primary executable is **`af`**. An `aftersh` executable alias will expose the same interface. Execution is the default subcommand, so `run` is optional.

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

```bash
mkdir -p /tmp/aftersh-test
af -w /tmp/aftersh-test -- touch /tmp/aftersh-test/hello
af history
af inspect last
```

`-w` / `--watch` is repeatable and required in v0.1; there is no implicit whole-system scan. `-e <path>` / `--exclude <path>` optionally excludes a path and its descendants. A fresh test directory produces a receipt like:

```text
AFTERSH RECEIPT

Command
  touch /tmp/aftersh-test/hello
Command exit
  0
Observation
  COMPLETE

OBSERVATION SCOPE
Watched
  /tmp/aftersh-test
Excluded
  none
Failed
  none

Observed between snapshots
CREATED
  /tmp/aftersh-test/hello

Receipt saved
  <receipt-id>
```

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

## Privacy and persistence

Receipts are planned under `~/.local/share/aftersh/receipts/` with schema versioning and restricted permissions. v0.1 stores metadata, not file contents, environment variables, or captured command output. Command arguments are omitted from persisted receipts by default because they can contain secrets.

Future content comparisons will retain selected originals only temporarily and persist only sanitized summaries. A semantic summary can also contain secrets; it is not safe merely because it is shorter.

## Planned architecture and project structure

```text
Validate scope and command
  → Before snapshot
  → Execute command and wait
  → After snapshot
  → Diff
  → Save receipt
  → Render summary
```

The following structure is the current package layout:

```text
aftersh/
├── Package.swift
├── Sources/
│   ├── AftershCore/
│   │   ├── CLI/
│   │   ├── Core/
│   │   ├── Monitor/      # planned
│   │   ├── Diff/         # planned
│   │   ├── Report/       # planned
│   │   └── Storage/      # planned
│   ├── af/
│   └── aftersh/
├── Tests/
└── docs/
```

Stack: Swift, Swift Package Manager, Swift Argument Parser, Foundation, and JSON storage. Primary executable: `af`; alias: `aftersh`. macOS first; deeper monitoring and inspectors will be added only when needed.

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
