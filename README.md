# ast-fingerprints

Live gallery of TypeScript codebases visualized as animated AST treemaps.
Every file becomes a colored rectangle whose subdivisions mirror its syntax
tree. Hover any cell to see the repo and file path it came from.

**Live site:** https://captnocap.github.io/ast-fingerprints/

## Submitting a repo

1. Open `submissions.txt` in this repo.
2. Add the GitHub URL of the repo you want on a new line, e.g.
   `https://github.com/sindresorhus/ky`.
3. Open a pull request with that change.
4. The `submit` workflow will clone the repo, parse it, and commit the
   resulting `gallery/<owner>__<repo>.json` back onto your PR branch.
5. Once a maintainer merges the PR, the `deploy` workflow republishes the
   site with your repo included.

### Rules / caveats

- Only public GitHub repos.
- TypeScript / TSX files only (the parser ignores everything else).
- Repos larger than 200 MB on disk are rejected.
- A repo's contract larger than 10 MB after normalization is rejected.
- Each repo's first submission wins — re-submitting an existing one is a no-op.

## Controls

| Key / action | What it does |
|---|---|
| **`t`** | Toggle between *individual* (one cell per file, scrollable) and *tiled* (packed grid, repeats to fill) modes |
| **scroll wheel** | Pan vertically in individual mode |
| **hover** | Show the source `repo : path/to/file` |
| **drag a `.json` onto the canvas** | Load any contract file ad-hoc, without submitting |
| **`esc` / `q`** | Quit (native build only) |

## Repo layout

```
.
├── viewer-love/        Löve2D app (drives both native and web builds)
│   ├── main.lua        Treemap renderer + interaction
│   ├── viewer.lua      Contract loader / accessors
│   └── default-contract.json  Bundled at build time by build-gallery.mjs
├── parser/             TypeScript → AST → contract pipeline
│   ├── parse.ts        Walk a directory, dump raw AST JSON
│   └── normalize.ts    Compact raw AST into the contract format
├── scripts/
│   ├── submit.mjs      One-shot: github URL → gallery/<slug>.json
│   └── build-gallery.mjs   Merge every gallery contract into one bundle
├── gallery/            Submitted contracts (one JSON per repo)
├── submissions.txt     Append a URL here in a PR to add a repo
└── .github/workflows/
    ├── submit.yml      On PR: ingest new submissions, commit contracts
    └── deploy.yml      On merge to main: rebuild viewer, publish to Pages
```

## Running locally

### Native viewer

```sh
# Requires: love (11.x), node, the parser deps installed.
cd parser && npm install && cd ..

# Look at the bundled gallery:
love viewer-love

# Or load a one-off contract:
love viewer-love path/to/contract.json
```

### Build a contract from a local directory

```sh
cd parser
npx tsx parse.ts /path/to/some/typescript/project /tmp/raw.json
npx tsx normalize.ts /tmp/raw.json /tmp/contract.json
love ../viewer-love /tmp/contract.json
```

### Build the web bundle

```sh
cd viewer-love
zip -rq /tmp/game.love . -x 'dist/*' '*.love'
npx love.js /tmp/game.love dist -t "AST Fingerprints" -m 134217728 -c
# serve dist/ with any static file server
```

## How it works

1. **Parse** — `parse.ts` walks the repo with the TypeScript compiler API and
   dumps every AST node as JSON.
2. **Normalize** — `normalize.ts` deduplicates kind/string/modifier tokens
   into pools and converts each file's tree into a struct-of-arrays layout.
   The result is the contract: a compact, language-agnostic representation
   the viewer can read without knowing TypeScript exists.
3. **Render** — the Löve viewer turns each file into a treemap. A node's
   rectangle is sized by its source byte span; children subdivide their
   parent's rectangle, alternating horizontal/vertical at each depth. Color
   comes from the node kind, with a slow hue rotation and a brighter "scan
   pulse" sweeping through each file's source.
4. **Merge** — when deploying, `build-gallery.mjs` unifies every contract's
   pools into a single shared one and tags each file with its source repo.
   The viewer reads the merged contract as if it were one giant codebase.

## Credits

- [Löve2D](https://love2d.org/) for graphics, packaged for the web with
  [love.js](https://github.com/Davidobot/love.js).
- TypeScript compiler API for parsing.
