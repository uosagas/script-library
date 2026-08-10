# UOSagas Script Library

Community scripts for the [UOSagas](https://www.uosagas.com) assistants — Razor scripts,
Lua scripts and VScript node graphs. Browse, rate and download them on the
**[script library page](https://www.uosagas.com/razor/share/)**; that page is also the
way to publish a script or release a new version of your own.

## How it works

- Every script lives in its own folder under `scripts/<language>/<slug>/` with a
  `manifest.json` (metadata) and a `versions/` folder holding one file per released
  version. The `latest` field in the manifest points at the version the site offers
  by default — older versions stay available.
- The website opens a pull request when you publish or update a script. Every pull
  request is reviewed by a maintainer before it is merged; nothing goes live
  automatically. A validation workflow checks the structure so reviews stay quick.
- `index.json` at the repo root is **generated** from all manifests after each merge —
  never edit it by hand.
- Ratings and download counters are not stored in this repo; the website keeps them
  and shows them next to each script.

## Layout

```
index.json                  generated catalog (do not edit)
scripts/
  razor/<slug>/manifest.json + versions/<version>.razor
  lua/<slug>/manifest.json + versions/<version>.lua
  vscript/<slug>/manifest.json + versions/<version>.vscript
tools/build_index.py        rebuilds index.json (runs in CI)
tools/validate.py           pull-request validation (runs in CI)
```

## manifest.json

```jsonc
{
  "name": "Mining Assistant",          // display name
  "slug": "mining-assistant",          // folder name, lowercase, dashes
  "language": "lua",                   // razor | lua | vscript
  "author": "Hawks",                   // GitHub login of the publisher (credit line)
  "description": "…",
  "category": "crafting",              // one of the site's categories
  "tags": ["crafting", "farming"],     // any of the site's tags
  "created": "2026-08-10",
  "updated": "2026-08-10",
  "latest": "1.0.0",
  "versions": [
    { "version": "1.0.0", "file": "versions/1.0.0.lua", "date": "2026-08-10" }
  ]
}
```

## License

MIT for the repository scaffolding; the scripts themselves are shared by their authors
for use with UOSagas. See [LICENSE](LICENSE).
