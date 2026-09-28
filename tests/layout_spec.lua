local hover = require("structlens.hover")
local layout = require("structlens.layout")
local fixtures = dofile("tests/fixtures/hover_samples.lua")

local B = 8 -- bits per byte

--- Facts table straight from clangd output.
local function facts_for(keys)
  local facts = {}
  for _, key in ipairs(keys) do
    local sample = fixtures.samples[key]
    assert(sample ~= nil, "no such fixture: " .. key)
    if sample ~= false then
      facts[key] = hover.parse(sample)
    end
  end
  return facts
end

local function field(key, name, opts)
  return vim.tbl_extend("force", {
    key = key, name = name, kind = "field", row = 0, anchor = { 0, 0 },
  }, opts or {})
end

local function anon_member(record)
  return { key = record.key, name = record.name, kind = "anon_record", record = record, row = 0, anchor = { 0, 0 } }
end

local function record(key, kind, name, members)
  return { key = key, kind = kind, name = name, anchor = { 0, 0 }, close_row = 0, members = members }
end

local function keys_of(node, acc)
  acc = acc or {}
  acc[#acc + 1] = node.key
  for _, m in ipairs(node.members) do
    if m.record then
      keys_of(m.record, acc)
    else
      acc[#acc + 1] = m.key
    end
  end
  return acc
end

local function compute(root, overrides)
  local facts = facts_for(keys_of(root))
  for key, patch in pairs(overrides or {}) do
    if patch == false then
      facts[key] = nil
    elseif type(patch) == "function" then
      facts[key] = patch(vim.deepcopy(facts[key] or {}))
    else
      facts[key] = vim.tbl_extend("force", facts[key] or {}, patch)
    end
  end
  layout.compute({ root }, facts)
  return root
end

local function by_name(rec, name)
  for _, m in ipairs(rec.members) do
    if m.name == name then
      return m
    end
  end
  error("no member named " .. name)
end

local function packet()
  return record("record.packet", "struct", "Packet", {
    field("field.char_before_gap", "kind"),
    field("field.plain_int", "len"),
    field("field.pointer", "data"),
    field("field.multi_first", "b"),
    field("field.multi_second", "c"),
    field("field.func_pointer", "cb"),
    field("field.array", "buf"),
    field("field.double", "dbl"),
    field("field.nested_named", "inner"),
    field("field.bitfield_aligned", "flags", { is_bitfield = true }),
    field("field.bitfield_split", "more", { is_bitfield = true }),
    field("field.bitfield_last", "last", { is_bitfield = true }),
    field("field.trailing_pad", "tail"),
  })
end

local function anon()
  return record("record.anon", "struct", "Anon", {
    field("field.anon_head", "head"),
    field("field.anon_named_member", "anon_named"),
    anon_member(record("record.anon_struct_member", "struct", "(anonymous struct)", {
      field("field.in_anon_struct_first", "s1"),
      field("field.in_anon_struct", "s2"),
    })),
    anon_member(record("record.anon_union_member", "union", "(anonymous union)", {
      field("field.in_anon_union", "u1"),
      field("field.in_anon_union_arr", "u2"),
    })),
    field("field.anon_tail", "tailc"),
  })
end

describe("layout: a plain struct", function()
  local r = compute(packet())

  it("reports clangd's sizeof and alignment verbatim", function()
    truthy(r.trusted)
    eq(72 * B, r.size_bits)
    eq(8 * B, r.align_bits)
  end)

  it("reports each field's absolute offset", function()
    eq(0, by_name(r, "kind").abs_bits)
    eq(8 * B, by_name(r, "data").abs_bits)
    eq(56 * B, by_name(r, "inner").abs_bits)
    eq(66 * B, by_name(r, "tail").abs_bits)
  end)

  it("keeps a bitfield offset that is not byte aligned", function()
    eq(64 * B + 3, by_name(r, "more").abs_bits)
    eq(5, by_name(r, "more").size_bits)
  end)

  it("reports holes, including the trailing one", function()
    eq(3 * B, by_name(r, "kind").hole_bits)
    eq(0, by_name(r, "len").hole_bits)
    eq(6 * B, by_name(r, "buf").hole_bits)
    eq(7, by_name(r, "last").hole_bits, "bitfield run tail, in bits")
    eq(5 * B, by_name(r, "tail").hole_bits, "trailing padding of the record")
  end)

  it("totals the padding and the waste", function()
    eq(14 * B + 7, r.total_pad_bits)
    eq((14 * B + 7) / (72 * B) * 100, r.waste_pct)
  end)

  it("does not count a named nested record's internal padding", function()
    eq(8 * B, by_name(r, "inner").size_bits)
    eq(0, by_name(r, "inner").hole_bits)
  end)
end)

describe("layout: anonymous members", function()
  local r = compute(anon())

  it("places an anonymous member with no Offset of its own", function()
    local m = r.members[3]
    eq("anon_record", m.kind)
    eq(24 * B, m.abs_bits, "derived from where anon_named ended")
    eq(8 * B, m.size_bits)
  end)

  it("rebases an anonymous record's inner fields onto the outer record", function()
    local inner = r.members[3].record
    eq(4 * B, hover.parse(fixtures.samples["field.in_anon_struct"]).offset_bits)
    eq(28 * B, by_name(inner, "s2").abs_bits)
    eq(24 * B, by_name(inner, "s1").abs_bits)
  end)

  it("rebases an anonymous union's members too", function()
    local inner = r.members[4].record
    eq(32 * B, by_name(inner, "u1").abs_bits)
    eq(32 * B, by_name(inner, "u2").abs_bits, "union members all start together")
  end)

  it("totals the outer record without folding in the children's padding", function()
    truthy(r.trusted)
    eq(48 * B, r.size_bits)
    eq(11 * B, r.total_pad_bits, "4 after head + 7 after tailc; nothing from the children")
  end)

  it("accounts each anonymous record in its own frame", function()
    local inner = r.members[3].record
    truthy(inner.trusted)
    eq(8 * B, inner.size_bits)
    eq(3 * B, inner.total_pad_bits)
  end)

  it("requires base_bits explicitly", function()
    local ok = pcall(layout._annotate, anon(), {}, nil)
    falsy(ok, "annotate must refuse to default the base to zero")
  end)
end)

describe("layout: unions", function()
  local r = compute(record("record.union_tag", "union", "Tag", {
    field("field.union_int", "ui"),
    field("field.union_array", "uc"),
  }))

  it("starts every member at the union's own offset", function()
    eq(0, by_name(r, "ui").abs_bits)
    eq(0, by_name(r, "uc").abs_bits)
  end)

  it("renders each member's unused tail as slack, never as a hole", function()
    eq(4 * B, by_name(r, "ui").slack_bits)
    eq(1 * B, by_name(r, "uc").slack_bits)
    eq(nil, by_name(r, "ui").hole_bits)
    eq(nil, by_name(r, "ui").pad_bits)
  end)

  it("totals only what the largest member leaves behind", function()
    eq(7 * B, r.largest_bits)
    eq(1 * B, r.total_pad_bits)
  end)
end)

describe("layout: layouts we do not model", function()
  it("reconciles a #pragma pack(1) struct rather than giving up on it", function()
    local r = compute(record("record.packed", "struct", "Packed", {
      field("field.packed_char", "pc"),
      field("field.packed_int", "pi"),
    }))
    truthy(r.trusted)
    eq(5 * B, r.size_bits)
    eq(1 * B, by_name(r, "pi").abs_bits)
    eq(0, r.total_pad_bits)
    eq(0, r.waste_pct)
  end)

  it("survives a zero-sized record without dividing by it", function()
    local r = compute(record("record.empty", "struct", "Empty", {}))
    eq(0, r.size_bits)
    eq(0, r.total_pad_bits)
    eq(nil, r.waste_pct)
  end)

  it("refuses to total a record with a flexible array member", function()
    -- sizeof(FlexArr) excludes data[] so any waste figure would be incorrect.
    local r = compute(record("record.flexarr", "struct", "FlexArr", {
      field("field.flex_len", "n"),
      field("field.flex_array", "data"),
    }))
    truthy(r.incomplete)
    falsy(r.trusted)
    eq(nil, r.total_pad_bits)
    eq(4 * B, by_name(r, "data").abs_bits, "the offset is still known and still true")
  end)

  it("does not call a mid-record parse failure a flexible array", function()
    local r = compute(packet(), {
      ["field.array"] = function(f)
        f.size_bits = nil
        return f
      end,
    })
    falsy(r.trusted)
    falsy(r.incomplete, "only the last member can be a flexible array")
  end)

  it("handles a bitfield run that straddles a zero-width separator", function()
    local r = compute(record("record.bits", "struct", "Bits", {
      field("field.bits_b1", "b1", { is_bitfield = true }),
      field("field.bits_b2", "b2", { is_bitfield = true }),
    }))
    truthy(r.trusted)
    eq(8 * B, r.size_bits)
    eq(31, by_name(r, "b1").hole_bits)
    eq(28, by_name(r, "b2").hole_bits)
    eq(59, r.total_pad_bits)
  end)
end)

describe("layout: refusing to guess", function()
  it("drops every hole when a member's hover is missing", function()
    local r = compute(packet(), { ["field.array"] = false })
    falsy(r.trusted)
    eq(nil, r.total_pad_bits)
    eq(nil, r.waste_pct)
    eq(nil, by_name(r, "kind").hole_bits, "one bad member poisons the whole record")
  end)

  it("catches clangd's padding disagreeing with the walk", function()
    local r = compute(packet(), { ["field.char_before_gap"] = { pad_bits = 99 } })
    falsy(r.trusted)
    eq(nil, r.total_pad_bits)
  end)

  it("catches a record whose members do not add up to its sizeof", function()
    local r = compute(packet(), { ["record.packet"] = { size_bits = 999 * B } })
    falsy(r.trusted)
    eq(nil, r.total_pad_bits)
  end)

  it("catches a hover that answered about the wrong symbol", function()
    local r = compute(packet(), { ["record.packet"] = { name = "SomethingElse" } })
    falsy(r.trusted)
  end)

  it("keeps offsets and sizes even when the record is untrusted", function()
    -- Degrade to less information rather than wrong information.
    local r = compute(packet(), { ["record.packet"] = { size_bits = 999 * B } })
    eq(8 * B, by_name(r, "data").abs_bits)
    eq(8 * B, by_name(r, "data").size_bits)
  end)
end)
