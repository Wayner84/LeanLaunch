# PowerToys Command Palette

LeanLaunch is intentionally a normal command rather than a resident launcher. Its installer adds one small command shim to your **user PATH** and does not add an autorun entry.

## Setup

1. From the repository, run:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
2. Open a new terminal and verify:
   ```text
   leanlaunch doctor
   ```
3. Restart PowerToys/Command Palette if it was open while PATH changed.

## Launching

Use the Command Palette facility/extension that executes shell commands, then enter:

```text
leanlaunch run solidworks
```

or, for an application registered through the audit workflow (policy-aware — respects the
Managed/Unmanaged toggle automatically):

```text
leanlaunch app run solidworks
```

LeanLaunch performs a dry-run preflight before a real launch. If—and only if—the plan proves that a
stopped Windows service must be started, Windows shows a UAC approval prompt and the complete run is
moved into one elevated supervisor process. Unmanaged applications and managed applications whose
required services are already running launch without elevation.

The profile/application name is deliberately command-friendly. Other useful entries are:

```text
leanlaunch list
leanlaunch app list
leanlaunch run solidworks --dry-run
leanlaunch snapshot before-fusion
leanlaunch gui
```

`leanlaunch gui` opens the desktop window for reviewing audits and toggling policy; it is a normal
process like any other command and exits completely when the window is closed — nothing stays
resident in either case.

If your Command Palette setup only indexes shortcuts rather than arbitrary shell commands, create a normal Windows shortcut whose target is:

```text
%LOCALAPPDATA%\Programs\LeanLaunch\bin\leanlaunch.cmd run solidworks
```

or, to open the GUI from a shortcut/tile:

```text
%LOCALAPPDATA%\Programs\LeanLaunch\bin\leanlaunch.cmd gui
```

Pin/index that shortcut in the palette. This does not make LeanLaunch resident; it starts only when selected.

## Why no custom palette plugin yet?

A custom Command Palette extension would increase packaging and maintenance before the core audit/cleanup model has been validated against real engineering applications. The stable CLI is the integration boundary: a native palette provider can call the same command later without changing profiles.
