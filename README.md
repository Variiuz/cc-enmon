# ENMON — Energy Network Monitor

Modular ComputerCraft energy monitoring for **Mekanism Induction Matrix** and **Extreme Reactors**. (Mekanism Reactors support coming soon!)

## Install (in-game)

```
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/master/installer.lua installer.lua
installer
```

Run on each computer. Pick a role, follow the wizard.

If `enmon.cfg` already exists, the installer now detects it and lets you reuse that config as a starting point before reviewing each page again.
## Node Roles

| Role | Hardware needed |
|---|---|
| **Controller** | Advanced Computer + Monitor (3×2) + Ender Modem + optional Speaker |
| **Matrix Node** | Computer + Ender Modem + wired to `mekanism:induction_port` |
| **Reactor Node** | Computer + Ender Modem + wired to Extreme Reactor CC port |
| **Display Node** | Computer + Monitor + Ender Modem |
| **Pocket Computer** | Pocket Computer + Ender Modem |

All nodes must share the same **channel** and **shared secret** configured during setup.

## Features

- Live energy stored / max / input / output from Induction Matrix
- Per-reactor status, output rate, and on/off control
- Automatic reactor on/off based on configurable matrix fill thresholds
- Speaker alerts for low energy / disconnected nodes
- HMAC-authenticated messages — foreign packets are silently dropped
- Responsive UI (adapts to monitor size)
- Peripheral check during setup wizard
- Automatic config schema migration for older `enmon.cfg` files on load/save
- Hash-based delta updates using manifest SHA-256 file hashes

## Hotkeys

### Terminal Hotkeys

All runtime terminals:

- `F2` open the config editor for this node and relaunch afterward
- `F3` toggle dedicated log view
- `Up` / `Down` scroll log view
- `PageUp` / `PageDown` scroll log view faster
- `Home` jump to oldest visible log region
- `End` jump back to live tail

Controller terminal only:

- `F4` toggle attached monitor between Overview and Updates
- `F5` check for updates
- `F6` offer updates to eligible remote nodes
- `F7` start the offered rollout
- `F8` abort the active offer/rollout
- `F9` self-update the controller

## Update Commands

- `enmon-cli update` checks the remote manifest and only downloads files whose manifest hash differs locally.
- `enmon-cli update force` re-downloads and reapplies files even when the version number did not change.
- `enmon-cli reinstall` is the explicit local alias of `update force`.
- `enmon-cli verify` compares local files against the remote manifest hashes and reports missing, changed, or stale managed files.

Normal updates trigger on a newer release label. A same-version hotfix is published by incrementing `manifest_revision`, which produces labels such as `0.3.8+r1`.

`enmon.lua` still forwards CLI arguments to `enmon-cli.lua` for compatibility, but the dedicated CLI entrypoint is now the preferred command.

## Rollout Policy

The manifest now includes an explicit `rollout_policy` field.

- `controller-first` means the controller must be reviewed/updated before normal remote node rollout is allowed.
- `node-safe` means remote node rollout can proceed without updating the controller first.

Current default: `controller-first`.

## Release Helper

Use the PowerShell helper to bump the release version and append a `changelog.json` entry:

```powershell
./tools/bump-version.ps1
./tools/bump-version.ps1 -Part minor
./tools/bump-version.ps1 -Version 0.4.0 -Notes "Add new reactor flow", "Tighten updater UX"
./tools/bump-version.ps1 -Hotfix -Notes "Same-version hotfix with new manifest revision"
```

It updates:

- `manifest.json`
- `installer.lua`
- `lib/version.lua`
- `changelog.json`

## Requirements

- CC: Tweaked
- Mekanism v10+ (Induction Matrix)
- Extreme Reactors / BigReactors (optional)
- HTTP enabled + `raw.githubusercontent.com` allowed in server config
