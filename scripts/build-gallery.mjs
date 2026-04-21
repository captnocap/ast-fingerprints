#!/usr/bin/env node
// Merge every contract under gallery/ into one combined contract, then bundle
// it into viewer-love/ as default-contract.json. Intended to be run in the
// deploy workflow after any PR that adds/updates gallery files is merged.
//
// Merge strategy:
//   - Concatenate files across all contracts.
//   - Remap per-contract pool ids (kinds, strings, modifiers) into a single
//     shared pool, so the renderer sees one flat contract.
//   - Introduce a new pool `repos` and tag every file with repoId, so the
//     viewer's tooltip can show which repo each cell came from.

import { readFileSync, writeFileSync, readdirSync, statSync, mkdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const GALLERY = resolve(ROOT, 'gallery');
const OUT = resolve(ROOT, 'viewer-love/default-contract.json');
const INDEX_OUT = resolve(GALLERY, 'index.json');

function poolAdder(out) {
  const index = new Map();
  out.forEach((v, i) => index.set(v, i + 1));
  return (v) => {
    const hit = index.get(v);
    if (hit !== undefined) return hit;
    out.push(v);
    const id = out.length;
    index.set(v, id);
    return id;
  };
}

function remapIdArray(arr, map) {
  return arr.map((v) => (v === 0 ? 0 : map[v]));
}

function main() {
  if (!statSync(GALLERY, { throwIfNoEntry: false })?.isDirectory()) {
    console.error('no gallery/ directory; nothing to merge');
    process.exit(0);
  }
  const entries = readdirSync(GALLERY).filter((n) => n.endsWith('.json') && n !== 'index.json');
  if (entries.length === 0) { console.error('no gallery contracts'); process.exit(0); }

  const merged = {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    meta: { kind: 'merged-gallery', count: entries.length },
    pools: { kinds: [], strings: [], modifiers: [], diagnosticCategories: [], repos: [] },
    files: [],
  };
  const addKind = poolAdder(merged.pools.kinds);
  const addStr = poolAdder(merged.pools.strings);
  const addMod = poolAdder(merged.pools.modifiers);
  const addRepo = poolAdder(merged.pools.repos);

  const indexList = [];

  for (const fname of entries.sort()) {
    const c = JSON.parse(readFileSync(join(GALLERY, fname), 'utf8'));
    const repoName = (c.meta && c.meta.repo) || fname.replace(/\.json$/, '');
    const repoId = addRepo(repoName);
    indexList.push({
      slug: fname.replace(/\.json$/, ''),
      repo: repoName,
      url: c.meta && c.meta.url,
      commit: c.meta && c.meta.commit,
      submittedAt: c.meta && c.meta.submittedAt,
      files: c.files.length,
    });

    // Build remap tables from this contract's pools into the merged pools.
    // Minimal contracts only have a kinds pool — handle the rest as optional.
    const kindMap = [0, ...c.pools.kinds.map(addKind)];
    const strMap  = c.pools.strings    ? [0, ...c.pools.strings.map(addStr)]    : null;
    const modMap  = c.pools.modifiers  ? [0, ...c.pools.modifiers.map(addMod)]  : null;

    for (const f of c.files) {
      if (!f.nodes) continue;
      const n = f.nodes;
      const out = {
        kind: remapIdArray(n.kind, kindMap),
        start: n.start,
        end: n.end,
        children: n.children,
      };
      if (n.line)     out.line   = n.line;
      if (n.col)      out.col    = n.col;
      if (n.text     && strMap) out.text     = remapIdArray(n.text, strMap);
      if (n.modifiers && modMap) out.modifiers = n.modifiers.map((m) => (m === 0 ? 0 : remapIdArray(m, modMap)));
      if (n.parent)   out.parent = n.parent;
      merged.files.push({ path: f.path, repoId, root: f.root, count: f.count, nodes: out });
    }
  }

  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, JSON.stringify(merged));
  writeFileSync(INDEX_OUT, JSON.stringify(indexList, null, 2));
  const size = statSync(OUT).size;
  console.error(`[build-gallery] merged ${entries.length} contracts, ${merged.files.length} files, ${(size/1e6).toFixed(2)} MB → ${OUT}`);
}

main();
