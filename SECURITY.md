# Security policy

## Supported versions

Only the [latest release](https://github.com/NorseGaud/SiliconCellar/releases/latest) gets security fixes. Update to the latest release before you send a report.

## Report a vulnerability

Do not open a public issue for a security problem.

Use [private vulnerability reporting](https://github.com/NorseGaud/SiliconCellar/security/advisories/new). In the report, include:

- The Silicon Cellar version and the macOS version
- The steps that cause the problem
- The effect of the problem

You will get a reply in 7 days. When a fix is available, we publish an advisory and a new release.

## Scope

In scope:

- The Silicon Cellar app and its scripts
- The files in `Sources/SiliconCellarCore/Fixes` that the app installs into game folders
- The downloads that the app does and their SHA-256 checks
- The GitHub workflows of this repository
- The Wine Engine that the app bundles ([NorseGaud/wine](https://github.com/NorseGaud/wine))

Report problems in a game, in Steam, or in a third-party fix to its owner.
