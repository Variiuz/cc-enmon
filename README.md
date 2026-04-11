# ENMON — Energy Network Monitor

Modular ComputerCraft energy monitoring for **Mekanism Induction Matrix** and **Extreme Reactors**. (Mekanism Reactors support coming soon!)

## Install (in-game)

```
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/refs/heads/master/installer.lua installer.lua
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

## Requirements

- CC: Tweaked
- Mekanism v10+ (Induction Matrix)
- Extreme Reactors / BigReactors (optional)
- HTTP enabled + `raw.githubusercontent.com` allowed in server config
