local render = require("structlens.render")

local CFG = {
  units = "auto", show_offset = true, show_total = true,
  holes = "inline", waste_threshold = 25, max_row_width = 80,
}

local function cfg(patch)
  return vim.tbl_extend("force", CFG, patch or {})
end

local function text_of(spec)
  local parts = {}
  for _, chunk in ipairs(spec.virt_text or spec.virt_lines[1]) do
    parts[#parts + 1] = chunk[1]
  end
  return table.concat(parts)
end

local function rows(specs)
  local out = {}
  for _, spec in ipairs(specs) do
    out[#out + 1] = ("%d:%s%s"):format(spec.row, spec.virt_lines and "~" or "", text_of(spec))
  end
  return out
end

describe("render.fmt", function()
  it("prints whole bytes as bytes and sub-byte values as bits", function()
    eq("4 B", render._fmt_quantity(32, "auto"))
    eq("3b", render._fmt_quantity(3, "auto"))
    eq("32b", render._fmt_quantity(32, "bits"))
  end)

  it("never truncates a bitfield offset to whole bytes", function()
    eq("@8", render._fmt_offset(64))
    eq("@64+3b", render._fmt_offset(64 * 8 + 3))
  end)
end)

describe("render.marks", function()
  it("renders size, offset and an inline hole", function()
    local specs = render.marks({
      {
        kind = "struct", close_row = 3, size_bits = 8 * 8, align_bits = 4 * 8,
        trusted = true, total_pad_bits = 3 * 8, waste_pct = 37.5,
        members = {
          { row = 1, name = "a", size_bits = 8, abs_bits = 0, hole_bits = 3 * 8 },
          { row = 2, name = "b", size_bits = 4 * 8, abs_bits = 4 * 8, hole_bits = 0 },
        },
      },
    }, cfg())
    eq({ "1:1 B @0 +3 B pad", "2:4 B @4", "3:sizeof=8 align=4 3 B pad (38%)" }, rows(specs))
  end)

  it("labels a union member's tail as slack and omits it from the total", function()
    local specs = render.marks({
      {
        kind = "union", close_row = 3, size_bits = 8 * 8, align_bits = 4 * 8,
        trusted = true, total_pad_bits = 1 * 8, waste_pct = 12.5,
        members = {
          { row = 1, name = "ui", size_bits = 4 * 8, abs_bits = 0, slack_bits = 4 * 8 },
          { row = 2, name = "uc", size_bits = 7 * 8, abs_bits = 0, slack_bits = 1 * 8 },
        },
      },
    }, cfg())
    eq({ "1:4 B @0 +4 B slack", "2:7 B @0 +1 B slack", "3:sizeof=8 align=4 1 B pad (13%)" }, rows(specs))
  end)

  it("merges several annotations that land on one row", function()
    -- Handles multiple fields on a single line with a single type: `int b, c;`.
    local specs = render.marks({
      {
        kind = "struct", close_row = 0, size_bits = 8 * 8, align_bits = 4 * 8,
        trusted = true, total_pad_bits = 0,
        members = {
          { row = 0, name = "b", size_bits = 4 * 8, abs_bits = 0, hole_bits = 0 },
          { row = 0, name = "c", size_bits = 4 * 8, abs_bits = 4 * 8, hole_bits = 0 },
        },
      },
    }, cfg())
    eq(1, #specs)
    eq("4 B @0  4 B @4  sizeof=8 align=4", text_of(specs[1]))
  end)

  it("puts a nested record's total before its parent's on a shared row", function()
    local inner = {
      kind = "struct", close_row = 0, size_bits = 1 * 8, align_bits = 1 * 8,
      trusted = true, total_pad_bits = 0,
      members = { { row = 0, name = "z", size_bits = 8, abs_bits = 0, hole_bits = 0 } },
    }
    local specs = render.marks({
      {
        kind = "struct", close_row = 0, size_bits = 2 * 8, align_bits = 1 * 8,
        trusted = true, total_pad_bits = 1 * 8, waste_pct = 50,
        members = { { row = 0, name = "(anon)", kind = "anon_record", size_bits = 8, abs_bits = 0, hole_bits = 1 * 8, record = inner } },
      },
    }, cfg())
    eq("1 B @0 +1 B pad  1 B @0  sizeof=1 align=1  sizeof=2 align=1 1 B pad (50%)", text_of(specs[1]))
  end)

  it("emits a hole as its own virtual line when asked", function()
    local specs = render.marks({
      {
        kind = "struct", close_row = 2, size_bits = 8 * 8, align_bits = 8 * 8,
        trusted = true, total_pad_bits = 7 * 8, waste_pct = 87.5,
        members = { { row = 1, name = "a", size_bits = 8, abs_bits = 0, hole_bits = 7 * 8 } },
      },
    }, cfg({ holes = "virt_lines" }))
    eq({ "1:~  ⋯ 7 B hole ⋯", "1:1 B @0", "2:sizeof=8 align=8 7 B pad (88%)" }, rows(specs))
  end)

  it("drops the padding terms for an untrusted record", function()
    local specs = render.marks({
      {
        kind = "struct", close_row = 2, size_bits = 8 * 8, align_bits = 4 * 8,
        trusted = false,
        members = { { row = 1, name = "a", size_bits = 8, abs_bits = 0 } },
      },
    }, cfg())
    eq({ "1:1 B @0", "2:sizeof=8 align=4" }, rows(specs))
  end)

  it("says so when a flexible array member makes the total meaningless", function()
    local specs = render.marks({
      {
        kind = "struct", close_row = 2, size_bits = 4 * 8, align_bits = 4 * 8,
        trusted = false, incomplete = true,
        members = { { row = 1, name = "n", size_bits = 4 * 8, abs_bits = 0 } },
      },
    }, cfg())
    eq("sizeof=4 align=4 (flexible array)", text_of(specs[2]))
  end)

  it("skips a member whose size never arrived", function()
    local specs = render.marks({
      {
        kind = "struct", close_row = 2, size_bits = 4 * 8, trusted = false,
        members = { { row = 1, name = "data", size_bits = nil, abs_bits = 4 * 8 } },
      },
    }, cfg())
    eq({ "2:sizeof=4" }, rows(specs))
  end)

  it("truncates a row that would run away", function()
    local members = {}
    for i = 1, 20 do
      members[i] = { row = 0, name = "f" .. i, size_bits = 4 * 8, abs_bits = i * 32, hole_bits = 0 }
    end
    local specs = render.marks({
      { kind = "struct", close_row = 9, size_bits = 80 * 8, trusted = true, total_pad_bits = 0, members = members },
    }, cfg())
    truthy(text_of(specs[1]):match("…$"), "expected an ellipsis, got: " .. text_of(specs[1]))
  end)
end)

describe("render.no_layout_reason", function()
  local sized = { { size_bits = 8 * 8, members = {} } }
  local unsized = { { size_bits = nil, members = {} } }

  it("says nothing when anything got a size", function()
    eq(nil, render.no_layout_reason(sized, 0, nil))
    eq(nil, render.no_layout_reason({}, 3, "boom"))
  end)

  it("blames the errors when clangd reported some", function()
    local msg = render.no_layout_reason(unsized, 1, "unknown type name 'uint32'")
    truthy(msg:match("1 error"))
    truthy(msg:match("unknown type name 'uint32'"))
  end)

  it("points at includes and compile_commands when there are no errors", function()
    local msg = render.no_layout_reason(unsized, 0, nil)
    truthy(msg:match("compile_commands"))
  end)
end)
