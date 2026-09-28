-- Pure layout math. No `vim.*` reference: the test runner enforces that.
--
-- Input is a record tree from locate.lua plus a facts table keyed by node key
-- (hover.parse output). Output is the same tree with layout fields filled in.
--
-- The one rule everything here obeys: this module computes only DIFFERENCES.
-- Every sizeof, alignment and offset it reports is a number clangd said. Holes
-- and percentages are the only derived values, and each is checked against an
-- invariant before it is allowed out.
--
-- The invariant, measured to hold exactly (in bits, bitfields included) across
-- the whole capture corpus:
--
--   sum over direct members of (size + padding) == sizeof(record)
--
-- That check is target-agnostic. It does not model C's alignment rules, so
-- #pragma pack and __attribute__((packed)) reconcile correctly rather than
-- tripping it, while a genuinely misunderstood layout cannot slip past.
--
-- clangd omits the "(+N padding)" clause when padding is zero, so an absent
-- pad means 0, not unknown.

local M = {}

---@param bits integer
---@return integer
local function bytes_of(bits)
  return bits / 8
end

--- Union members all start at offset 0 and overlap. clangd reports each one's
--- "padding" as sizeof(union) - sizeof(member), which is that member's own
--- unused tail, NOT a hole in the enclosing struct. Summing those fabricates
--- loss, so they are rendered as `slack` and never reach an accumulator.
---@param record table
local function compute_union(record)
  local largest = 0
  for _, m in ipairs(record.members) do
    if m.size_bits and m.size_bits > largest then
      largest = m.size_bits
    end
  end
  record.largest_bits = largest
  if record.size_bits then
    record.total_pad_bits = record.size_bits - largest
    if record.total_pad_bits < 0 then
      record.trusted = false
      record.total_pad_bits = nil
    end
  end
end

--- Derive each member's hole, cross-check it against clangd's own figure, then
--- reconcile the whole record.
---@param record table
local function compute_struct(record)
  local members = record.members
  local total = 0

  for i, m in ipairs(members) do
    if m.rel == nil or m.size_bits == nil then
      record.trusted = false
    else
      local next_start = members[i + 1] and members[i + 1].rel or record.size_bits
      local expected = next_start and (next_start - (m.rel + m.size_bits)) or nil
      if expected and expected < 0 then
        record.trusted = false
        expected = nil
      end
      -- clangd's number wins; ours exists to catch the day it stops agreeing.
      if m.pad_bits ~= nil and expected ~= nil and m.pad_bits ~= expected then
        record.trusted = false
      end
      local effective = m.pad_bits or expected
      if effective == nil then
        record.trusted = false
      else
        m.hole_bits = effective
        total = total + m.size_bits + effective
      end
    end
  end

  if record.trusted and record.size_bits and total ~= record.size_bits then
    -- The walk and clangd disagree about where the bytes went. Something in
    -- this record is not what we think it is; say nothing rather than guess.
    record.trusted = false
  end
  if record.trusted then
    local pad = 0
    for _, m in ipairs(members) do
      pad = pad + (m.hole_bits or 0)
    end
    record.total_pad_bits = pad
  end
end

--- Annotate one record and everything under it.
---@param record table node from locate.lua
---@param facts table<string, table> hover.parse results keyed by node key
---@param base_bits integer absolute bit offset of this record in its outermost
---   ancestor. Required positionally, never defaulted: an anonymous member's
---   inner fields report offsets relative to the anonymous record, so a
---   silently-zero base is exactly the bug that ships wrong-looking-right
---   numbers.
local function annotate(record, facts, base_bits)
  assert(type(base_bits) == "number", "annotate: base_bits is required")

  local rf = facts[record.key]
  record.base_bits = base_bits
  record.is_union = record.kind == "union"
  record.trusted = true
  record.incomplete = false

  if not rf then
    record.trusted = false
  else
    record.size_bits = rf.size_bits
    record.align_bits = rf.align_bits
    if rf.name and record.name and rf.name ~= record.name then
      -- The hover answered about a different symbol than the locator aimed at.
      record.trusted = false
    end
  end
  if record.size_bits == nil then
    record.trusted = false
  end

  local cursor = 0
  for i, m in ipairs(record.members) do
    local mf = facts[m.key]
    if mf then
      m.size_bits = mf.size_bits
      m.type = mf.type
      m.scope = mf.scope
      m.pad_bits = mf.pad_bits
    else
      record.trusted = false
    end
    if m.size_bits == nil then
      record.trusted = false
      -- A flexible array member has no size, and the record's sizeof excludes
      -- it, so no total for this record can mean anything. Only the LAST
      -- member can be one; a sizeless member anywhere else means we simply
      -- failed to read it, and mislabelling that as a flexible array would be
      -- its own kind of wrong number.
      if i == #record.members then
        record.incomplete = true
      end
    end

    if record.is_union then
      m.rel = 0
      m.slack_bits = m.pad_bits
      m.pad_bits = nil
    elseif mf and mf.offset_bits then
      m.rel = mf.offset_bits
    elseif m.kind == "anon_record" then
      -- Anonymous members carry no Offset of their own; their position is
      -- fully determined by where the previous member ended.
      m.rel = cursor
    else
      m.rel = nil
      record.trusted = false
    end

    m.abs_bits = m.rel and (base_bits + m.rel) or nil
    if m.rel and m.size_bits then
      cursor = m.rel + m.size_bits + (m.pad_bits or 0)
    end

    if m.record then
      annotate(m.record, facts, base_bits + (m.rel or 0))
    end
  end

  if record.is_union then
    compute_union(record)
  else
    compute_struct(record)
  end

  if not record.trusted then
    record.total_pad_bits = nil
    for _, m in ipairs(record.members) do
      m.hole_bits = nil
    end
  end

  if record.total_pad_bits and record.size_bits and record.size_bits > 0 then
    record.waste_pct = record.total_pad_bits / record.size_bits * 100
  else
    record.waste_pct = nil
  end
  record.size_bytes = record.size_bits and bytes_of(record.size_bits) or nil
end

--- Annotate a list of top-level records in place and return it.
---@param records table[] record nodes from locate.lua
---@param facts table<string, table>
---@return table[] records
function M.compute(records, facts)
  for _, record in ipairs(records) do
    annotate(record, facts, 0)
  end
  return records
end

M._annotate = annotate

return M
