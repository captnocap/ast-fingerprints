-- Adapted from ts-parse/viewer/src/viewer.lua for Löve.
-- Decodes a contract from a string (so it works with love.filesystem reads
-- AND with web drag-and-drop), then precomputes firstChild/nextSibling.

local json = require('json')
local M = { data = nil }

function M.load_string(s)
  M.data = json.decode(s)
  for fi = 1, #M.data.files do
    local file = M.data.files[fi]
    if file.nodes then
      local n = file.count
      local children = file.nodes.children
      local fc, ns = {}, {}
      for i = 1, n do fc[i] = 0; ns[i] = 0 end
      for i = 1, n do
        local ch = children[i]
        if ch ~= 0 and type(ch) == 'table' then
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
function M.file_repo(idx)
  local f = M.data.files[idx]
  if f.repo then return f.repo end
  if f.repoId and M.data.pools and M.data.pools.repos then
    return M.data.pools.repos[f.repoId]
  end
  return (M.data.meta and M.data.meta.repo) or nil
end

-- Returns: kind, start, end_, firstChild, nextSibling, max_end
function M.arrays(idx)
  local n = M.data.files[idx].nodes
  local end_ = n['end']
  local max_end = 0
  for i = 1, #end_ do if end_[i] > max_end then max_end = end_[i] end end
  return n.kind, n.start, end_, n.firstChild, n.nextSibling, max_end
end

return M
