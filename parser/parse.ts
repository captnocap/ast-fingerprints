import * as fs from 'node:fs';
import * as path from 'node:path';
import * as ts from 'typescript';

function walk(dir: string, out: string[] = []): string[] {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		if (entry.name === 'node_modules' || entry.name === '.git' || entry.name === 'distribution' || entry.name === 'dist') continue;
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) walk(full, out);
		else if (entry.isFile() && /\.(ts|tsx|mts|cts)$/.test(entry.name)) out.push(full);
	}
	return out;
}

const SKIP_KEYS = new Set(['parent', 'symbol', 'localSymbol', 'nextContainer', 'locals', 'flowNode', 'endFlowNode', 'returnFlowNode', 'emitNode']);

function nodeToJson(node: ts.Node, source: ts.SourceFile): any {
	const out: any = {
		kind: ts.SyntaxKind[node.kind],
		kindCode: node.kind,
		pos: node.pos,
		end: node.end,
	};
	const start = node.getStart(source, false);
	out.start = start;
	const { line, character } = source.getLineAndCharacterOfPosition(start);
	out.loc = { line: line + 1, column: character };

	if (ts.isIdentifier(node) || ts.isPrivateIdentifier(node) || ts.isStringLiteralLike(node) || ts.isNumericLiteral(node) || ts.isBigIntLiteral(node)) {
		out.text = (node as any).text;
	}
	if (ts.isJSDocCommentContainingNode(node) && (node as any).comment) {
		out.comment = (node as any).comment;
	}

	if ((node as any).modifiers) {
		out.modifiers = (node as any).modifiers.map((m: ts.Node) => ts.SyntaxKind[m.kind]);
	}

	const children: any[] = [];
	ts.forEachChild(node, (child) => {
		children.push(nodeToJson(child, source));
	});
	if (children.length) out.children = children;

	return out;
}

function fileToJson(filePath: string): any {
	const text = fs.readFileSync(filePath, 'utf8');
	const source = ts.createSourceFile(filePath, text, ts.ScriptTarget.Latest, /* setParentNodes */ false, path.extname(filePath) === '.tsx' ? ts.ScriptKind.TSX : ts.ScriptKind.TS);

	const diagnostics: any[] = [];
	for (const d of (source as any).parseDiagnostics ?? []) {
		diagnostics.push({
			start: d.start,
			length: d.length,
			messageText: typeof d.messageText === 'string' ? d.messageText : ts.flattenDiagnosticMessageText(d.messageText, '\n'),
			category: ts.DiagnosticCategory[d.category],
			code: d.code,
		});
	}

	return {
		fileName: filePath,
		size: text.length,
		lineCount: source.getLineStarts().length,
		diagnostics,
		ast: nodeToJson(source, source),
	};
}

function main() {
	const target = path.resolve(process.argv[2] ?? '.');
	const outPath = path.resolve(process.argv[3] ?? 'output.json');
	const stat = fs.statSync(target);

	const files = stat.isDirectory() ? walk(target) : [target];
	files.sort();

	const root: any = {
		root: target,
		tsVersion: ts.version,
		generatedAt: new Date().toISOString(),
		fileCount: files.length,
		files: {} as Record<string, any>,
	};

	for (const file of files) {
		const rel = path.relative(target, file) || path.basename(file);
		process.stderr.write(`parsing ${rel}\n`);
		try {
			root.files[rel] = fileToJson(file);
		} catch (error: any) {
			root.files[rel] = { fileName: file, error: String(error?.stack ?? error) };
		}
	}

	fs.writeFileSync(outPath, JSON.stringify(root, null, 2));
	const bytes = fs.statSync(outPath).size;
	process.stderr.write(`\nwrote ${outPath} (${files.length} files, ${(bytes / 1024 / 1024).toFixed(2)} MB)\n`);
}

main();
