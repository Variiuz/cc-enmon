# ENMON

ENMON is a distributed energy monitoring and control stack for CC: Tweaked networks. It gives you one controller for your power room, shared telemetry across attached displays and pocket computers, and coordinated update rollouts for the machines that keep the system running.

It currently supports Mekanism induction matrices, Extreme Reactors / BigReactors, Almost Reliable Energy Meter / IE current transformers, and Immersive Engineering diesel generators (Powah has no CC peripheral in the lab pack yet).

## Why ENMON

- Keep matrix storage, IO, and fill trends visible from one controller instead of checking each machine manually
- Mirror the same controller-authored data to wall displays and pocket computers
- Start and stop reactors/generators automatically using configurable matrix thresholds
- Track history without requiring every node to sample and store its own graphs
- Roll out updates across the network without manually reinstalling each computer

## Quick Start

Run this on each ComputerCraft computer that should join the network:

```lua
wget https://raw.githubusercontent.com/Variiuz/cc-enmon/master/installer.lua installer.lua
installer
```

Recommended first setup:

1. Install a controller first.
2. Pick a shared wireless channel for the network.
3. Add matrix, reactor, meter, generator, display, or pocket nodes on that same channel.
4. When multiple matching peripherals are attached, the installer asks which one to bind.
5. Adopt new non-controller nodes from the controller using their claim codes (shown after reboot).
6. Verify that the controller monitor shows live node state before enabling auto control.

The bootstrap installer lets you choose a branch first, then downloads the full setup wizard from that branch. Installed nodes keep using their chosen branch for future updates.

If `enmon.cfg` already exists, the installer can reuse it as a starting point and walk you back through the configuration pages. Changing role during install or later in the config editor force-resyncs managed files and prunes the old role package.

If `enmon.lua` starts without a config, it offers to run `installer.lua` when present, or shows the wget command to fetch it.

## Hardware By Role

| Role | What it does | Hardware |
|---|---|---|
| **Controller** | Central authority for telemetry, history, alerts, and updates | Advanced Computer + Monitor (3x2 recommended) + Ender Modem + optional Speaker |
| **Matrix Node** | Reads Mekanism induction matrix state and publishes storage telemetry | Computer + Ender Modem + wired `mekanism:induction_port` |
| **Reactor Node** | Reads reactor state and accepts bounded control commands | Computer + Ender Modem + Extreme Reactors / BigReactors Computer Port |
| **Meter Node** | Publishes FE transfer rate from Energy Meter / IE current transformer | Computer + Ender Modem + meter peripheral |
| **Generator Node** | Publishes IE diesel/capacitor state and accepts enable/disable | Computer + Ender Modem + IE diesel generator (or capacitor readout) |
| **Display Node** | Mirrors the controller-authored overview on another monitor | Computer + Monitor + Ender Modem |
| **Pocket Computer** | Mobile readout + remote ON/OFF / rod control | Pocket Computer + Ender Modem |

All nodes that belong to the same installation must share the same wireless channel.

## How It Works

ENMON uses a controller-first network model.

```text
Matrix / Meter / Reactor / Generator ----\
                                          Controller ---- Display Node
Pocket Computer (read + control) ---------/        \
                                                    \--- Alerts (speaker / redstone / webhook)
                                                    \--- Update coordination
```

- The controller collects telemetry, evaluates alerts, and stores the history series used by every view.
- Matrix, meter, reactor, and generator nodes stay focused on peripherals and transport.
- Display and pocket nodes render controller-authored data instead of sampling their own local history.
- New non-controller nodes start as `unlinked` and show a short claim code on their own screen until the controller adopts them (type the code on the controller; it is not broadcast).
- After adoption, operational traffic is authenticated with per-node tokens.

## What You Can Do With It

- Monitor induction matrix stored energy, capacity, input, output, and fill percentage
- See predicted time-to-empty / time-to-full from matrix IO rates
- Aggregate multiple matrix nodes into one combined storage view
- Show meter IO rates alongside matrix transfer
- Watch shared history lines on the controller monitor, remote displays, and pocket tabs
- See per-reactor / generator output and active state
- Toggle reactors/generators and adjust reactor rod levels from the controller or pocket
- Enable automatic reactor/generator start/stop based on low and high matrix fill thresholds
- Receive speaker, redstone, and optional Discord webhook alerts for low charge and missing nodes
- Check, offer, and coordinate node updates from the controller
- Adopt nodes by typing the claim code shown on each node screen (codes are not broadcast)

## Controller Workflow

The controller is the operational center of the system.

Typical flow:

1. Install the controller and complete its hardware bindings.
2. Add remote nodes on the same channel.
3. Adopt them from the controller once they appear as unlinked.
4. Confirm matrix and reactor telemetry is live.
5. Tune thresholds and history settings in the config editor.
6. Turn on automatic reactor control if that fits your base.

Key controller settings:

- `auto_ctrl`: enables automatic reactor/generator start and stop behavior
- `threshold_low`: matrix fill percentage that starts reactors/generators
- `threshold_high`: matrix fill percentage that stops reactors/generators
- `history_persistence_mode`: `memory_only`, `prompt_when_disk_detected`, or `disk_enabled`
- `energy_unit`: `FE` or `RF` label for FE-equivalent values
- `update_check_interval`: seconds between controller manifest checks
- `alert_redstone_side`: optional computer side that goes high while alerts are active
- `alert_webhook_url`: optional Discord-compatible webhook URL

## Operating Views And Hotkeys

### Runtime hotkeys on every node

| Key | Action |
|---|---|
| `C` | Open the config editor and relaunch this node afterward |
| `F3` | Toggle the dedicated log view |
| `Up` / `Down` | Scroll the log view |
| `PageUp` / `PageDown` | Scroll the log view faster |
| `Home` | Jump to the oldest visible log region |
| `End` | Jump back to the live tail |

### Extra controller hotkeys

| Key | Action |
|---|---|
| `F4` | Switch the attached monitor between Overview and Updates |
| `F5` | Check for updates |
| `F6` | Offer updates to eligible remote nodes |
| `F7` | Start the offered rollout |
| `F8` | Abort the active offer or rollout |
| `F9` | Self-update the controller |

## History And Energy Units

History is memory-first by design. If a disk is detected and the controller is set to `prompt_when_disk_detected`, ENMON asks once before enabling disk-backed persistence.

Matrix readings are normalized to FE-equivalent values before display. This keeps matrix telemetry aligned with the rest of a typical CC: Tweaked power room even when Mekanism reports internal Joule values differently.

The display label is configurable:

- `FE` is the default and matches Mekanism's common UI wording
- `RF` keeps the same FE-equivalent numbers and only changes the label

## Updates And Rollouts

Use the dedicated CLI entrypoint for local update operations:

- `enmon-cli update` checks the remote manifest and downloads only changed managed files
- `enmon-cli update force` re-downloads and reapplies managed files even if the semantic version is unchanged
- `enmon-cli reinstall` is an explicit alias of `update force`
- `enmon-cli verify` compares local managed files against manifest hashes and reports missing, changed, or stale files

`enmon.lua` still forwards CLI arguments to `enmon-cli.lua` for compatibility, but `enmon-cli` is the preferred interface.

The manifest also defines a rollout policy:

- `controller-first`: the controller should be reviewed or updated before normal remote rollout
- `node-safe`: remote rollout can proceed without updating the controller first

The current default policy is `controller-first`.

## Release Workflow

Use the PowerShell helper to create releases and same-version hotfixes:

```powershell
./tools/bump-version.ps1
./tools/bump-version.ps1 -Part minor
./tools/bump-version.ps1 -Version 0.4.0 -Notes "Add new reactor flow", "Tighten updater UX"
./tools/bump-version.ps1 -Hotfix -Notes "Same-version hotfix with new manifest revision"
```

The release helper updates:

- `manifest.json`
- `installer.lua`
- `installer-full.lua`
- `lib/version.lua`
- `changelog.json`

Important release rule: do not edit manifest hashes by hand. Use `./tools/bump-version.ps1` so managed file hashes and release metadata stay in sync.

## Project Status

Current release line: `0.4.0`

Recent changes in this line include:

- Shared controller-authored history across controller, display, and pocket nodes
- Pocket tab views for overview, history, and reactor detail
- Configurable history persistence mode and energy-unit label
- Hash-based updater verification and same-version hotfix support

## Screenshots And Demo

Layout reference (capture in-game when convenient; the UI is live in the codebase):

```text
Controller overview (3x2 monitor)
+--------------------------------------------------+
| ENMON Controller / Overview              12:34:56|
| ! Low charge | matrix_1 offline                  |
| [Matrix]              | [Reactors]               |
| 12.4 MFE              | reactor_1 ON  2.1k FE/t  |
| Fill 42% ETA empty 3m | Rod 40%  Fuel 88%        |
| ███▄▄▄▄▄ Recent fill  | [OFF] [R-] [R+]          |
| In +1.2k  Out -800    |                          |
+--------------------------------------------------+

Updates view (F4)
+--------------------------------------------------+
| Check | Offer | Start | Abort | Adopt/Replace    |
| Selected node claim codes are typed on terminal  |
+--------------------------------------------------+

Pocket tabs: Overview | History | Reactor detail
Setup: branch select -> role wizard -> soft peripheral check / pickers -> claim code on node screen after reboot
```

Recommended captures once available: controller overview, updates during rollout, pocket overview/history, setup/adoption flow.

## Development Notes

- There is no large automated test suite yet
- `tools/update-recovery-harness.lua` is available for updater and stale-file recovery checks
- Runtime behavior is easiest to validate in-game with a controller plus at least one matrix or reactor node
- For a ready-made Prism / NeoForge 1.21.1 test environment, use [`enmon-lab/`](enmon-lab/README.md) (import `enmon-lab/dist/ENMON-Lab-0.1.0.mrpack`)

## Contributing

Contributions are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md) for issue guidance, release rules, and workflow expectations.

## Requirements

- CC: Tweaked
- Mekanism v10+ for induction matrix telemetry
- Extreme Reactors or BigReactors for reactor telemetry and control
- HTTP enabled, with access to `raw.githubusercontent.com`

## License

This project is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

