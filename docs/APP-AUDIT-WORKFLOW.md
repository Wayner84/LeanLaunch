# Auditing one application

Audit **one installer at a time**. Do not assume every process, service, startup entry, or
scheduled task that appears is safe to disable — LeanLaunch never assumes that for you either. This
guide uses **Microsoft Office** as the first application you audit after installing LeanLaunch,
because it is a realistic, widely available "heavy" application with vendor background components
worth reviewing. The same steps apply to any other application.

You can do all of this from the CLI, the desktop GUI (`leanlaunch gui`), or a mix of both — they
share the same underlying application records, so switching between them mid-audit is safe.

## Why "applications" instead of raw snapshots

Earlier in this document you may see references to `leanlaunch snapshot`/`leanlaunch diff` directly.
That low-level pair still exists (see the bottom of this document), but for real audits use the
**application** workflow (`leanlaunch app ...`). An application record:

- enforces a **fresh** before-install baseline every time you start a new audit (you cannot
  accidentally diff against a stale or reused snapshot);
- keeps every resource the diff discovered as retained evidence, together with your review decision
  and note, so the audit trail survives restarts;
- carries one explicit **policy toggle** — `Managed` or `Unmanaged` — and refuses to take any
  enable/disable/cleanup action at all while `Unmanaged`;
- turns only the resources you explicitly mark `Managed` into a profile. Anything left `Unreviewed`
  or marked `Unmanaged` is never included.

## 1. Create the application record

Before installing anything:

```text
leanlaunch app new office --exe "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE" --display-name "Microsoft Office"
```

New applications default to **Unmanaged** — LeanLaunch takes no action on them until you explicitly
review evidence and switch the policy.

## 2. Before-install baseline

Close unrelated applications first so the comparison is quieter, then capture the baseline. This
always takes a brand-new snapshot; there is no way to point it at an old one, so the baseline is
guaranteed fresh for this install:

```text
leanlaunch app scan-before office
```

## 3. Install, but do not optimize yet

Install Office normally. Note any installer choices concerning telemetry, update behavior (Office
uses "Click-to-Run", which runs its own background updater/service), licensing/activation, file
sync (OneDrive), or startup behavior. Reboot if prompted, then let the machine settle for a minute
or two before the next step.

## 4. Post-install scan and diff

```text
leanlaunch app scan-after office
```

This captures a fresh "after" snapshot, computes the diff against the exact baseline from step 2,
and stores the full diff as evidence under your LeanLaunch data directory
(`%LOCALAPPDATA%\LeanLaunch\audits`). Every new/changed service, every process group whose instance
count increased, and every newly added startup entry or scheduled task becomes a **classification
candidate** you must explicitly review — nothing is pre-decided for you, and collector errors are
surfaced rather than treated as "no changes."

## 5. Review and classify every candidate

```text
leanlaunch app show office
```

lists every candidate with its evidence. For each one, decide:

```text
leanlaunch app classify office "Service|clicktorunsvc" Managed --note "Only needed while Office runs; observed starting only on first launch"
leanlaunch app classify office "Process|officeclicktorun|c:\program files\...\officeclicktorun.exe" Unmanaged --note "Shared Click-to-Run licensing/update helper; leave alone"
leanlaunch app classify office "StartupEntry|hkcu|officebackgroundtaskhandlerregistration" Reviewed --note "Vendor background task registration; leave to Office's own settings"
```

Decision vocabulary depends on the resource type, and this is enforced by LeanLaunch itself, not
just convention:

- **Service** or **Process**: `Managed` (LeanLaunch may start/stop it for this run only),
  `Unmanaged` (never touched), or leave `Unreviewed`.
- **StartupEntry** or **ScheduledTask**: `Reviewed` or `Unreviewed` only. LeanLaunch **cannot** be
  asked to disable a startup entry or scheduled task — attempting to classify one `Managed` is
  rejected outright. If a vendor updater or background task should be controlled, do that in the
  vendor's own settings or Task Scheduler, not through LeanLaunch.

Never mark shared licensing, hardware, security, database, indexing, or sync services `Managed`
unless you have independently confirmed nothing else on the machine depends on them.

Everything you have not classified is `Unreviewed` and will simply be left out of the profile — an
unreviewed resource can never accidentally become a controlled one.

## 6. Build the profile from what you reviewed

```text
leanlaunch app profile office
```

This writes `%LOCALAPPDATA%\LeanLaunch\profiles\office.json` from the complete reviewed policy
(executable, arguments, working directory, service/residual rules, wait rules, and cleanup flags) and
binds Managed execution to those exact serialized bytes. Open it to review it against
[the profile schema](PROFILE-SCHEMA.md), but do not hand-edit a bound profile: any byte or policy change
invalidates the binding and LeanLaunch fails closed. Make the desired application/audit change and
regenerate the profile instead.

## 6a. Optional: park a Managed service while it is idle

For a service you classified `Managed` and confirmed is safe to stop, you can additionally opt it
into **idle parking** so LeanLaunch disables it whenever the application is not actually running,
rather than only stopping it after each launch:

```text
leanlaunch app park office "Service|clicktorunsvc" On
```

or, in the GUI, select the service's row in the classification grid, check "Park when idle
(services only)", and click "Save idle-parking preference".

Turning parking `On` takes effect the next time the application's policy is (re-)applied as
`Managed` — if the application is already `Managed`, run `leanlaunch app policy office Managed`
again (or click "Apply policy" in the GUI) to actually park the service. Turning it `Off` has the
opposite, immediate behavior: if the service is currently parked, LeanLaunch identity-bind-stops it
if it is running and restores its recorded original start mode right away, regardless of the
application's policy, so a service is never left disabled longer than you asked for; the service
change and the persisted record are written as one step, so a failure partway through can never
leave the two disagreeing about whether the service is still parked. Idle parking requires
administrator rights to activate or to restore a live-parked service, and each managed run also
temporarily restores a parked service for its own duration before re-parking it afterward — re-
parking only ever proceeds once the service is confirmed stopped, so `--keep-services`,
`--no-cleanup`, a preserved timeout, or a cleanup failure that leaves it running never strand it
running but Disabled. The GUI's classification grid shows this preference ("Park pref.") and the
service's actual live state ("Parked now") as two separate columns, since the preference alone does
not mean the service is currently parked — activation is deferred until policy is next applied.
Leave a service's parking preference at its default (off) unless you specifically want it disabled
between runs.

## 7. Turn management on, preview, then run

```text
leanlaunch app policy office Managed
leanlaunch app run office --dry-run
```

Read the plan: which services will be started, which are already running (and therefore left
alone), and which residual-process rules apply. Only after reviewing it:

```text
leanlaunch app run office
```

If you decide Office should just launch normally with no LeanLaunch involvement, leave (or set) the
policy back to `Unmanaged` — `leanlaunch app run office` will then simply start the executable and
take no other action at all.

## 8. Using the GUI instead

`leanlaunch gui` opens a desktop window over the same application records: an application list on
the left, and on the right an Overview tab (policy toggle, safety warnings, dry-run/action plan,
launch) and an Audit tab (before/after scan buttons, the classification grid, idle-parking
preference, and "build profile"). Nothing here is resident — closing the window ends the process,
exactly like any other command, and closing it mid-scan cancels/drains/disposes that scan first
rather than leaving the process waiting on a slow or hung collector. Any adapter injected for
testing (never used in a normal install) reaches every one of these actions identically to the CLI.

## 9. Re-auditing after an update

If Office (or any audited application) is updated later, start a new before-install baseline
(`leanlaunch app scan-before office` again). This archives the previous audit's evidence rather than
deleting it, mints a brand-new audit identity, and immediately drops the application back to
Unmanaged with any bound profile cleared, so a Managed policy or generated profile can never
silently keep running against evidence a rescan has since superseded. The new classification pass
carries forward the immediately preceding audit's decision for any resource that reappears, so you
are only reviewing what is actually new. Note that `scan-after` can only complete a given
before-install baseline once — if you need to capture different after-install evidence, start over
with a fresh `scan-before` rather than re-running `scan-after` against the same baseline.

## Low-level: a single before/after snapshot pair without an application record

For quick one-off comparisons that do not need policy tracking:

```text
leanlaunch snapshot before-solidworks
# install one application, then launch it once
leanlaunch snapshot after-solidworks
leanlaunch diff before-solidworks after-solidworks
```

Then create a profile by hand with `leanlaunch profile init <name> --exe <path>` and edit it
directly, following [the profile schema](PROFILE-SCHEMA.md).

## Sharing a profile safely

Before contributing a profile, remove machine-specific paths, document application/version
assumptions, and explain how every service/process rule was identified. Profiles — and application
audit records — are reviewable evidence, not universal truth.
