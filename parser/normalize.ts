import * as fs from 'node:fs';
import * as path from 'node:path';

type RawNode = {
	kind: string;
	kindCode: number;
	pos: number;
	end: number;
	start: number;
	loc: { line: number; column: number };
	text?: string;
	comment?: unknown;
	modifiers?: string[];
	children?: RawNode[];
};

type RawDiagnostic = {
	start: number;
	length: number;
	messageText: string;
	category: string;
	code: number;
};

type RawFile = {
	fileName: string;
	size: number;
	lineCount: number;
	diagnostics: RawDiagnostic[];
	ast: RawNode;
	error?: string;
};

type RawInput = {
	root: string;
	tsVersion: string;
	generatedAt: string;
	fileCount: number;
	files: Record<string, RawFile>;
	meta?: Record<string, unknown>;
};

class Pool {
	private index = new Map<string, number>();
	readonly values: string[] = [];
	id(v: string): number {
		const hit = this.index.get(v);
		if (hit !== undefined) return hit;
		this.values.push(v);
		const id = this.values.length;
		this.index.set(v, id);
		return id;
	}
}

function normalize(input: RawInput) {
	const kinds = new Pool();
	const strings = new Pool();
	const modifiers = new Pool();
	const categories = new Pool();

	const files = Object.entries(input.files).map(([relPath, f], i) => {
		if (f.error) {
			return { id: i + 1, path: relPath, error: f.error };
		}

		const nodeKind: number[] = [];
		const nodeStart: number[] = [];
		const nodeEnd: number[] = [];
		const nodeLine: number[] = [];
		const nodeCol: number[] = [];
		const nodeText: number[] = [];
		const nodeModifiers: (number[] | 0)[] = [];
		const nodeChildren: (number[] | 0)[] = [];
		const nodeParent: number[] = [];

		function visit(n: RawNode, parent: number): number {
			const id = nodeKind.length + 1;
			nodeKind.push(kinds.id(n.kind));
			nodeStart.push(n.start);
			nodeEnd.push(n.end);
			nodeLine.push(n.loc.line);
			nodeCol.push(n.loc.column);
			nodeText.push(n.text !== undefined ? strings.id(n.text) : 0);
			nodeModifiers.push(0);
			nodeChildren.push(0);
			nodeParent.push(parent);

			if (n.modifiers && n.modifiers.length) {
				nodeModifiers[id - 1] = n.modifiers.map((m) => modifiers.id(m));
			}
			if (n.children && n.children.length) {
				nodeChildren[id - 1] = n.children.map((c) => visit(c, id));
			}
			return id;
		}

		const root = visit(f.ast, 0);

		const diag = f.diagnostics.map((d) => ({
			s: d.start,
			len: d.length,
			msg: strings.id(d.messageText),
			cat: categories.id(d.category),
			code: d.code,
		}));

		return {
			id: i + 1,
			path: relPath,
			size: f.size,
			lines: f.lineCount,
			root,
			count: nodeKind.length,
			nodes: {
				kind: nodeKind,
				start: nodeStart,
				end: nodeEnd,
				line: nodeLine,
				col: nodeCol,
				text: nodeText,
				modifiers: nodeModifiers,
				children: nodeChildren,
				parent: nodeParent,
			},
			diagnostics: diag,
		};
	});

	return {
		schemaVersion: 1,
		tsVersion: input.tsVersion,
		generatedAt: input.generatedAt,
		root: input.root,
		meta: input.meta ?? {},
		lua: {
			indexing: '1-based throughout: pools and node ids. 0 is the "none" sentinel (parent of root, absent text/modifiers/children).',
			pools: 'kinds[i], strings[i], modifiers[i], diagnosticCategories[i] map id -> name.',
			nodeLayout: 'Per-file struct-of-arrays. For node id n in file F: F.nodes.kind[n], F.nodes.start[n], etc.',
			fields: {
				kind: 'kind pool id',
				start: 'source byte offset (inclusive)',
				end: 'source byte offset (exclusive)',
				line: '1-based line',
				col: '0-based column',
				text: 'string pool id, or 0 if the node has no literal text',
				modifiers: 'array of modifier pool ids, or 0 if none',
				children: 'array of child node ids, or 0 if none',
				parent: 'parent node id, or 0 for the root',
			},
		},
		pools: {
			kinds: kinds.values,
			strings: strings.values,
			modifiers: modifiers.values,
			diagnosticCategories: categories.values,
		},
		files,
	};
}

function main() {
	const inPath = path.resolve(process.argv[2] ?? (() => { throw new Error('usage: normalize.ts <raw.json> [out.json]'); })());
	const outPath = path.resolve(process.argv[3] ?? inPath.replace(/\.json$/, '.contract.json'));
	const raw = JSON.parse(fs.readFileSync(inPath, 'utf8')) as RawInput;
	const contract = normalize(raw);
	fs.writeFileSync(outPath, JSON.stringify(contract));
	const size = fs.statSync(outPath).size;
	const p = contract.pools;
	process.stderr.write(
		`wrote ${outPath}\n` +
		`  files: ${contract.files.length}\n` +
		`  kinds: ${p.kinds.length}, strings: ${p.strings.length}, modifiers: ${p.modifiers.length}\n` +
		`  size: ${(size / 1024 / 1024).toFixed(2)} MB\n`
	);
}

main();
