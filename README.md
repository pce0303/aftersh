# aftersh

> **Know what changed after `sh`.**

`aftersh` is a macOS CLI that turns changes observed around a shell command into a human-readable receipt.

**Status: v0.3 in progress.** v0.1 (run → snapshot → diff → save → history/inspect) and the v0.2 first pass (selected content, literal PATH summaries, summary ranking) are complete. v0.3 adds launchd definition summaries, opt-in package receipt comparison (`--pkgutil`), and opt-in FSEvents evidence (`--events`).

## Why aftersh?

After running an unfamiliar installer or setup script, it can be hard to tell what appeared or changed. `aftersh` aims to answer that question without making you dig through your Mac manually.

The product is the receipt: useful information about observed changes, with clear limits on what was actually inspected. Observation is not causation. Other processes can change files during a run, and snapshots do not establish which process made a change.

## Requirements

- Apple Silicon macOS (tested on arm64)
- macOS 13+ (see `Package.swift`)
- Swift 6.4+ / Swift Package Manager (Xcode or Command Line Tools)

Full `swift test` needs the Swift Testing macros. With a complete Xcode toolchain, plain `swift test` works. With Command Line Tools alone, point the compiler at the macro plugin:

```bash
swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

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

Semantic shell diffs and importance ranking arrived in v0.2; launchd definition summaries, package receipts, and FSEvents in v0.3.

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
| | `--content` | Compare a file’s text (bounded); must be under a watch root; repeatable |
| `-e` | `--exclude` | Exclude a path; repeatable |
| | `--pkgutil` | Compare macOS package receipts before and after the run |
| | `--events` | Record FSEvents under the watch roots during the run |
| `-r` | `--receipt-output` | Choose auto, stderr, or none |
| `-v` | `--verbose` | Print the full detailed receipt after the run |
| `-h` | `--help` | Show help |

Use single-letter short options (`-e`, not `-ec`). The required `--` separates aftersh options from the child command and its arguments. `af history`, `af inspect`, and `af delete` remain explicit subcommands.

### Reproducible demo

```bash
mkdir -p /tmp/aftersh-test
af -w /tmp/aftersh-test -- touch /tmp/aftersh-test/hello
af history
af inspect last

# Selected-file content + literal PATH summary (v0.2)
FIXTURE=/tmp/aftersh-v02-fixture
mkdir -p "$FIXTURE"
printf 'export PATH=/old\n' > "$FIXTURE/.zshrc"
af -w "$FIXTURE" --content "$FIXTURE/.zshrc" -- \
  sh -c 'printf "export PATH=/old:/new\n" > "$0/.zshrc"' "$FIXTURE"
# Summary includes: PATH entry added: /new

# LaunchAgent definition summary (v0.3); use a fixture, not your real ~/Library
AGENTS=/tmp/aftersh-launchd-demo/LaunchAgents
mkdir -p "$AGENTS"
plutil -create xml1 /tmp/aftersh-launchd-demo/demo.plist
plutil -insert Label -string com.example.demo /tmp/aftersh-launchd-demo/demo.plist
plutil -insert RunAtLoad -bool YES /tmp/aftersh-launchd-demo/demo.plist
af -w "$AGENTS" -- cp /tmp/aftersh-launchd-demo/demo.plist "$AGENTS/com.example.demo.plist"
# Summary includes: LaunchAgent definition observed: com.example.demo (RunAtLoad)
```

When a changed `.plist` sits directly inside a watched `LaunchAgents` or `LaunchDaemons` directory, the receipt summarizes the definition: `Label`, the program path (`Program` or the first `ProgramArguments` entry), `RunAtLoad`, `KeepAlive`, and whether `StartInterval` is set. Remaining arguments and `EnvironmentVariables` are never stored. The summary says a definition was **observed**; it does not claim the job is loaded or running.

### Package receipts (`--pkgutil`)

```bash
af --pkgutil -w /tmp/aftersh-test -- sudo installer -pkg ./tool.pkg -target /
```

The summary adds one line per receipt that changed:

```text
Package receipt added: com.example.tool 1.2.3
Package receipt updated: com.example.tool (version now 1.2.4)
Package receipt removed: com.example.tool
```

How changes are detected:

- **New or removed IDs** come from `pkgutil --pkgs` before and after the run (default volume only). Only new IDs get an extra `pkgutil --pkg-info-plist` call, for their version.
- **Same-ID updates** come from the modification time of the receipt plist in `/var/db/receipts` (or `/Library/Apple/System/Library/Receipts`). Only the new version is shown; the old version is not collected.

If `pkgutil` fails or times out (10 s), or the receipt directories cannot be read, the receipt records a limitation and the run continues. The wording says a package **receipt** appeared, changed, or disappeared. It does not claim the install succeeded, which process installed it, or anything about Homebrew.

### Runtime events (`--events`)

Snapshots only compare the two endpoints, so a file created and removed during the run is invisible to them. `--events` records FSEvents under the watch roots while the child runs and lists paths that appear only in events:

```bash
D=/tmp/aftersh-events-demo; mkdir -p "$D"
af --events -w "$D" -- sh -c "touch $D/tmp1; rm $D/tmp1; echo hi > $D/kept"
```

```text
AFTERSH
Observation  COMPLETE
Command      /bin/sh
Exit         0
Events       COMPLETE

CREATED
  /tmp/aftersh-events-demo/kept

(+1 path seen only in events — af inspect last)
(+1 directory metadata — af inspect last)
```

`af inspect last` lists those paths (up to 50) under **SEEN ONLY IN EVENTS**. `Events` is `COMPLETE`, `GAPPED` (FSEvents reported dropped or coalesced events, the path cap was hit, or delivery could not be confirmed before stop), or `UNAVAILABLE` (the stream could not start). Gap reasons are listed under Limits. Events are supplemental: they show that a path was touched under the watch scope during the run window, not which process touched it, and they never change snapshot coverage status.

### Summary view

By default the live receipt is a **short summary** ordered by importance (semantic → created/deleted → modified; directory metadata collapsed). Full scope, limits, and low-signal directory metadata changes are in `af inspect last` (or pass `-v` on the run).

```text
AFTERSH
Observation  COMPLETE
Command      /usr/bin/touch
Exit         0

CREATED
  /tmp/aftersh-test/hello

(+1 directory metadata — af inspect last)

Receipt saved
  <receipt-id>
```

Receipts are written under `~/.local/share/aftersh/receipts/` (`0700` / `0600`). Use `af history` and `af inspect last` (or an id / unambiguous prefix) to reload them. A save failure is reported separately and never claims `Receipt saved`.

```bash
af delete 35b6c507     # one receipt: id, unambiguous prefix, or last
af delete --all --yes  # every saved receipt; --all without --yes is refused
```

`af delete <id>` also removes an exact `<id>.json` file that can no longer be decoded, so corrupt receipts can be cleaned up without touching the directory by hand.

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
- **Events are supplemental.** `--events` does not attribute paths to processes; a `GAPPED` status means some events may be missing.
- **Package receipts are not installs.** `--pkgutil` reports receipt changes only; same-ID updates rely on receipt file modification times.
- **Interactive and job-control edge cases** (full shell job control) are outside v0.1; ordinary foreground children should still be waited on across Ctrl-C.
- **Privacy:** argv values, environment, and child output are not stored; paths and metadata in local receipts can still be sensitive.

## Privacy and persistence

Receipts are stored under `~/.local/share/aftersh/receipts/` with schema versioning and restricted permissions. v0.1 stores metadata, not file contents, environment variables, or captured command output. Command arguments are omitted from persisted receipts by default because they can contain secrets.

Selected `--content` files are compared in memory (64 KiB limit); only sanitized semantic summaries (e.g. `PATH entry added: /new`) are persisted — never raw file bodies. A semantic summary can still contain secrets; it is not safe merely because it is shorter.

## Scan overhead (measured)

On Apple Silicon (arm64), watching a fixture of ~2000 small files (~2040 path entries including directories):

- Each endpoint metadata scan took about **350–360 ms** (from receipt coverage `startedAt`/`endedAt`).
- The wrapped `/usr/bin/true` child itself was about **65 ms**; full wall-clock also includes save/render outside those intervals.

Do not extrapolate from the trivial `touch` demo alone; cost scales with the size of the watched trees.

Opt-in flag overhead (Apple M4 Pro, macOS 27, release build, ~2000-file `/tmp` fixture, child `touch`, median of 8 wall-clock runs, 33 package receipts on the machine):

| Flags | Median | Added |
| --- | --- | --- |
| none | ~0.31 s | — |
| `--pkgutil` | ~0.33 s | ~0.02 s |
| `--events` | ~0.39 s | ~0.07 s |
| `--pkgutil --events` | ~0.395 s | ~0.08 s |

`--events` includes the drain at stop, where the watcher waits for a sentinel event to confirm delivery. `--pkgutil` cost grows with the number of new package IDs (one `pkgutil` call each).

## Architecture and layout

```text
Validate scope and command
  → Before snapshot (+ pkgutil before)
  → Start FSEvents watcher (--events)
  → Execute command and wait
  → Drain and stop watcher
  → After snapshot (+ pkgutil after)
  → Diff + semantic summaries
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
│   │   ├── Inspectors/
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
