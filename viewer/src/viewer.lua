-- viewer.lua — embedded into Zig, loaded at startup.
-- Holds the parsed contract and precomputes sibling/first-child links.

local cjson = require('cjson')
local M = { data = nil }

function M.load(path)
	local f = assert(io.open(path, 'r'))
	local s = f:read('*a')
	f:close()
	M.data = cjson.decode(s)

	-- Per-file precompute: firstChild[i], nextSibling[i]
	for fi = 1, #M.data.files do
		local file = M.data.files[fi]
		if file.nodes then
			local n = file.count
			local children = file.nodes.children
			local fc, ns = {}, {}
			for i = 1, n do fc[i] = 0; ns[i] = 0 end
			for i = 1, n do
				local ch = children[i]
				if ch ~= 0 then
					fc[i] = ch[1]
					for j = 1, #ch - 1 do
						ns[ch[j]] = ch[j + 1]
					end
				end
			end
			file.nodes.firstChild = fc
			file.nodes.nextSibling = ns
		end
	end

	return #M.data.files
end

function M.file_path(idx)  return M.data.files[idx].path end
function M.file_count(idx) return M.data.files[idx].count or 0 end
function M.file_root(idx)  return M.data.files[idx].root or 0 end
function M.kind_name(id)   return M.data.pools.kinds[id] end
function M.string_at(id)   return M.data.pools.strings[id] end

-- Returns 5 arrays (1-based, length == file.count): kind, start, end, firstChild, nextSibling
function M.arrays(idx)
	local n = M.data.files[idx].nodes
	return n.kind, n.start, n['end'], n.firstChild, n.nextSibling
end

return M
