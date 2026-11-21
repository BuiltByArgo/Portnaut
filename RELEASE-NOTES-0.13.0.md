# Portnaut 0.13.0

**Portnaut now updates itself, and setting up a game is one menu away.**

Portnaut runs Windows games on Apple silicon Macs. It keeps each launcher or game in its own bottle and picks the graphics renderer that suits each game. Free and open source, by Built by Argo. Public beta.

## What's new

- **Updates inside Portnaut.** Click **Check for Updates** in the sidebar, or use the About page or the Portnaut menu. Portnaut checks this GitHub page for a newer release and installs it with one click. You can let it check once a day. Updates are signed by Built by Argo and checked before they install, and an update waits until your games have closed. This is the last version you need to download by hand.
- **Set Up, in Will It Run?** After searching a game, choose **Set Up** and pick where you have it: Steam, Epic, GOG, EA, Ubisoft, Battle.net, Rockstar or Amazon. Portnaut uses that store's bottle, or makes one, and installs or opens the store, so you can install the game there.
- **"Players report problems".** Games that Mac players report not starting, or not playable, now say so in Will It Run? and the Library, instead of "Players report it runs". Highball’s list of curated games, the ones with Mac results, has grown from 674 to 909.
- **Settings** (⌘,): the Windows version new bottles start with, whether they record performance, a button to turn performance recording off in every bottle, and cover art.
- **Cover art** for Steam games in the Library and Couch Mode, from the copies Steam keeps on your Mac. Downloading missing ones from Steam is a switch in Settings, off unless you turn it on.
- **Clearer problem reports.** Logs now say how each program ended. A diagnostics report no longer fills up with graphics driver details. If an installer closes straight away in a Windows 7 or 8.1 bottle, Portnaut suggests trying Windows 10.
- The header now says **Public beta**, as the website does.

## Tested so far

On an M4 Pro with macOS 27.2: updating from one test version to the next, from a GitHub-style release, including while a game was running (the update waited until it closed). Also tested: Set Up installing Steam, Settings, cover art, and the new problem verdicts. Not yet tried: an update through this real GitHub page, which the next release will be the first to use.

Reports are very welcome: [builtbyargo@proton.me](mailto:builtbyargo@proton.me).

## Privacy

Still no account, analytics or tracking. New:
- **Updates:** Portnaut asks GitHub whether a newer version exists when you click Check for Updates, or once a day if you allow it. It sends nothing about your Mac.
- **Cover art downloads:** only if you turn them on in Settings, Portnaut fetches missing cover art for your Steam games from Steam's image server, so Valve sees which games' images were asked for.

## Install

**You need:**
- a Mac with Apple silicon (M1 or later)
- macOS 14.6 or later
- about 3 GB of free space plus room for your games
- Rosetta

1. **Download** `Portnaut-0.13.0.zip` below, open it, and move **Portnaut** to your Applications folder. Have 0.12.0 or earlier? Quit it and choose **Replace**: your bottles, games and saves stay. From now on, Portnaut updates itself.
2. **Open Portnaut.** It isn't notarized by Apple yet, so the first time:
   1. Open **System Settings › Privacy & Security**.
   2. Choose **Open Anyway** next to the message about Portnaut, then confirm.
3. **Choose Prepare Portnaut,** then **Bottles › New Bottle…**, or search a game in **Will It Run?** and choose **Set Up**.

Guides and answers: [portnaut.com](https://portnaut.com).

## Check your download

```
shasum -a 256 Portnaut-0.13.0.zip
2fc9d7a0d7449e41be1172ba53d66d22997668d7fae6cd973c4e9e2bfcd1807b
```

## Good to know

- Games with kernel-level anti-cheat don't run under Wine, and some games run only offline (GTA V's story mode, but not GTA Online). Will It Run? names a game's anti-cheat.
- DirectX 12 games need D3DMetal.
- Keep backups of saves you care about: Portnaut is in public beta.

Support: [builtbyargo@proton.me](mailto:builtbyargo@proton.me) · Support Portnaut on [Ko-fi](https://ko-fi.com/A2H229BWWV)

<sub>The compatibility list comes from Highball's database (CC0), with predictions computed from ProtonDB's Linux reports (ODbL) and anti-cheat data from Are We Anti-Cheat Yet? (MIT). Portnaut's updates use Sparkle (MIT).</sub>
