# Profile schema

Profiles are JSON files with `schemaVersion: 1`.

- `name` — command-safe identifier: letters, numbers, dot, underscore, or hyphen. It must match the JSON filename.
- `displayName` — human-readable label.
- `executable` — exact executable path. `%ENVIRONMENT_VARIABLES%` are expanded without invoking a shell.
- `arguments` — argument strings passed to `Start-Process`.
- `workingDirectory` — optional working directory.
- `services` — exact Windows service names. LeanLaunch starts stopped entries before launching the app. It stops only services that this same run started.
- `residualProcesses` — opt-in cleanup rules with exact `name` and required `executablePath`. Only newly observed, attributable descendant processes are eligible, and creation identity is revalidated before stopping.
- `waitForProcessNames` — attributable descendant processes to wait for when a vendor launcher exits before the real application. Waiting is bounded.
- `cleanup.stopStartedServices` — default `true`.
- `cleanup.stopResidualProcesses` — default `true`.

Example:

```json
{
  "schemaVersion": 1,
  "name": "my-cad",
  "displayName": "My CAD",
  "executable": "%ProgramFiles%\\Vendor\\CAD\\cad.exe",
  "arguments": [],
  "workingDirectory": "%USERPROFILE%\\Documents",
  "services": ["ExactVendorServiceName"],
  "residualProcesses": [
    {
      "name": "vendor-helper",
      "executablePath": "%ProgramFiles%\\Vendor\\CAD\\vendor-helper.exe"
    }
  ],
  "waitForProcessNames": ["cad"],
  "cleanup": {
    "stopStartedServices": true,
    "stopResidualProcesses": true
  }
}
```

## Safety boundaries

Running a profile (`leanlaunch run`/`leanlaunch app run`) never changes a service's startup type, disables a scheduled task, removes a startup entry, or infers cleanup rules from a diff. Those are persistent system policy decisions and remain outside automatic profile execution. Profile properties are type-checked rather than silently coerced (a numeric or boolean value where an object or array is required is rejected, not coerced).

The one deliberate, opt-in exception is idle-service parking (see below): a user can explicitly ask LeanLaunch to change a specific Managed service's startup type between runs with `leanlaunch app park`. It is off by default, requires an explicit command per service, requires administrator rights, and is always reversible — it is never a side effect of running a profile.

## Application records (the audit-driven workflow)

Profiles are the low-level execution contract. Most users should build them through an
**application record** instead of hand-writing JSON — see
[the audit workflow](APP-AUDIT-WORKFLOW.md). Application records live in
`%LOCALAPPDATA%\LeanLaunch\apps\<name>.json` (schemaVersion 1) and hold:

- `policy` — `"Managed"` or `"Unmanaged"`. New applications default to `Unmanaged`; LeanLaunch takes
  no enable/disable/cleanup action at all for an `Unmanaged` application, and `leanlaunch app run`
  simply launches the executable directly.
- `profileName` — set automatically once `leanlaunch app profile <name>` writes a profile from
  reviewed resources.
- `profileAuditId`/`profileContentHash` — the audit ID and a SHA-256 hash of the exact profile bytes
  recorded at the moment the profile was generated. Enabling Managed policy and every Managed run
  both revalidate this binding immediately before acting — audit ID match, no Unreviewed candidate,
  the profile file at its one expected location still hashing to what was recorded, and the
  profile's services/residual-process rules exactly matching the current audit's Managed
  classifications — and refuse to proceed if any part no longer holds.
- `currentAudit` — the active before/after snapshot pair, the diff evidence path, and a
  `classifications` array. Each classification entry has a `key`, `resourceType`
  (`Service`/`Process`/`StartupEntry`/`ScheduledTask`), the evidence that surfaced it, and a
  `decision`. `Service`/`Process` entries accept `Unreviewed`/`Managed`/`Unmanaged`;
  `StartupEntry`/`ScheduledTask` entries only ever accept `Unreviewed`/`Reviewed` — the schema itself
  makes it impossible to ask LeanLaunch to manage an autorun entry or scheduled task. A `Service`
  entry also carries `parkWhenIdle` (default `false`), settable only while that entry is classified
  `Managed`, via `leanlaunch app park <name> <key> <On|Off>` or the GUI's idle-parking checkbox. A
  before-install baseline is single-use for completion: once `scan-after` has completed the active
  audit (`currentAudit.completedAtUtc` is set), completing it again is refused — only a fresh
  `scan-before` (which mints a new audit ID and unconditionally returns the application to
  `Unmanaged`) can supply new evidence, so new evidence and an old runnable profile/Managed policy
  can never coexist.
- `parkedServices` — bookkeeping for idle-parked services: each entry records the service's real
  `originalStartMode`, whether it was running when parking touched it (`originalWasRunning`), and
  whether it is currently `currentlyParked`, so a park/restore cycle (stop-then-disable to park;
  identity-bound-stop-if-needed, restore-then-restart-if-it-was-running to unpark) is always fully
  reversible even across process restarts.
- `auditHistory` — prior audits, archived (not deleted) each time a fresh before-install baseline is
  captured, so evidence from earlier install/update cycles is retained. A resource's classification
  decision carries forward from the most recently archived audit here when it reappears in a rescan.

Only classification entries marked `Managed` are ever written into the generated profile's
`services`/`residualProcesses`. Everything else — `Unreviewed` or `Unmanaged` — is left out.
`parkWhenIdle` is independent of profile generation: it controls whether `leanlaunch app policy
<name> Managed` also disables the service between runs, not which services the generated profile
lists. The GUI distinguishes this preference from the service's actual live parked state, which it
reads from `parkedServices` rather than `parkWhenIdle`.

Every field above is validated strictly on load — required properties, exact runtime types (no
coercion of a numeric-looking string or a stray decision outside a resource type's allowed
vocabulary), and, for `Service` entries in `currentAudit.classifications`/`parkedServices`, the same
name syntax native service control enforces. A record that fails validation is not silently dropped
from `leanlaunch app list` or the GUI — it is surfaced as an explicit "Malformed" entry so corruption
or a bad hand-edit is visible rather than hidden.
