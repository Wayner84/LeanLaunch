# LeanLaunch Foundation Implementation Plan

> **For Hermes:** Implement this plan task-by-task with strict RED-GREEN-REFACTOR cycles.

**Goal:** Build a zero-background-footprint Windows CLI that audits an application's process/service impact, launches it on demand, and cleans up only explicitly configured resources when the app exits.

**Architecture:** Use Windows PowerShell 5.1, already included with Windows, to avoid installing a runtime or permanent service. A thin `leanlaunch.cmd` shim exposes a natural command-line interface suitable for PowerToys Command Palette's shell execution. Profiles are declarative JSON, with built-in conservative safeguards: services are only stopped if LeanLaunch started them, residual processes require explicit profile configuration, and snapshots/diffs are read-only.

**Tech Stack:** Windows PowerShell 5.1, JSON profiles, Pester 3.4-compatible tests, GitHub Actions on `windows-latest`, Git.

---

## Design principles

- LeanLaunch itself must install no service, scheduled task, startup item, tray process, or daemon.
- `leanlaunch` runs only while executing a command or supervising a launched application.
- Default behavior is conservative: observe first; never infer destructive cleanup automatically.
- A profile explicitly names executable, arguments, services, and optional residual processes.
- Only services started by the current LeanLaunch run are eligible for automatic stop.
- Process cleanup is opt-in and scoped by exact process names plus optional executable paths.
- Snapshot and diff commands must work without elevation where Windows permits; service control reports a useful elevation error.
- User profiles live under `%LOCALAPPDATA%\LeanLaunch\profiles`; repository examples remain immutable templates.

## CLI surface

- `leanlaunch help`
- `leanlaunch doctor`
- `leanlaunch snapshot <name>`
- `leanlaunch diff <before> <after>`
- `leanlaunch list`
- `leanlaunch show <profile>`
- `leanlaunch profile init <name> --exe <path>`
- `leanlaunch run <profile> [--dry-run] [--keep-services] [--no-cleanup]`

## Task 1: Repository and test harness

**Files:**
- Create: `.gitignore`, `LICENSE`, `LeanLaunch.psd1`
- Create: `tests/Run-Tests.ps1`, `tests/TestHelpers.ps1`
- Create: `.github/workflows/ci.yml`

**Steps:**
1. Initialize Git with `main`.
2. Add Pester-compatible test harness and fixture isolation using temporary directories.
3. Add CI that runs Windows PowerShell tests on `windows-latest`.
4. Verify the empty harness executes successfully.

## Task 2: Paths, profile model, and validation (TDD)

**Files:**
- Test: `tests/LeanLaunch.Profile.Tests.ps1`
- Create: `src/LeanLaunch.psm1`
- Create: `profiles/example.json`

**RED:** Tests define safe profile-name validation, environment-variable expansion, profile lookup, JSON parsing, defaults, executable existence checks, and rejection of malformed service/process entries.

**GREEN:** Implement only the profile/path functions required by each failing test.

**REFACTOR:** Centralize validation and deterministic JSON conversion.

## Task 3: Snapshot capture and persistence (TDD)

**Files:**
- Test: `tests/LeanLaunch.Snapshot.Tests.ps1`
- Modify: `src/LeanLaunch.psm1`

**RED:** Tests require a schema-versioned snapshot containing timestamp, host, processes, services, startup commands, and scheduled tasks; persistence must sanitize names and write under the configured data directory.

**GREEN:** Implement injectable capture providers so tests use fixtures while production uses CIM/Get-Process/Get-Service/registry/task APIs.

**REFACTOR:** Normalize process/service records for stable comparisons.

## Task 4: Snapshot diff engine (TDD)

**Files:**
- Test: `tests/LeanLaunch.Diff.Tests.ps1`
- Modify: `src/LeanLaunch.psm1`

**RED:** Tests cover added/removed processes, process-count deltas, newly running/stopped services, new startup entries, and new/changed scheduled tasks.

**GREEN:** Implement deterministic comparisons and a concise summary object.

**REFACTOR:** Share indexing helpers and preserve machine-readable output.

## Task 5: Managed launch lifecycle (TDD)

**Files:**
- Test: `tests/LeanLaunch.Run.Tests.ps1`
- Modify: `src/LeanLaunch.psm1`

**RED:** Tests require dry-run planning, starting only stopped required services, waiting for the configured app, stopping only services started by LeanLaunch, respecting keep/no-cleanup flags, and exact-name residual-process cleanup.

**GREEN:** Implement lifecycle operations through injectable adapters. Record session state before cleanup and use `try/finally` so cleanup runs after normal exit or interruption.

**REFACTOR:** Separate plan generation from execution, making `--dry-run` a faithful preview.

## Task 6: Command dispatcher and Windows shim (TDD where behavioral)

**Files:**
- Test: `tests/LeanLaunch.Cli.Tests.ps1`
- Create: `leanlaunch.ps1`, `bin/leanlaunch.cmd`
- Modify: `src/LeanLaunch.psm1`

**RED:** Tests cover command parsing, helpful usage errors, nonzero exit codes, JSON output option where applicable, and dry-run output.

**GREEN:** Implement dispatcher and stable human-readable formatting.

**REFACTOR:** Keep the entry script thin; all behavior remains in the module.

## Task 7: User-local installer and Command Palette workflow

**Files:**
- Create: `install.ps1`, `uninstall.ps1`
- Create: `docs/COMMAND-PALETTE.md`

**Steps:**
1. Installer copies only LeanLaunch files to `%LOCALAPPDATA%\Programs\LeanLaunch` and adds its `bin` directory to the user PATH.
2. Installer creates data/profile directories but no persistent process, service, task, startup entry, or registry autorun.
3. Uninstaller removes installed files and only the exact PATH entry it added, preserving user profiles unless `-RemoveData` is explicitly supplied.
4. Document invoking `leanlaunch run solidworks` through PowerToys Command Palette's shell/command execution.
5. Smoke-test installation into a temporary prefix rather than altering the real PATH during development.

## Task 8: Documentation and starter workflow

**Files:**
- Create: `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, `docs/APP-AUDIT-WORKFLOW.md`, `docs/PROFILE-SCHEMA.md`
- Create: `profiles/example.json`, `profiles/solidworks.example.json`

**Steps:**
1. Explain the resource-efficiency philosophy and explicit safety model.
2. Document tomorrow's repeatable workflow: snapshot before install, install one app, snapshot after, diff, inspect while app runs, create profile, dry-run, then validate cleanup.
3. Clearly warn against blindly stopping vendor licensing, update, security, hardware, or shared services.
4. Document profile fields and minimal examples without claiming unverified vendor service names.

## Task 9: Verification and GitHub publication

**Steps:**
1. Run the complete Pester suite in Windows PowerShell 5.1.
2. Run `leanlaunch doctor`, `snapshot`, `diff`, `list`, `show example`, and a harmless dry-run end-to-end.
3. Confirm Git status contains no snapshots, user profiles, secrets, or machine-specific paths.
4. Review for command injection, over-broad process termination, unsafe service cleanup, quoting, and elevation behavior.
5. Create public repository `Wayner84/LeanLaunch`, set description/topics, commit, and push `main`.
6. Verify the remote URL, branch, and GitHub-visible files.

## Acceptance criteria

- No LeanLaunch background process remains after a command completes.
- No installation-time autorun mechanism is created.
- Tests pass on local Windows PowerShell 5.1 and GitHub Actions.
- Snapshots and diffs provide enough information to profile one application at a time.
- Dry-run shows exactly which services/processes would be touched.
- Cleanup cannot stop a pre-existing service merely because it appears in a profile.
- The CLI is accessible as `leanlaunch ...` and documented for PowerToys Command Palette.
- Public GitHub repository exists with all committed work pushed.

## Risks and trade-offs

- Some launchers exit before their real child application. Profiles therefore need optional `waitForProcessNames` support and careful per-app validation.
- Administrative rights may be needed for service changes; LeanLaunch should fail clearly rather than auto-elevating invisibly.
- Process names are not globally unique. Optional executable-path constraints reduce collateral risk.
- Vendor licensing and update services may be shared across applications. Profiles must be reviewed rather than generated as unquestioned truth.
- PowerShell 5.1 provides zero-runtime deployment but less polished packaging than a future compiled UI; it is the lowest-impact foundation for tomorrow's audits.
