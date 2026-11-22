# LeanLaunch

**Launch heavyweight Windows applications only with the resources they need—then clean up the resources they leave behind.**

LeanLaunch is a zero-resident-footprint Windows CLI and desktop GUI for people who want CAD, EDA, slicing, rendering, Office, and other large applications available without allowing every vendor helper to run all day.

It is built around an evidence-first workflow:

1. register the application and capture a **fresh before-install snapshot**;
2. install it, then capture the **after-install snapshot** and review the diff;
3. explicitly classify every discovered service, process, startup entry, and scheduled task — nothing is assumed safe to disable;
4. build a conservative, human-reviewed JSON profile from only the resources you approved;
5. flip one policy toggle per application: **Managed** (LeanLaunch may start/stop the resources you approved) or **Unmanaged** (LeanLaunch never touches it, ever);
6. launch with `leanlaunch app run <name>` (or the low-level `leanlaunch run <profile>`);
7. stop only explicitly configured leftovers and only services that LeanLaunch itself started.

## Resource-efficiency promise

LeanLaunch installs **no Windows service, scheduled task, startup item, tray process, daemon, updater, or telemetry component**. The command (CLI or GUI) exists only while capturing a snapshot, showing a window, or supervising a launched application — closing it ends the process completely.

## Status — development snapshot, not ready to install

This public repository is a **work-in-progress checkpoint for further development**, not a release or a controlled pilot. The latest local PowerShell 5.1 suite has **299 passing tests and one failing installer rollback regression** (the newly created data-directory cleanup failure is not reported as expected). Installer rollback needs investigation and a fresh independent safety review before any real installation or application audit. See [development handoff](docs/DEVELOPMENT-HANDOFF.md). Do not use the install instructions below yet.

The snapshot/diff collectors, the application-record audit workflow with a Managed/Unmanaged policy toggle, profile generation from reviewed resources, managed launch with identity-bound cleanup, a WPF desktop GUI, the installer/uninstaller, tests, and Command Palette integration are all in place. Community application profiles should be treated as reviewable starting points, not universal truth.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (included with Windows)
- Administrative rights only when a run actually needs to start a protected service

No .NET SDK, Node.js, Python, package manager, or background runtime is required. The GUI uses only the WPF assemblies built into Windows.

## Install

```powershell
git clone https://github.com/Wayner84/LeanLaunch.git
cd LeanLaunch
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Open a new terminal and run:

```text
leanlaunch doctor
```

The default install location is `%LOCALAPPDATA%\Programs\LeanLaunch`. User profiles, snapshots, application records, and audit evidence live separately under `%LOCALAPPDATA%\LeanLaunch`, so uninstalling the program never touches your review history unless you ask it to.

## Quick start: audit Microsoft Office (recommended first application)

```text
leanlaunch app new office --exe "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE" --display-name "Microsoft Office"
leanlaunch app scan-before office
# install/update Office, let it settle
leanlaunch app scan-after office
leanlaunch app show office
leanlaunch app classify office "Service|clicktorunsvc" Managed --note "Only needed while Office runs"
leanlaunch app profile office
leanlaunch app policy office Managed
leanlaunch app run office --dry-run
leanlaunch app run office
```

Or do the same thing visually:

```text
leanlaunch gui
```

See [the full application audit workflow](docs/APP-AUDIT-WORKFLOW.md) for what every step does and why, including the safety rules around startup entries and scheduled tasks.

## Commands

```text
leanlaunch doctor
leanlaunch snapshot <name>
leanlaunch diff <before> <after>
leanlaunch list
leanlaunch show <profile>
leanlaunch profile init <name> --exe <path>
leanlaunch run <profile> [--dry-run] [--keep-services] [--no-cleanup]
leanlaunch gui

leanlaunch app new <name> --exe <path> [--display-name <text>]
leanlaunch app list
leanlaunch app show <name>
leanlaunch app scan-before <name>
leanlaunch app scan-after <name>
leanlaunch app classify <name> <key> <Managed|Unmanaged|Reviewed> [--note <text>]
leanlaunch app park <name> <key> <On|Off>
leanlaunch app profile <name> [--force]
leanlaunch app policy <name> <Managed|Unmanaged>
leanlaunch app run <name> [--dry-run] [--keep-services] [--no-cleanup]
```

`leanlaunch run`/`leanlaunch app run` exit with code `0` on a clean run, `3` if cleanup was
incomplete, `4` if an attributable child process never exited within the safety bound, `2` for a
usage error, and `1` for any other error.

## Safety model

- Every application defaults to **Unmanaged**: LeanLaunch takes no enable/disable/cleanup action at all until you explicitly review evidence and switch it to Managed.
- Startup entries and scheduled tasks can only ever be classified `Reviewed`/`Unreviewed` — LeanLaunch's own schema makes it impossible to ask it to manage or disable one.
- Service names must be exact and pass strict validation.
- **Managed execution is cryptographically bound to the exact audit that produced it, not merely a matching ID.** Generating a profile records a SHA-256 hash of the exact profile bytes written. Enabling Managed policy and every Managed run both revalidate, immediately before acting: the audit ID still matches, no discovered resource is Unreviewed, the profile file at its one expected location (never a same-named repository template) still hashes to what was recorded, and the profile's services/residual-process rules are structurally identical, element for element, to what the current audit's classifications say should be Managed. A replaced, hand-edited, or stale profile — or a hand-edited application record whose classifications drifted from what was reviewed — fails this and the action is refused.
- **A rescan cannot silently coexist with an old Managed profile.** Each before-install baseline is single-use for completion: after `scan-after` has completed an audit, calling it again against the same baseline is refused. The only way to capture new evidence is a fresh `scan-before`, which always mints a new audit ID and immediately drops the application back to Unmanaged with any bound profile cleared — new evidence and an old runnable profile can never coexist.
- Cleanup stops only services whose start adapter proved a successful transition during the current run. A single native service handle is used to query the owned process identity and issue the stop, and the stop additionally re-validates the native creation time of the process backing that service's reported PID immediately beforehand — so neither a delete/recreate replacement nor a stop/restart-with-PID-reuse race can redirect cleanup to an instance this run did not start.
- A Managed service may optionally be opted into idle parking, from the CLI (`leanlaunch app park <name> <key> On`) or the GUI (the Audit tab's "Park when idle" checkbox and "Save idle-parking preference" button). Parking is a safe stop-then-disable transaction: LeanLaunch records the service's real start mode *and* whether it was running, identity-bind-stops it first if it was running, and only then disables it. `On` takes effect the next time policy is (re-)applied as Managed; `Off` restores an already-parked service (stopped and, if it was originally running, restarted) immediately, regardless of policy, with the service change and the persisted record written as one transactional step — if persistence fails after the service was restored, the service is rolled back to parked so the two can never diverge. Re-parking after a run only ever proceeds once the service is confirmed stopped: `--keep-services`, `--no-cleanup`, a preserved timeout, or a cleanup failure that leaves it running all leave the service at its running-capable start mode rather than stranding it running-but-Disabled. This is reversible, off by default, requires administrator rights to activate or restore, and fails closed (leaving the service exactly as it was) if the recorded mode or running state ever drifts. The GUI's classification grid shows "Park pref." (the preference) and "Parked now" (live state) as two distinct columns — a preference is never displayed as if it were live state.
- Residual process cleanup is opt-in, path-constrained, and limited to attributable descendants of the process this run launched. Process creation identity is tracked across the whole run and revalidated immediately before termination, so PID reuse (of the launched root, an intermediate ancestor, or the target itself) fails closed instead of terminating an unrelated process.
- Persisted application, audit, classification, parked-service, and snapshot records are validated strictly on load: every required field, its exact runtime type (no coercion of a numeric-looking string), and — for classifications and parked-service entries — decision/resourceType vocabulary and service-name syntax. A record that fails validation is never silently dropped: `leanlaunch app list`/the GUI list surface it as an explicit "Malformed" entry instead of hiding it.
- A required service that never reaches the Running state aborts the launch instead of proceeding without it.
- Administrator rights are requested only when a run actually needs to start a stopped service — not merely because the profile lists one.
- Shell and Command Palette launches automatically request UAC only for that case, then keep the complete managed lifecycle in the elevated supervisor.
- Environment variables are expanded without shell evaluation.
- `--dry-run` previews service and process rules (or, for an Unmanaged application, the plain "launch directly, no management" plan) before anything runs.
- `--no-cleanup` launches without stopping anything afterward; `--keep-services` leaves started services running.
- If attributable child waiting reaches its 24-hour safety bound, LeanLaunch preserves the app's services/resources and exits with code `4` instead of cleaning up underneath a potentially running application.
- Cleanup continues past individual errors and reports incomplete cleanup structurally (exit code `3`), rather than stopping partway with no record of what was missed.
- `snapshot` and `diff` still save/return whatever partial evidence collectors did produce, but exit with code `5` if any collector failed, so a failure is never silently indistinguishable from a clean capture. `leanlaunch app scan-before`/`scan-after` are stricter: they refuse to start or complete an audit at all (no partial evidence saved) when any collector fails.

A profile can still be wrong. Review every rule, especially licensing, hardware, security, database, and shared vendor services.

## Desktop GUI

`leanlaunch gui` opens a window listing your applications, with an Overview tab (policy toggle,
safety warnings, dry-run/action plan, launch) and an Audit tab (before/after scan, the
classification grid, idle-parking preference, and "build profile from reviewed resources"). It
calls exactly the same module functions as the CLI — there is one shared lifecycle implementation,
not two, including which adapter (real or injected) reaches every policy, classification, parking,
and scan action. Like every other LeanLaunch surface, it is not resident: closing the window ends
the process, and closing it during an active before/after scan cancels, drains, and disposes that
scan's background runspace/pipeline/timer first, so no process is ever left behind waiting on a
slow or hung collector. Managed launches run in a separate hidden supervisor so the GUI remains
responsive; that supervisor exits with the application and writes its result (atomically) under
`%LOCALAPPDATA%\LeanLaunch\sessions`. Building a profile over an existing one prompts for
confirmation rather than overwriting silently.

## PowerToys Command Palette

After installation, use the palette's shell-command facility:

```text
leanlaunch app run office
```

See [Command Palette setup](docs/COMMAND-PALETTE.md), including a shortcut fallback for configurations that only index shortcuts, and how to pin `leanlaunch gui`.

## Profiles and application records

Repository profiles (`profiles/*.json`) are unreviewed templates — audit before trusting them.
Personal profiles override them by name and live in:

```text
%LOCALAPPDATA%\LeanLaunch\profiles
```

Application records, their audit evidence, and your classification decisions live in:

```text
%LOCALAPPDATA%\LeanLaunch\apps
%LOCALAPPDATA%\LeanLaunch\audits
```

Each profile filename must match its declared `name` (for example, `solidworks.json` must declare `"name": "solidworks"`).

See [profile schema, application-record schema, and safety boundaries](docs/PROFILE-SCHEMA.md).

## Development

Run the test suite with the Windows PowerShell version included in Windows:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

The tests use dependency-injected collectors and operating-system adapters for service/process policy. They never touch real services or unrelated processes. One boundary test starts a harmless, isolated PowerShell sleeper and terminates that exact test-owned process through the native creation-identity handle to prove PID-reuse-safe termination; the GUI smoke test opens and automatically closes its window.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\LeanLaunch\uninstall.ps1"
```

Profiles, snapshots, application records, and audit evidence are preserved by default. To remove them too:

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\LeanLaunch\uninstall.ps1" -RemoveData
```

The installer records exactly which files it copied and, separately, whether and which literal PATH
entry it added — both in the install directory and in a copy under the user data root, so uninstall
can remove exactly and only what this install added even if the install directory was already
deleted some other way. It refuses to delete through a reparse point (symlink/junction), never does
a blanket recursive delete of the install directory, and leaves behind (with a warning) any file
under that directory it did not itself install. A file whose content changed concurrently since
uninstall began is likewise preserved rather than removed. Both scripts support `-WhatIf`, and one
confirmation covers the complete file-and-PATH operation.

Uninstall uses a reversible quarantine phase: every owned file, the marker, and the PATH removal are
moved into invocation-owned same-volume quarantine only after their identity is validated. Until
physical quarantine deletion begins, any failure—including marker/file drift or quarantine payload
substitution—rolls invocation-owned items back to their exact original locations and undoes the PATH
edit when this invocation still owns it. `-RemoveData` applies the same quarantine boundary to the data
root and walks the entire tree without following nested reparse points, both before quarantine and
again immediately before finalization.

The final recursive deletion of a quarantine directory is deliberately documented as a point of no
return: Windows provides no atomic primitive for deleting an arbitrary directory tree, so an OS error
can occur after some quarantined bytes have already been deleted. LeanLaunch then restores every item
still present, reports every missing or unrestorable original path, preserves all recoverable remaining
quarantine content, and fails loudly with its location; it never falsely claims that a partial physical
deletion was completely rolled back. A concurrent process reclaiming an original path is likewise
preserved rather than overwritten.

Upgrading an existing install (running `install.ps1` again over a prior installation) captures each
destination file's exact content fingerprint immediately before backing it up, and re-checks that
fingerprint immediately before the atomic swap that overwrites it. A file changed by another process in
that window is left completely untouched and the upgrade aborts and rolls back, rather than silently
overwriting a concurrent change.

## Troubleshooting and recovery

- **`leanlaunch doctor` reports not administrator, and a run needs a service**: re-run only that
  run elevated (`Start-Process powershell -Verb RunAs` or an elevated terminal); nothing else in
  LeanLaunch requires elevation.
- **A run exits with code `3` (`CleanupIncomplete`)**: check `result.cleanupErrors` (CLI) or the log
  panel (GUI) for which specific service/process could not be stopped, and clean it up manually if
  needed — LeanLaunch does not retry silently.
- **A run exits with code `4` (`WaitTimedOut`)**: an attributable child process the profile is
  waiting for did not exit within 24 hours; LeanLaunch preserved every resource rather than guessing.
  Investigate whether the application is still legitimately running.
- **`snapshot` or `diff` exits with code `5`**: one or more collectors failed. The snapshot/diff data
  is still saved/returned with whatever evidence succeeded; check `collectionErrors` in the output
  for which collector failed and why, then re-run once fixed.
- **Uninstall reports preserved files**: something was added to the install directory after
  install that LeanLaunch did not put there; it is left in place intentionally and listed in the
  warning so you can review it.
- **Lost track of what a classification decision meant**: every classification records the
  evidence that produced it and your note; `leanlaunch app show <name>` (or the GUI Audit tab)
  always shows both.
- **`leanlaunch app park ... On` (or the GUI's "Save idle-parking preference") didn't disable the
  service**: if the application was already `Managed`, turning idle parking on only takes effect
  the next time policy is (re-)applied — run `leanlaunch app policy <name> Managed` again (or click
  "Apply policy" in the GUI). Turning it `Off` always restores an already-parked service
  immediately, regardless of policy.
- **A Managed run refuses with "no longer matches the current audit exactly"**: the bound profile
  file no longer hashes to what was recorded when it was generated (replaced, hand-edited, or a
  rescan happened), or a hand-edited application record's classifications no longer match what the
  profile file actually contains. Regenerate the profile from the current audit and re-apply
  Managed policy.
- **`scan-after` refuses with "already been used to complete an audit"**: the active before-install
  baseline was already completed once. Capture a fresh before-install baseline (`scan-before`) to
  rescan; this also drops the application back to Unmanaged and clears any bound profile.

## Roadmap

- Validate profiles for SOLIDWORKS, Fusion, OrCAD, Lychee Slicer, and other engineering tools using captured evidence.
- Improve attribution of process trees and delayed child launchers.
- Add signed releases and a compact compiled distribution if it can retain the zero-resident principle.
- Add a native PowerToys Command Palette provider once the CLI/profile contract is proven.
- Build a reviewed community profile library with application/version metadata.

## License

MIT. See [LICENSE](LICENSE).
