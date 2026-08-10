#!/usr/bin/env python3
"""Rebuilds index.json from every scripts/<language>/<slug>/manifest.json.

The index is what the website fetches to draw the library list — one file
instead of one API request per folder. Run from the repo root (CI does).
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ("razor", "lua", "vscript")


def main() -> int:
    scripts = []
    errors = []

    for lang in LANGUAGES:
        lang_dir = ROOT / "scripts" / lang
        if not lang_dir.is_dir():
            continue
        for script_dir in sorted(p for p in lang_dir.iterdir() if p.is_dir()):
            manifest_path = script_dir / "manifest.json"
            if not manifest_path.is_file():
                errors.append(f"{script_dir}: missing manifest.json")
                continue
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                errors.append(f"{manifest_path}: invalid JSON ({exc})")
                continue

            latest = manifest.get("latest")
            versions = manifest.get("versions") or []
            latest_entry = next((v for v in versions if v.get("version") == latest), None)
            if latest_entry is None:
                errors.append(f"{manifest_path}: latest '{latest}' not in versions")
                continue
            latest_file = script_dir / latest_entry["file"]
            if not latest_file.is_file():
                errors.append(f"{manifest_path}: file '{latest_entry['file']}' missing")
                continue

            entry = dict(manifest)
            entry["id"] = f"{lang}/{script_dir.name}"
            entry["dir"] = f"scripts/{lang}/{script_dir.name}"
            entry["size"] = latest_file.stat().st_size
            scripts.append(entry)

    if errors:
        for line in errors:
            print(f"ERROR: {line}", file=sys.stderr)
        return 1

    scripts.sort(key=lambda s: s["id"])
    index = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "count": len(scripts),
        "scripts": scripts,
    }
    out = ROOT / "index.json"
    out.write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"index.json: {len(scripts)} scripts")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
