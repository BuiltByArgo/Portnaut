#!/bin/bash
# Refreshes the compatibility data shipped inside Portnaut.app from Highball's public database
# (https://github.com/gauthierpiarrette/highball-db): curated games (CC0), predictions from ProtonDB
# reports (ODbL) and the anti-cheat map (MIT, from Are We Anti-Cheat Yet?), with their licences.
set -euo pipefail
project="$(cd "$(dirname "$0")/.." && pwd)"
out="$project/Compatibility"
raw="https://raw.githubusercontent.com/gauthierpiarrette/highball-db/main/db"
mkdir -p "$out"
fetch() { curl -fsSL --retry 2 -o "$out/$2.tmp" "$1" && mv "$out/$2.tmp" "$out/$2"; }
fetch https://gethighball.com/data/games.json games.json
# Keep only what Portnaut reads (CC0 allows it): each game's id, title, status, Steam app id, renderer,
# anti-cheat names and verdict, and page link. Notes and provenance are left out; instead, a player-
# reported game whose notes say it doesn't start or isn't playable gets "reportsProblems", by the rule
# in CompatibilityReport.reportsProblems (keep the two in step).
python3 -I - "$out/games.json" <<'PY_TRIM'
import json, re, sys
path = sys.argv[1]
POSITIVE = ["playable with", "runs ", "runs.", "gets in game", "is playable", "plays ", "playable on", "reaches gameplay", "works "]
NEGATIVE = ["does not start", "doesn't start", "does not run", "doesn't run", "not playable", "won't start", "fails to start", "never opens", "does not launch", "doesn't launch"]
def reports_problems(notes):
    sentences = re.split(r"(?<=[.!?])\s+", (notes or "").strip().lower())[:2]
    if not sentences or not sentences[0] or any(word in sentences[0] for word in POSITIVE):
        return False
    return any(word in " ".join(sentences) for word in NEGATIVE)
data = json.load(open(path))
keep = ("id", "title", "status", "steam_appid", "renderer", "url")
games = []
for game in data["games"]:
    trimmed = {key: game[key] for key in keep if game.get(key) is not None}
    if game.get("status") in ("community", "reported-upstream") and reports_problems(game.get("notes")):
        trimmed["reportsProblems"] = True
    cheat = game.get("anticheat")
    if isinstance(cheat, dict):
        trimmed["anticheat"] = {key: cheat[key] for key in ("names", "macVerdict") if key in cheat}
    games.append(trimmed)
header = {key: data[key] for key in ("license", "license_url", "source", "generated", "count") if key in data}
header["note"] = "Trimmed by Portnaut to the fields it reads; the full data is at the source above."
json.dump({**header, "games": games}, open(path, "w"), indent=1, ensure_ascii=False)
PY_TRIM
fetch "$raw/derived/derived.json" derived.json
fetch "$raw/anticheat.json" anticheat.json
fetch "$raw/LICENSE" LICENSE-games-CC0.txt
fetch "$raw/derived/LICENSE" LICENSE-derived-ODbL.txt
fetch "$raw/anticheat.LICENSE" LICENSE-anticheat-MIT.txt
ls -l "$out"
