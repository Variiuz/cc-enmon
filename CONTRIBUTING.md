# Contributing To ENMON

ENMON is maintained as a practical ComputerCraft infrastructure project. Contributions are welcome, especially fixes, documentation improvements, and careful feature work that keeps the system readable and reliable in-game.

## Before You Start

- Read [README.md](README.md) for the current product scope and operator workflow
- Open an issue before large feature work or protocol changes
- Keep changes focused; avoid mixing repo cleanup, UI work, and runtime behavior changes in one patch

## Good Contribution Targets

- Bug fixes in node runtime behavior, updater flow, or UI rendering
- Documentation improvements, screenshots, and setup walkthroughs
- Better validation and recovery behavior around config, networking, or peripherals
- Small UX improvements for controller, display, or pocket flows

## Development Expectations

- Keep changes consistent with the existing Lua style and module boundaries
- Prefer targeted fixes over broad refactors
- Preserve user-facing behavior unless the change intentionally updates it
- If you change setup, update, or operator workflows, update the documentation in the same pull request

## Release And Versioning Rules

Release metadata is script-driven.

- Do not edit manifest hashes by hand
- Use `./tools/bump-version.ps1` for semantic releases and same-version hotfixes
- If a release file needs narrow EOF or EOL cleanup after the script runs, rerun the script or otherwise bring generated metadata back into sync
- `manifest_revision` is the mechanism for same-version hotfix publishes

Relevant release-managed files:

- `manifest.json`
- `installer.lua`
- `installer-full.lua`
- `lib/version.lua`
- `changelog.json`

## Testing And Validation

There is not a full automated test suite yet, so changes should be validated deliberately.

- For updater changes, use `tools/update-recovery-harness.lua`
- For runtime or UI changes, validate with a controller and at least one real or representative node in-game
- For config changes, verify migration behavior against an existing `enmon.cfg` where possible
- For networking changes, check adoption, steady-state telemetry, and reconnect behavior

## Issues

When reporting a bug, include as much of the following as possible:

- Node role involved
- Attached peripherals and mod versions
- ENMON version or release label
- Branch if you are not on the default release branch
- What you expected to happen
- What actually happened
- Relevant runtime log output or reproduction steps

## Pull Requests

- Keep pull requests reviewable in size
- Explain the operator-facing effect of the change
- Mention any manual in-game validation you performed
- Call out protocol, manifest, or updater changes explicitly

## License

By contributing, you agree that your contributions are provided under the repository license in [LICENSE](LICENSE).
