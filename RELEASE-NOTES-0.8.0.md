# Portnaut 0.8.0

**New name, new look, and the full source code.**

Portnaut runs Windows games on Apple silicon Macs. It keeps each launcher or game in its own bottle and
recommends the graphics renderer (DXMT, D3DMetal, DXVK or Wine's own) that suits each game. Free and
open source, by Built by Argo. Early access.

## What's new

- **Portnaut:** a new name and a new icon, the gamepad planet.
- **A new look:**
  - deep-space colours with rocket-orange buttons
  - rounded headings
  - starry scenery for games without their own artwork
- **The full source code** is now in this repository, under the MIT licence. It builds with Apple's
  Command Line Tools; Xcode isn't needed. See *Build from source* in the README.
- **Build scripts** now build inside the repository (`build/`, `release-assets/`).

Everything else works as before:
- bottles for Steam, the EA app and Ubisoft Connect
- renderer recommendations
- per-game settings
- controllers
- Windows components
- snapshots and save backups
- performance records
- component updates

## Install

**You need:**
- a Mac with Apple silicon (M1 or later)
- macOS 14.6 or later
- about 3 GB of free space plus room for your games
- Rosetta

1. **Download** `Portnaut-0.8.0.zip` below, open it, and move **Portnaut** to your Applications folder.
2. **Open Portnaut.** It isn't notarized by Apple yet, so the first time:
   1. Open **System Settings › Privacy & Security**.
   2. Choose **Open Anyway** next to the message about Portnaut, then confirm.
3. **Choose Prepare Portnaut,** then **Bottles › New Bottle…**.

Guides and answers: [portnaut.com](https://portnaut.com).

## Check your download

```
shasum -a 256 Portnaut-0.8.0.zip
1e5f14000a7438b7224a69842ae75f1e138571ec32b02fa8a6f46bf8fe7ea2b3
```

## Good to know

- Games with kernel-level anti-cheat don't run under Wine.
- DirectX 12 games need D3DMetal.
- Keep backups of saves you care about: Portnaut is early access.

Support: [builtbyargo@proton.me](mailto:builtbyargo@proton.me) · Support Portnaut on
[Ko-fi](https://ko-fi.com/A2H229BWWV)
