-- Pure parser for clangd's textDocument/hover markdown.
--
-- This module must stay free of any `vim.*` reference so the whole parse layer
-- is testable headless with no Neovim buffer and no language server. The test
-- runner enforces that with a grep.
--
-- The shapes below were captured from clangd 21.1.8 by driving it over stdio.
-- Do not rewrite them from memory; regenerate with tests/capture.lua instead.
--
--   ### field `len`
--
--   ---
--   Type: `unsigned int`
--   Offset: 4 bytes
--   Size: 4 bytes (+3 bytes padding), alignment 4 bytes
--
--   ---
--   ```cpp
--   // In struct Packet
--   public: unsigned int len
--   ```
--
-- Records carry no `Type:` and no `Offset:` line. There is no `Alignment:`
-- paragraph at all -- alignment is the lowercase ", alignment N bytes" suffix
-- riding on the Size line.

local M = {}

local PAD_SUFFIX = " %(%+(.-) padding%)$"
local ALIGN_SEP = ", alignment "

--- Convert one clangd quantity string to a bit count.
---
--- clangd renders quantities through formatSize/formatOffset, which produce:
---   "4 bytes" / "1 byte"       whole bytes, singular when the value is 1
---   "3 bits"  / "1 bit"        sub-byte values: bitfield sizes, bitfield padding
---   "16 bytes and 3 bits"      offsets only, bitfield off a byte boundary
---
--- Returns nil -- never 0 -- when nothing matches. A zero here would print
--- "0 B @0" on every field of every struct, confidently, forever; a nil is
--- caught downstream and suppresses the annotation instead.
---@param s string?
---@return integer? bits
function M.qty_to_bits(s)
  if type(s) ~= "string" then
    return nil
  end
  local bytes, bits = s:match("^(%d+) bytes? and (%d+) bits?$")
  if bytes then
    return tonumber(bytes) * 8 + tonumber(bits)
  end
  local n = s:match("^(%d+) bytes?$")
  if n then
    return tonumber(n) * 8
  end
  n = s:match("^(%d+) bits?$")
  if n then
    return tonumber(n)
  end
  return nil
end

--- Pull the markdown string out of any of the three LSP hover content shapes:
--- MarkupContent, a bare string, or a MarkedString[].
---@param result table? the `result` field of a textDocument/hover response
---@return string?
function M.contents_value(result)
  if type(result) ~= "table" then
    return nil
  end
  local contents = result.contents
  if type(contents) == "string" then
    return contents
  end
  if type(contents) ~= "table" then
    return nil
  end
  if type(contents.value) == "string" then
    return contents.value
  end
  -- MarkedString[]: concatenate the string-ish members in order.
  local parts = {}
  for _, item in ipairs(contents) do
    if type(item) == "string" then
      parts[#parts + 1] = item
    elseif type(item) == "table" and type(item.value) == "string" then
      parts[#parts + 1] = item.value
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n")
end

--- Split the "Size: ..." payload into its three parts.
--- The alignment separator is matched as a plain literal, not a pattern, so a
--- record type named with regex metacharacters cannot break it.
---@param payload string
---@return string? size, string? pad, string? align
local function split_size(payload)
  local size_part, align_part = payload, nil
  local sep = payload:find(ALIGN_SEP, 1, true)
  if sep then
    size_part = payload:sub(1, sep - 1)
    align_part = payload:sub(sep + #ALIGN_SEP)
  end
  local base, pad_part = size_part:match("^(.-)" .. PAD_SUFFIX)
  if base then
    size_part = base
  end
  return size_part, pad_part, align_part
end

--- Parse a hover markdown body into layout facts.
---
--- Every numeric field is nil when clangd did not report it. Absence is
--- meaningful and each case is handled by the caller:
---   offset nil on a union member    expected -- union members start at 0
---   offset nil on a struct field    unexpected -- downgrades the record
---   size nil                        flexible array member -- record incomplete
---   align nil                       tolerable -- drop the align= term
---@param value string?
---@return table? facts
function M.parse(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end

  local facts = { raw = value }
  local rulers = 0

  for line in (value:gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("%s+$", "")
    if line == "---" then
      rulers = rulers + 1
    elseif rulers >= 2 then
      -- Past the second ruler is the ```cpp declaration block. The only thing
      -- worth taking from it is the enclosing scope, which doubles as a
      -- cross-check that we hovered the member we meant to.
      local scope = line:match("^// In (.+)$")
      if scope then
        facts.scope = scope
      end
    else
      local kind, name = line:match("^### ([%w%-]+) `(.+)`$")
      if kind then
        facts.kind = kind
        facts.name = name
      else
        local ty = line:match("^Type: `(.+)`$")
        if ty then
          facts.type = ty
        else
          local offset = line:match("^Offset: (.+)$")
          if offset then
            facts.offset_bits = M.qty_to_bits(offset)
            facts.offset_raw = offset
          else
            local size = line:match("^Size: (.+)$")
            if size then
              local size_s, pad_s, align_s = split_size(size)
              facts.size_bits = M.qty_to_bits(size_s)
              facts.pad_bits = M.qty_to_bits(pad_s)
              facts.align_bits = M.qty_to_bits(align_s)
              facts.size_raw = size
            end
          end
        end
      end
    end
  end

  if not facts.kind then
    return nil
  end
  return facts
end

--- True when the facts describe a record rather than a member.
---@param facts table
---@return boolean
function M.is_record(facts)
  return facts.kind == "struct" or facts.kind == "union" or facts.kind == "class"
end

return M
