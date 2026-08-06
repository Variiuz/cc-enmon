# ENMON

Distributed energy monitoring and control for [CC: Tweaked](https://tweaked.cc/) networks.

One **controller** owns telemetry, history, alerts, and update rollouts. Matrix, meter, reactor, and generator nodes publish peripheral state. Displays and pocket computers mirror controller-authored views.

## Support Matrix

| System | Role | Status | Notes |
|---|---|---|---|
| Mekanism induction matrix | `matrix` | Supported | Wired `mekanism:induction_port` (aliases accepted) |
| Extreme Reactors / BigReactors | `reactor` | Supported | Computer / access port; ON/OFF + rod control |
| Almost Reliable Energy Meter | `meter` | Supported | Peripheral type `energymeter` |
| Immersive Engineering current transformer | `meter` | Supported | `current_transformer` / IE aliases |
| Immersive Engineering diesel generator | `generator` | Supported | Enable/disable when the peripheral exposes it |
| Immersive Engineering capacitors | `generator` | Supported | Readout only (passive) |
| Powah | — | Not supported | No CC peripheral API in current packs |
| Flux Networks | — | Not supported | No native CC peripheral |
| RFTools Utility | — | Not supported | No native CC peripheral |

**Always required:** CC: Tweaked, HTTP enabled, ender modem on every node, access to `raw.githubusercontent.com`.

| Role | Computer | Extra hardware |
|---|---|---|
| Controller | Advanced Computer | Monitor (3×2 recommended), optional speaker |
| Matrix / Reactor / Meter / Generator | Computer | Matching peripheral from the table above |
| Display | Computer | Monitor |
| Pocket | Pocket Computer | Ender modem only |

All nodes in one install must share the **same wireless channel**.

## How To Install

### Prerequisites

- HTTP enabled for ComputerCraft
- Install the **controller first**, then other roles
- Pick one channel and stick to it (default `42` is fine)

### Install a computer

```lua
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/master/installer.lua installer.lua
installer
```

Wizard flow:

1. **Branch** — Stable (`master`) unless you want Development / custom
2. **Reuse or fresh** — only if `enmon.cfg` already exists
3. **Role** — controller, matrix, reactor, meter, generator, display, or pocket
4. **Peripheral check** — soft warnings; you can continue if gear is missing
5. **Pickers** — only when several matching modems/devices are attached
6. **Network** — node ID + channel
7. **Role settings** — controller also sets auto-control, update interval, energy label, history mode
8. **Review → Install** — downloads files, writes `enmon.cfg` + `startup.lua`
9. **Reboot** when prompted

If `enmon` starts with no config, press **I** to run `installer.lua` when present (otherwise the screen shows the wget command).

### Bring up the network

1. Finish the **controller** and confirm the monitor HUD is up.
2. Install other nodes on the **same channel**.
3. After reboot, non-controller nodes show **Unlinked** and a short **claim code** on their own screen.
4. On the controller, open the Updates view (`F4`), select the unlinked node, choose **Adopt**, and type that claim code on the controller terminal.
5. Codes are typed on the controller; they are not broadcast over the modem.
6. Confirm live telemetry, then enable auto-control if you want it.

**Replace** uses the same claim-code prompt when a computer was rebuilt but should take an existing node slot.

Recommended order: controller → matrix (and meters) → reactor / generator → display / pocket → adopt each non-controller.

### Day-to-day

| Key | Where | Action |
|---|---|---|
| `C` | Any node | Config editor, then relaunch |
| `F3` | Any node | Toggle log view (`Up`/`Down`/`PgUp`/`PgDn`/`Home`/`End` to scroll) |
| `F4` | Controller | Switch monitor Overview ↔ Updates |
| `F5` | Controller | Check for updates |
| `F6` | Controller | Offer updates to eligible nodes |
| `F7` | Controller | Start offered rollout |
| `F8` | Controller | Abort offer / rollout |
| `F9` | Controller | Controller self-update |

Useful config fields (`C`):

- Channel, node ID, modem / monitor / speaker
- Bound device name for matrix/reactor/meter/generator (`blank` = auto-find)
- Controller thresholds, `energy_unit` (`FE`/`RF`), `history_persistence_mode`
- Optional `alert_redstone_side` and Discord `alert_webhook_url`

Changing **role** in the config editor is supported: Save resyncs that role’s files, then press Launch. Re-adopt if the node was linked.

## Updates

### From the controller (preferred for a live network)

1. `F5` — check the manifest
2. Review the Updates view (`F4`)
3. `F9` if the controller itself needs updating first (default policy is controller-first)
4. `F6` — offer to eligible remote nodes
5. `F7` — start the rollout (`F8` to abort)

### On one computer

```text
enmon-cli update          Check and apply changed managed files
enmon-cli update force    Reapply managed files even if the version matches
enmon-cli reinstall       Alias of update force
enmon-cli verify          Report missing / changed / stale managed files
```

`enmon update …` still forwards to `enmon-cli` for compatibility.

Installed nodes keep the branch chosen at install (`enmon-source.json`) for future pulls. To change branch, re-run the installer bootstrap and pick again.

## Troubleshooting

| Symptom | What to check |
|---|---|
| Installer exits immediately / download fails | HTTP enabled; `raw.githubusercontent.com` reachable; retry from the install log |
| Hash / Basalt download fails | Re-run installer on the same branch; if it persists, the release hashes may be stale—use a known-good branch or wait for a hotfix |
| “Configuration Missing” | Press **I** if `installer.lua` exists, or wget it again |
| Node stuck **Unlinked** | Same channel as controller; ender modem attached; adopt with the claim code shown on **that** node’s screen |
| Adopt rejected / no effect | Type the code carefully; use **Replace** if the computer ID changed for an existing slot |
| No matrix / reactor / meter data | Peripheral attached and powered; if several match, set Bound peripheral in config or re-run the installer picker |
| Controller HUD empty | Monitor side correct; at least one node adopted and online |
| Auto-control not firing | `auto_ctrl` on; low threshold below high; matrix fill updating; reactors/generators controllable |
| Pocket can’t control | Pocket adopted; target reactor/generator online on the controller |
| Updates never offered | Controller updated first under controller-first policy; remote node online and eligible |
| After role change, wrong files / crash | Save role in config editor (force resync), Launch, then re-adopt if needed—or re-run `installer` / `enmon-cli reinstall` |

Soft install checks mean a node can install without all hardware present; it will wait or warn at runtime until peripherals appear.

## How It Works (short)

```text
Matrix / Meter / Reactor / Generator ----\
                                          Controller ---- Display
Pocket (read + control) ------------------/        \
                                                    \--- Alerts / updates
```

- Controller collects telemetry, history, and alerts
- Sensor nodes talk to peripherals only
- Display / pocket render controller-authored data
- Adoption uses out-of-band claim codes; later traffic uses per-node tokens

History is memory-first. With `prompt_when_disk_detected`, the controller asks once if a disk is present. Matrix values are shown as FE-equivalent numbers; `energy_unit` only changes the FE/RF label.

## Development

- Lab pack: [`enmon-lab/`](enmon-lab/README.md)
- Release helper: `./tools/bump-version.ps1` (do not edit manifest hashes by hand)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)

Current release line: `0.4.0`

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
