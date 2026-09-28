-- Finds records and their members, and produces the hover anchors for both.
--
-- Two backends, one output shape:
--
--   record = { key, kind, name, anchor = {row, col}, close_row, members }
--   member = { key, name, row, anchor, kind = "field"|"anon_record",
--              record = <record>?, is_bitfield = boolean }
--
-- The key is the anchor position, so an anonymous member and the record it
-- introduces share a key -- they are the same hover, taken on the struct/union
-- keyword, which is the one anchor that works for named, anonymous, nested and
-- typedef'd records alike.
--
-- documentSymbol is primary: clangd hands back selectionRange values that are
-- exactly the positions it will answer hovers for, so the anchors cannot
-- disagree with the server that supplies the numbers. Treesitter is the
-- fallback for when the server returns nothing.

local M = {}

---@param row integer
---@param col integer
---@return string
local function key_of(row, col)
  return ("%d:%d"):format(row, col)
end

-- ---------------------------------------------------------------- documentSymbol

-- clangd's SymbolKind for a C record is not stable: the same server has been
-- observed returning Class (5) for a struct in one translation unit and
-- Struct (23) in another, and unions come back as Class. `detail` carries the
-- tag reliably, so that is what we discriminate on.
local RECORD_DETAIL = { struct = "struct", union = "union", class = "struct" }
local SYMBOL_FIELD = 8

-- clangd names an unnamed bitfield (`int : 0;`) "(anonymous)". Hovering it
-- returns null, and its space is already folded into the preceding field's
-- padding, so it is skipped rather than asked about.
local ANONYMOUS_FIELD = "(anonymous)"

---@param symbol table
---@return string? kind
local function record_kind(symbol)
  if not symbol.children or #symbol.children == 0 then
    -- An empty record is still a record; fall through to the detail check.
  end
  return RECORD_DETAIL[symbol.detail]
end

local function symbol_anchor(symbol)
  local start = (symbol.selectionRange or symbol.range).start
  return start.line, start.character
end

local build_symbol_record

---@param symbol table a Field symbol
---@return table member
local function symbol_field(symbol)
  local row, col = symbol_anchor(symbol)
  return {
    key = key_of(row, col),
    name = symbol.name,
    row = row,
    anchor = { row, col },
    kind = "field",
  }
end

---@param symbol table a record symbol
---@return table record
build_symbol_record = function(symbol)
  local row, col = symbol_anchor(symbol)
  local record = {
    key = key_of(row, col),
    kind = record_kind(symbol),
    name = symbol.name,
    anchor = { row, col },
    close_row = symbol.range["end"].line,
    members = {},
  }

  local children = symbol.children or {}
  local i = 1
  while i <= #children do
    local child = children[i]
    if record_kind(child) then
      local nxt = children[i + 1]
      -- `struct { ... } named;` arrives as a record symbol followed by a field
      -- whose detail is "struct (unnamed)". That field has a real Offset of
      -- its own, so it is an ordinary member -- not an anonymous one.
      if nxt and nxt.kind == SYMBOL_FIELD and nxt.detail and nxt.detail:match("%(unnamed%)$") then
        local member = symbol_field(nxt)
        member.record = build_symbol_record(child)
        record.members[#record.members + 1] = member
        i = i + 2
      else
        local inner = build_symbol_record(child)
        record.members[#record.members + 1] = {
          key = inner.key,
          name = inner.name,
          row = inner.anchor[1],
          anchor = inner.anchor,
          kind = "anon_record",
          record = inner,
        }
        i = i + 1
      end
    else
      if child.kind == SYMBOL_FIELD and child.name ~= ANONYMOUS_FIELD then
        record.members[#record.members + 1] = symbol_field(child)
      end
      i = i + 1
    end
  end

  return record
end

--- Normalise a textDocument/documentSymbol result into record trees.
---@param symbols table[]? DocumentSymbol[] (hierarchical) -- SymbolInformation[]
---   has no children and is rejected outright
---@return table[] records
function M.from_document_symbols(symbols)
  local records = {}
  if type(symbols) ~= "table" then
    return records
  end
  for _, symbol in ipairs(symbols) do
    if type(symbol) == "table" and symbol.range then
      if record_kind(symbol) then
        records[#records + 1] = build_symbol_record(symbol)
      elseif symbol.children then
        -- A record nested inside a namespace or function body.
        vim.list_extend(records, M.from_document_symbols(symbol.children))
      end
    end
  end
  return records
end

-- ------------------------------------------------------------------ treesitter

local QUERY = [[
(struct_specifier body: (field_declaration_list)) @record
(union_specifier  body: (field_declaration_list)) @record
]]

local SPECIFIER = { struct_specifier = "struct", union_specifier = "union" }

---@param node TSNode
---@return TSNode?
local function innermost_field_identifier(node)
  if node:type() == "field_identifier" then
    return node
  end
  for child in node:iter_children() do
    if child:named() then
      local found = innermost_field_identifier(child)
      if found then
        return found
      end
    end
  end
  return nil
end

---@param decl TSNode a field_declaration
---@return boolean
local function has_bitfield(decl)
  for child in decl:iter_children() do
    if child:type() == "bitfield_clause" then
      return true
    end
  end
  return false
end

--- The record specifier used as a declaration's type, if it defines a body.
---@param decl TSNode
---@return TSNode?, string?
local function inline_record(decl)
  local ty = decl:field("type")[1]
  if ty and SPECIFIER[ty:type()] and ty:field("body")[1] then
    return ty, SPECIFIER[ty:type()]
  end
  return nil, nil
end

local build_ts_record

---@param node TSNode a struct_specifier or union_specifier with a body
---@return table record
build_ts_record = function(node, source)
  local row, col = node:start()
  local body = node:field("body")[1]
  local close_row = select(1, body:end_())
  local name_node = node:field("name")[1]
  local record = {
    key = key_of(row, col),
    kind = SPECIFIER[node:type()],
    name = name_node and vim.treesitter.get_node_text(name_node, source) or nil,
    anchor = { row, col },
    close_row = close_row,
    members = {},
  }

  for decl in body:iter_children() do
    if decl:type() == "field_declaration" then
      local declarators = decl:field("declarator")
      local inner, _ = inline_record(decl)
      if #declarators == 0 then
        if inner then
          -- A truly anonymous member: no declarator, a record type with a body.
          local child = build_ts_record(inner, source)
          record.members[#record.members + 1] = {
            key = child.key,
            name = child.name,
            row = child.anchor[1],
            anchor = child.anchor,
            kind = "anon_record",
            record = child,
          }
        end
        -- Otherwise it is an unnamed bitfield (`int : 0;`), whose space is
        -- already folded into the preceding field's padding. Skipping it is
        -- correct, not a failure.
      else
        local bitfield = has_bitfield(decl)
        for _, declarator in ipairs(declarators) do
          local ident = innermost_field_identifier(declarator)
          -- tree-sitter-c gives an unnamed bitfield (`int : 0;`) a zero-width
          -- field_identifier. Its space is already folded into the preceding
          -- field's padding, so skipping it is correct -- and asking clangd
          -- about it would return null and poison the record.
          if ident and not vim.deep_equal({ ident:start() }, { ident:end_() }) then
            local irow, icol = ident:start()
            local member = {
              key = key_of(irow, icol),
              name = vim.treesitter.get_node_text(ident, source),
              row = irow,
              anchor = { irow, icol },
              kind = "field",
              is_bitfield = bitfield,
            }
            if inner then
              member.record = build_ts_record(inner, source)
            end
            record.members[#record.members + 1] = member
          end
        end
      end
    end
  end

  return record
end

--- Walk a parsed tree into record nodes. `source` is a buffer number or the
--- source string, whichever the parser was built from.
---@param tree TSTree
---@param source integer|string
---@return table[] records
local function records_of(tree, source)
  local query = vim.treesitter.query.get("c", "structlens")
  if not query then
    local ok, parsed = pcall(vim.treesitter.query.parse, "c", QUERY)
    if not ok then
      return {}
    end
    query = parsed
  end

  -- Top-level records only; nested ones are reached through their parent so
  -- that offsets are rebased exactly once.
  local seen, records = {}, {}
  for _, node in query:iter_captures(tree:root(), source, 0, -1) do
    local row, col = node:start()
    local key = key_of(row, col)
    if not seen[key] then
      local nested = false
      local parent = node:parent()
      while parent do
        if SPECIFIER[parent:type()] then
          nested = true
          break
        end
        parent = parent:parent()
      end
      if not nested then
        seen[key] = true
        records[#records + 1] = build_ts_record(node, source)
      end
    end
  end
  return records
end

--- Find records with treesitter. Only used when documentSymbol comes up empty.
---@param bufnr integer
---@return table[] records
function M.from_treesitter(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c")
  if not ok or not parser then
    return {}
  end
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  return records_of(tree, bufnr)
end

--- Same walk over a plain string, so the locator is testable headless.
---@param src string
---@return table[] records
function M.from_string(src)
  local parser = vim.treesitter.get_string_parser(src, "c")
  local tree = parser:parse()[1]
  if not tree then
    return {}
  end
  return records_of(tree, src)
end

-- ---------------------------------------------------------------------- scoping

--- Flatten a tree into the hover anchors to request, parents before children.
---@param records table[]
---@return table[] anchors { key, row, col }
function M.anchors(records)
  local out, seen = {}, {}
  local function visit(record)
    if not seen[record.key] then
      seen[record.key] = true
      out[#out + 1] = { key = record.key, row = record.anchor[1], col = record.anchor[2] }
    end
    for _, member in ipairs(record.members) do
      if not seen[member.key] then
        seen[member.key] = true
        out[#out + 1] = { key = member.key, row = member.anchor[1], col = member.anchor[2] }
      end
      if member.record then
        visit(member.record)
      end
    end
  end
  for _, record in ipairs(records) do
    visit(record)
  end
  return out
end

--- Keep only records overlapping [first_row, last_row].
---@param records table[]
---@param first_row integer
---@param last_row integer
---@return table[]
function M.within(records, first_row, last_row)
  local kept = {}
  for _, record in ipairs(records) do
    if record.anchor[1] <= last_row and record.close_row >= first_row then
      kept[#kept + 1] = record
    end
  end
  return kept
end

--- Keep only the record containing `row`, if any.
---@param records table[]
---@param row integer
---@return table[]
function M.containing(records, row)
  for _, record in ipairs(records) do
    if record.anchor[1] <= row and record.close_row >= row then
      return { record }
    end
  end
  return {}
end

return M
