#!/usr/bin/env node
// Ingest a public GitHub repo URL into the gallery.
// Usage: node scripts/submit.mjs <github-url> [--out gallery/<slug>.json]
//
// Shallow-clones into a tmpdir, runs parser/parse.ts and parser/normalize.ts
// against it, then writes a normalized contract.json with meta.{repo,commit}
// into gallery/<owner>__<repo>.json. Exits non-zero on any failure so callers
// (e.g. the submit workflow) can fail the PR cleanly.

import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');
const MAX_REPO_BYTES = 200 * 1024 * 1024;  // 200MB clone cap — refuse giants
const MAX_CONTRACT_BYTES = 30 * 1024 * 1024; // 30MB minimal-contract cap

function parseGithubUrl(url) {
  const m = url.match(/^https?:\/\/github\.com\/([^/\s]+)\/([^/\s#?]+?)(?:\.git)?\/?$/);
  if (!m) throw new Error(`not a github url: ${url}`);
  return { owner: m[1], repo: m[2], slug: `${m[1]}__${m[2]}`.toLowerCase() };
}

function dirBytes(dir) {
  let total = 0;
  const stack = [dir];
  while (stack.length) {
    const d = stack.pop();
    for (const name of execFileSync('ls', ['-A', d], { encoding: 'utf8' }).split('\n').filter(Boolean)) {
      const p = join(d, name);
      const s = statSync(p);
      if (s.isDirectory()) stack.push(p);
      else total += s.size;
    }
  }
  return total;
}

function main() {
  const args = process.argv.slice(2);
  if (args.length < 1) { console.error('usage: submit.mjs <github-url> [--out path]'); process.exit(1); }
  const url = args[0];
  const outIdx = args.indexOf('--out');
  const { owner, repo, slug } = parseGithubUrl(url);
  const outPath = outIdx >= 0 ? resolve(args[outIdx + 1]) : resolve(ROOT, 'gallery', `${slug}.json`);

  const tmp = mkdtempSync(join(tmpdir(), 'ts-parse-submit-'));
  const cloneDir = join(tmp, 'repo');
  try {
    console.error(`[submit] cloning ${url} (shallow)`);
    execFileSync('git', ['clone', '--depth=1', '--no-tags', url, cloneDir], { stdio: ['ignore', 'inherit', 'inherit'] });

    const bytes = dirBytes(cloneDir);
    if (bytes > MAX_REPO_BYTES) throw new Error(`repo too large: ${(bytes/1e6).toFixed(1)}MB > ${(MAX_REPO_BYTES/1e6)}MB`);

    const commit = execFileSync('git', ['-C', cloneDir, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim();

    const rawPath = join(tmp, 'raw.json');
    const contractPath = join(tmp, 'contract.json');

    console.error(`[submit] parsing TypeScript`);
    execFileSync('npx', ['--prefix', join(ROOT, 'parser'), 'tsx', join(ROOT, 'parser/parse.ts'), cloneDir, rawPath],
      { stdio: ['ignore', 'inherit', 'inherit'] });

    // Inject submission metadata into the raw input before normalize.
    const raw = JSON.parse(readFileSync(rawPath, 'utf8'));
    raw.meta = {
      repo: `${owner}/${repo}`,
      url: `https://github.com/${owner}/${repo}`,
      commit,
      submittedAt: new Date().toISOString(),
    };
    writeFileSync(rawPath, JSON.stringify(raw));

    console.error(`[submit] normalizing`);
    execFileSync('npx', ['--prefix', join(ROOT, 'parser'), 'tsx', join(ROOT, 'parser/normalize.ts'), rawPath, contractPath, '--minimal'],
      { stdio: ['ignore', 'inherit', 'inherit'] });

    const cb = statSync(contractPath).size;
    if (cb > MAX_CONTRACT_BYTES) throw new Error(`contract too large: ${(cb/1e6).toFixed(1)}MB > ${(MAX_CONTRACT_BYTES/1e6)}MB`);

    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, readFileSync(contractPath));
    console.error(`[submit] wrote ${outPath} (${(cb/1e6).toFixed(2)} MB)`);
  } finally {
    try { rmSync(tmp, { recursive: true, force: true }); } catch {}
  }
}

main();
