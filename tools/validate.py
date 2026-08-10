#!/usr/bin/env python3
"""Pull-request validation: checks that every touched script folder is
structurally sound. This is a status check for the reviewer — merging is
always a manual decision, so problems FAIL loudly and oddities only WARN.

Usage: python tools/validate.py --base origin/main
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = {"razor": ".razor", "lua": ".lua", "vscript": ".vscript"}
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")
CATEGORIES = {"combat", "crafting", "farming", "training", "trading", "utility", "helpers"}
REQUIRED_KEYS = {
    "name", "slug", "language", "author", "description",
    "category", "tags", "created", "updated", "latest", "versions",
}

errors: list[str] = []
warnings: list[str] = []


def changed_files(base: str) -> list[str]:
    out = subprocess.check_output(
        ["git", "diff", "--name-only", f"{base}...HEAD"], cwd=ROOT, text=True
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def check_manifest(lang: str, slug: str) -> None:
    script_dir = ROOT / "scripts" / lang / slug
    manifest_path = script_dir / "manifest.json"
    where = f"scripts/{lang}/{slug}"

    if not manifest_path.is_file():
        errors.append(f"{where}: manifest.json is missing")
        return
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"{where}: manifest.json is not valid JSON ({exc})")
        return

    missing = REQUIRED_KEYS - manifest.keys()
    if missing:
        errors.append(f"{where}: manifest is missing keys: {', '.join(sorted(missing))}")
    if manifest.get("slug") != slug:
        errors.append(f"{where}: manifest slug '{manifest.get('slug')}' != folder name")
    if manifest.get("language") != lang:
        errors.append(f"{where}: manifest language '{manifest.get('language')}' != folder")
    if manifest.get("category") not in CATEGORIES:
        errors.append(f"{where}: unknown category '{manifest.get('category')}'")
    tags = manifest.get("tags")
    if not isinstance(tags, list) or not tags:
        errors.append(f"{where}: tags must be a non-empty list")
    else:
        for tag in tags:
            if tag not in CATEGORIES:
                warnings.append(f"{where}: tag '{tag}' is not a site tag")

    versions = manifest.get("versions") or []
    if not versions:
        errors.append(f"{where}: versions list is empty")
    seen = set()
    for v in versions:
        version = v.get("version", "")
        if not VERSION_RE.match(version):
            errors.append(f"{where}: version '{version}' is not MAJOR.MINOR.PATCH")
        if version in seen:
            errors.append(f"{where}: duplicate version '{version}'")
        seen.add(version)
        file_rel = v.get("file", "")
        file_path = script_dir / file_rel
        if not file_rel.startswith("versions/") or not file_path.is_file():
            errors.append(f"{where}: version file '{file_rel}' is missing")
            continue
        if not file_rel.endswith(LANGUAGES[lang]):
            errors.append(f"{where}: '{file_rel}' has the wrong extension for {lang}")
        if lang == "vscript":
            try:
                json.loads(file_path.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                errors.append(f"{where}: '{file_rel}' is not valid JSON ({exc})")

    if manifest.get("latest") not in seen:
        errors.append(f"{where}: latest '{manifest.get('latest')}' has no versions entry")

    pr_author = os.environ.get("PR_AUTHOR", "")
    if pr_author and manifest.get("author") and manifest["author"] != pr_author:
        warnings.append(
            f"{where}: PR author '{pr_author}' differs from manifest author "
            f"'{manifest['author']}' — fine for maintainers, worth a look otherwise"
        )


def all_script_dirs() -> list[str]:
    paths = []
    for lang in LANGUAGES:
        lang_dir = ROOT / "scripts" / lang
        if lang_dir.is_dir():
            for p in sorted(d for d in lang_dir.iterdir() if d.is_dir()):
                paths.append(f"scripts/{lang}/{p.name}/manifest.json")
    return paths


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--all", action="store_true", help="check every script folder instead of a diff")
    args = parser.parse_args()

    touched: set[tuple[str, str]] = set()
    for path in (all_script_dirs() if args.all else changed_files(args.base)):
        parts = path.split("/")
        if parts[0] != "scripts":
            warnings.append(f"{path}: outside scripts/ (maintainer change?)")
            continue
        if len(parts) < 4 or parts[1] not in LANGUAGES:
            errors.append(f"{path}: not under scripts/<razor|lua|vscript>/<slug>/")
            continue
        if not SLUG_RE.match(parts[2]):
            errors.append(f"{path}: slug '{parts[2]}' must be lowercase-with-dashes")
            continue
        touched.add((parts[1], parts[2]))

    for lang, slug in sorted(touched):
        check_manifest(lang, slug)

    for line in warnings:
        print(f"WARN:  {line}")
    for line in errors:
        print(f"ERROR: {line}", file=sys.stderr)
    print(f"{len(touched)} script folder(s) checked, {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
