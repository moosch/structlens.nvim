-- Pure formatting: annotated record tree -> extmark specs. No `vim.*`.
--
-- Output is a flat list of { row, virt_text?, virt_lines? } with at most one
-- virt_text entry per row. Rows have to be merged rather than stacked because
-- several annotations legitimately land on one line:
--
--   int b, c;                            two fields
--   struct OnlyAnon { struct { char z; }; };   two records, a field, two braces

local M = {}

local SEP = "  "
local HL = {
  size = "StructLensSize",
  offset = "StructLensOffset",
  pad = "StructLensPad",
  slack = "StructLensSlack",
  hole = "StructLensHole",
  total = "StructLensTotal",
  waste = "StructLensWaste",
}

---@param bits integer
---@param units string "auto" | "bytes" | "bits"
---@return string
local function fmt_quantity(bits, units)
  if units == "bits" or (units ~= "bytes" and bits % 8 ~= 0) then
    return ("%db"):format(bits)
  end
  return ("%d B"):format(bits / 8)
end

--- Never truncate a bitfield offset to whole bytes: "@64" and "@64+3b" are
--- different places, and the second one is where the field actually is.
---@param bits integer
---@return string
local function fmt_offset(bits)
  if bits % 8 == 0 then
    return ("@%d"):format(bits / 8)
  end
  return ("@%d+%db"):format(math.floor(bits / 8), bits % 8)
end

---@param member table
---@param cfg table
---@return table[]? chunks
local function member_chunks(member, cfg)
  if member.size_bits == nil then
    return nil
  end
  local chunks = { { fmt_quantity(member.size_bits, cfg.units), HL.size } }
  if cfg.show_offset and member.abs_bits then
    chunks[#chunks + 1] = { " " .. fmt_offset(member.abs_bits), HL.offset }
  end
  if member.slack_bits and member.slack_bits > 0 then
    -- A union member's own unused tail. Deliberately not called padding: it
    -- overlaps its siblings and never enters any total.
    chunks[#chunks + 1] = { " +" .. fmt_quantity(member.slack_bits, cfg.units) .. " slack", HL.slack }
  elseif cfg.holes == "inline" and member.hole_bits and member.hole_bits > 0 then
    chunks[#chunks + 1] = { " +" .. fmt_quantity(member.hole_bits, cfg.units) .. " pad", HL.pad }
  end
  return chunks
end

---@param record table
---@param cfg table
---@return table[]? chunks
local function total_chunks(record, cfg)
  if not cfg.show_total or record.size_bits == nil then
    return nil
  end
  local text = ("sizeof=%d"):format(record.size_bits / 8)
  if record.align_bits then
    text = text .. (" align=%d"):format(record.align_bits / 8)
  end
  if not record.trusted or record.total_pad_bits == nil then
    -- Degrade to less information, never to wrong information.
    if record.incomplete then
      text = text .. " (flexible array)"
    end
    return { { text, HL.total } }
  end
  if record.total_pad_bits > 0 then
    text = text .. (" %s pad"):format(fmt_quantity(record.total_pad_bits, cfg.units))
    if record.waste_pct then
      text = text .. (" (%d%%)"):format(math.floor(record.waste_pct + 0.5))
    end
  end
  local hl = HL.total
  if record.waste_pct and record.waste_pct >= cfg.waste_threshold then
    hl = HL.waste
  end
  return { { text, hl } }
end

---@param records table[]
---@param cfg table
---@param out table[]
local function collect(records, cfg, out)
  for _, record in ipairs(records) do
    for _, member in ipairs(record.members) do
      local chunks = member_chunks(member, cfg)
      if chunks then
        out[#out + 1] = { row = member.row, chunks = chunks }
      end
      if cfg.holes == "virt_lines" and member.hole_bits and member.hole_bits > 0 then
        out[#out + 1] = {
          row = member.row,
          virt_lines = {
            { { ("%s⋯ %s hole ⋯"):format(cfg.hole_indent or "  ", fmt_quantity(member.hole_bits, cfg.units)), HL.hole } },
          },
        }
      end
      if member.record then
        collect({ member.record }, cfg, out)
      end
    end
    -- Pushed after the members, so a nested record's total precedes its
    -- parent's when both land on the same closing line.
    local total = total_chunks(record, cfg)
    if total then
      out[#out + 1] = { row = record.close_row, chunks = total }
    end
  end
end

--- Build extmark specs for a whole buffer's worth of annotated records.
---@param records table[] output of layout.compute
---@param cfg table
---@return table[] specs { row, virt_text?, virt_lines? }
function M.marks(records, cfg)
  local entries = {}
  collect(records, cfg, entries)

  local order, by_row, specs = {}, {}, {}
  for _, entry in ipairs(entries) do
    if entry.virt_lines then
      specs[#specs + 1] = { row = entry.row, virt_lines = entry.virt_lines }
    else
      if not by_row[entry.row] then
        by_row[entry.row] = {}
        order[#order + 1] = entry.row
      end
      local row = by_row[entry.row]
      if #row > 0 then
        row[#row + 1] = { SEP, HL.size }
      end
      for _, chunk in ipairs(entry.chunks) do
        row[#row + 1] = chunk
      end
    end
  end

  for _, row in ipairs(order) do
    local chunks, width = {}, 0
    for _, chunk in ipairs(by_row[row]) do
      if width + #chunk[1] > cfg.max_row_width then
        chunks[#chunks + 1] = { "…", HL.total }
        break
      end
      width = width + #chunk[1]
      chunks[#chunks + 1] = chunk
    end
    specs[#specs + 1] = { row = row, virt_text = chunks }
  end

  return specs
end

--- Why a buffer full of records produced no numbers at all.
---
--- clang cannot lay out a record that contains an unresolved type, so ONE
--- unknown member type strips Size and Offset from every member and from the
--- record itself. That renders as silence, which looks like the plugin is
--- broken rather than like the translation unit is.
---@param records table[] annotated records
---@param error_count integer clangd errors in the buffer
---@param first_error string? the first error message
---@return string? message
function M.no_layout_reason(records, error_count, first_error)
  if #records == 0 then
    return nil
  end
  for _, record in ipairs(records) do
    if record.size_bits then
      return nil
    end
  end
  local why = "structlens: clangd reported no layout for any record in this buffer."
  if error_count and error_count > 0 then
    return why
      .. (" This translation unit has %d error%s -- one unresolved type removes the sizes from the whole record. First: %s")
        :format(error_count, error_count == 1 and "" or "s", first_error or "?")
  end
  return why
    .. " Check that every member's type is visible here: a missing #include, or no compile_commands.json entry for this file."
end

M._fmt_quantity = fmt_quantity
M._fmt_offset = fmt_offset
M.HL = HL

return M
