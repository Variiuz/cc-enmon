# ENMON — Energy Network Monitor

Modular ComputerCraft energy monitoring for **Mekanism Induction Matrix** and **Extreme Reactors**. (Mekanism Reactors support coming soon!)

## Install (in-game)

```
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/master/installer.lua installer.lua
installer
```

Run on each computer. Pick a role, follow the wizard.

The bootstrap `installer.lua` now lets you choose a branch first, then downloads the full installer wizard from that branch. The installed node keeps using that branch for later updates through its local branch selection file rather than `manifest.json`.

If `enmon.cfg` already exists, the installer now detects it and lets you reuse that config as a starting point before reviewing each page again.

Controller setup now only needs the node identity, channel, and controller-specific hardware/settings. New non-controller nodes on the same channel come up as `unlinked`, advertise a short claim code, and must be explicitly adopted from the controller before they start sending operational data.

## Node Roles

| Role | Hardware needed |
|---|---|
| **Controller** | Advanced Computer + Monitor (3×2) + Ender Modem + optional Speaker |
| **Matrix Node** | Computer + Ender Modem + wired to `mekanism:induction_port` |
| **Reactor Node** | Computer + Ender Modem + wired to Extreme Reactor CC port |
| **Display Node** | Computer + Monitor + Ender Modem |
| **Pocket Computer** | Pocket Computer + Ender Modem |

All nodes that should work together must share the same **channel**. Non-controller nodes no longer need a manually entered shared secret or controller ID during setup.

## Features

- Live induction matrix stored / max / input / output normalized to FE-equivalent values
- Controller-authored history graphs on controller monitor, display node, and pocket tabs
- In-memory rolling history with optional disk-backed persistence after operator approval
- Per-reactor status, output rate, temperatures, rod level, and bounded control surfaces
- Automatic reactor on/off based on configurable matrix fill thresholds
- Speaker alerts for low energy / disconnected nodes
- Explicit controller adoption flow for new nodes
- Per-node token-authenticated operational messages after adoption
- Responsive UI (adapts to monitor size)

## Hotkeys

### Terminal Hotkeys

All runtime terminals:

- `C` open the config editor for this node and relaunch afterward
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

## 0.4.0 Runtime Notes

- Controller, display, and pocket all render the same controller-authored history series rather than sampling locally.
- Pocket now uses tabbed views for Overview, History, and Reactor detail.
- History persistence is memory-first. If a disk is detected and the controller is set to `prompt_when_disk_detected`, ENMON asks once before enabling disk-backed history.
- The controller config editor now exposes `History persistence` and `Energy unit label` settings.
- Matrix values are normalized to FE-equivalent numbers before display. The display unit label defaults to `FE` and can be changed to `RF` in the controller config editor.

## Update Commands

- `enmon-cli update` checks the remote manifest and only downloads files whose manifest hash differs locally.
- `enmon-cli update force` re-downloads and reapplies files even when the version number did not change.
- `enmon-cli reinstall` is the explicit local alias of `update force`.
- `enmon-cli verify` compares local files against the remote manifest hashes and reports missing, changed, or stale managed files.
- `enmon-cli update` and `reinstall` prompt before applying changes; pass `--yes` to skip confirmation.
- `tools/update-recovery-harness.lua` exercises interrupted update recovery and stale managed-file cleanup inside a temporary test workspace.

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
- `installer-full.lua`
- `lib/version.lua`
- `changelog.json`

Release rule: do not edit manifest hashes by hand. Use `./tools/bump-version.ps1` for both semantic releases and same-version hotfix revisions so manifest hashes are generated consistently from the script.

Exception: a manual follow-up is acceptable for a narrow EOF/EOL normalization fix when a release file needs line-ending cleanup after the script runs. In that case, rerun the bump flow or otherwise bring the script-generated metadata back into sync instead of maintaining hand-edited hashes as the steady-state process.

## Energy Units

Mekanism induction matrix readings are normalized to FE-equivalent values before ENMON displays them. This avoids the common Joules-vs-FE mismatch where matrix input/output appears roughly `2.5x` higher than the reactor output feeding it.

The controller config editor exposes an `Energy unit label` field:

- `FE` is the default and matches the in-game Mekanism display.
- `RF` keeps the same FE-equivalent numbers but changes the label for packs or players that still prefer RF wording.

## Requirements

- CC: Tweaked
- Mekanism v10+ (Induction Matrix)
- Extreme Reactors / BigReactors (optional)
- HTTP enabled + `raw.githubusercontent.com` allowed in server config
