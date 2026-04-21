-- consume.lua <contract.json>
-- Smoke-test the contract: decode, walk one AST, aggregate across all files.

local cjson = require('cjson')

local function read_all(p)
	local f = assert(io.open(p, 'r'))
	local s = f:read('*a')
	f:close()
	return s
end

local path = arg[1] or error('usage: luajit consume.lua <contract.json>')
local t0 = os.clock()
local data = cjson.decode(read_all(path))
local decode_s = os.clock() - t0

local kinds = data.pools.kinds
local strings = data.pools.strings
local modifiers = data.pools.modifiers

-- build name -> id table for a few kinds we care about
local kindByName = {}
for i = 1, #kinds do kindByName[kinds[i]] = i end

local IMPORT = kindByName['ImportDeclaration']
local JSX_EL = kindByName['JsxElement']
local JSX_SELF = kindByName['JsxSelfClosingElement']
local FN_DECL = kindByName['FunctionDeclaration']
local ARROW_FN = kindByName['ArrowFunction']
local TYPE_ALIAS = kindByName['TypeAliasDeclaration']
local INTERFACE = kindByName['InterfaceDeclaration']

local totals = { import = 0, jsx = 0, fn = 0, arrow = 0, alias = 0, iface = 0 }
local nodeTotal = 0

for fi = 1, #data.files do
	local f = data.files[fi]
	if f.nodes then
		local k = f.nodes.kind
		nodeTotal = nodeTotal + #k
		for i = 1, #k do
			local v = k[i]
			if     v == IMPORT     then totals.import = totals.import + 1
			elseif v == JSX_EL or v == JSX_SELF then totals.jsx = totals.jsx + 1
			elseif v == FN_DECL    then totals.fn = totals.fn + 1
			elseif v == ARROW_FN   then totals.arrow = totals.arrow + 1
			elseif v == TYPE_ALIAS then totals.alias = totals.alias + 1
			elseif v == INTERFACE  then totals.iface = totals.iface + 1
			end
		end
	end
end

-- walk the first file's AST and collect top-level kinds + names
local function walkTop(f, limit)
	local root = f.root
	local c = f.nodes.children[root]
	if c == 0 then return {} end
	local out = {}
	for i = 1, math.min(#c, limit or 10) do
		local id = c[i]
		local entry = { kind = kinds[f.nodes.kind[id]], line = f.nodes.line[id] }
		-- try to grab an identifier name from its children
		local cc = f.nodes.children[id]
		if cc ~= 0 then
			for j = 1, #cc do
				local cid = cc[j]
				local t = f.nodes.text[cid]
				if t ~= 0 then entry.name = strings[t]; break end
			end
		end
		out[#out + 1] = entry
	end
	return out
end

local f1
for i = 1, #data.files do
	if data.files[i].nodes then f1 = data.files[i]; break end
end

print(('contract v%d | ts %s'):format(data.schemaVersion, data.tsVersion))
print(('decode: %.3fs | files: %d | total nodes: %d')
	:format(decode_s, #data.files, nodeTotal))
print(('pools: kinds=%d strings=%d modifiers=%d')
	:format(#kinds, #strings, #modifiers))
print(('totals: imports=%d jsx=%d fnDecl=%d arrowFn=%d typeAlias=%d iface=%d')
	:format(totals.import, totals.jsx, totals.fn, totals.arrow, totals.alias, totals.iface))

print(('\nfirst parsed file: %s (%d nodes, %d lines)')
	:format(f1.path, f1.count, f1.lines))
print('top-level children:')
for _, e in ipairs(walkTop(f1, 8)) do
	print(('  [L%d] %s%s'):format(e.line, e.kind, e.name and (' -> ' .. e.name) or ''))
end
