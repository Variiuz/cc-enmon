# ENMON — Energy Network Monitor

Modular ComputerCraft energy monitoring for **Mekanism Induction Matrix** and **Extreme Reactors**. (Mekanism Reactors support coming soon!)

## Install (in-game)

```
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/master/installer.lua installer.lua
installer
```

Run on each computer. Pick a role, follow the wizard.
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

## Hotkeys

### Terminal Hotkeys

All runtime terminals:

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
- `F10` toggle force-update mode for the next check/offer/start/self-update

## Update Commands

- `enmon update` checks the remote manifest and updates only when the remote version is newer.
- `enmon update force` re-downloads and reapplies files even when the version number did not change.

Force mode on the controller exists for the same reason: if you changed files without bumping the manifest version, you can still re-offer and reapply the build.

## Requirements

- CC: Tweaked
- Mekanism v10+ (Induction Matrix)
- Extreme Reactors / BigReactors (optional)
- HTTP enabled + `raw.githubusercontent.com` allowed in server config
