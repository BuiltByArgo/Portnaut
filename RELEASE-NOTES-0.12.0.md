# Portnaut 0.12.0

**Install a game and play: easy mode, Will It Run?, five more launchers and Couch Mode.**

Portnaut runs Windows games on Apple silicon Macs. It keeps each launcher or game in its own bottle and picks the graphics renderer (DXMT, D3DMetal, DXVK or Wine's own) that suits each game. Free and open source, by Built by Argo. Public beta.

## What's new since 0.8.0

- **Five more launchers:** the **Epic Games Launcher**, **Battle.net**, the **Rockstar Games Launcher**, **GOG Galaxy** and **Amazon Games**, next to Steam, the EA app and Ubisoft Connect. Each installs from its publisher's own installer. Games from Epic, GOG and Amazon Games appear by themselves; Epic games start through the launcher, so they're signed in.
- **Easy mode,** on for new bottles: when you press Play, Portnaut switches the bottle to the renderer that suits the game, and backs up your saves first. Bottles from earlier versions keep working as they did until you turn it on.
- **Will It Run?** (⌘K): check about 13,000 games before you buy or download one, from Highball's open compatibility database, with anti-cheat and Linux players' results. Only games played on a Mac show as "Tested on Apple silicon". Games in your library show their verdict, and Portnaut warns you when Steam starts downloading a game that can't run.
- **Find My Best Setup:** Portnaut plays a game once on each renderer it can use, measures every round on your Mac, and keeps the fastest. Easy mode then starts the game there.
- **Couch Mode** (⇧⌘T): your library full screen for a TV, driven by a controller.
- **Automatic save backups** before every game, ten kept.
- **Launcher windows that draw:** Battle.net, Rockstar's Social Club, GOG Galaxy and Amazon Games showed blank windows under Wine on a Mac; Portnaut sets each one up to draw in software. Rockstar bottles use DXMT, because the Rockstar Games Launcher doesn't start on D3DMetal.
- **GTA V and Red Dead Redemption 2 from Steam:** Rockstar's sign-in window draws in every bottle, because these games open the Rockstar Games Launcher from Steam too. GTA V Legacy gets the launch option `-nobattleye` by itself, so its story mode can start; GTA Online needs BattlEye, which Wine can't run.

## Tested so far

Each new launcher installs and opens to its sign-in screen on an M4 Pro with macOS 27.2, and easy mode's renderer switch and save backups work in a test bottle. Not yet tried with real games: signing in and playing in the new launchers, Find My Best Setup's rounds, and Couch Mode with a controller. GTA V and Red Dead Redemption 2 haven't been played through Portnaut yet: their setup follows Highball's database, where both were played on a Mac.

Reports are very welcome: [builtbyargo@proton.me](mailto:builtbyargo@proton.me).

## Privacy

Still no account, analytics or tracking. New: when you open Component Updates, Portnaut also fetches the newest compatibility list from Highball's public database. Will It Run? and every verdict are worked out on your Mac; Portnaut never sends what you search for or play.

## Install

**You need:**
- a Mac with Apple silicon (M1 or later)
- macOS 14.6 or later
- about 3 GB of free space plus room for your games
- Rosetta

1. **Download** `Portnaut-0.12.0.zip` below, open it, and move **Portnaut** to your Applications folder. Already have Portnaut? Quit it and choose **Replace**: your bottles, games and saves stay.
2. **Open Portnaut.** It isn't notarized by Apple yet, so the first time:
   1. Open **System Settings › Privacy & Security**.
   2. Choose **Open Anyway** next to the message about Portnaut, then confirm.
3. **Choose Prepare Portnaut,** then **Bottles › New Bottle…**.

Guides and answers: [portnaut.com](https://portnaut.com).

## Check your download

```
shasum -a 256 Portnaut-0.12.0.zip
35d95bf8925b98b22a4c7e0c8af2bbe3629ed3e8353cb5aae2704814b1d4ae95
```

## Good to know

- Games with kernel-level anti-cheat don't run under Wine, and some games run only offline (GTA V's story mode, but not GTA Online); Will It Run? names a game's anti-cheat.
- DirectX 12 games need D3DMetal.
- Keep backups of saves you care about: Portnaut is in public beta.

Support: [builtbyargo@proton.me](mailto:builtbyargo@proton.me) · Support Portnaut on [Ko-fi](https://ko-fi.com/A2H229BWWV)

<sub>The compatibility list comes from Highball's database (CC0), with predictions computed from ProtonDB's Linux reports (ODbL) and anti-cheat data from Are We Anti-Cheat Yet? (MIT).</sub>
