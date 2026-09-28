local hover = require("structlens.hover")
local fixtures = dofile("tests/fixtures/hover_samples.lua")

local function parse(key)
  local value = fixtures.samples[key]
  assert(value ~= nil, "no such fixture: " .. key)
  if value == false then
    return nil
  end
  return hover.parse(value)
end

describe("hover.qty_to_bits", function()
  it("reads whole bytes, singular and plural", function()
    eq(8, hover.qty_to_bits("1 byte"))
    eq(32, hover.qty_to_bits("4 bytes"))
    eq(0, hover.qty_to_bits("0 bytes"))
  end)

  it("reads sub-byte quantities", function()
    eq(1, hover.qty_to_bits("1 bit"))
    eq(31, hover.qty_to_bits("31 bits"))
  end)

  it("reads the split bitfield offset form", function()
    eq(64 * 8 + 3, hover.qty_to_bits("64 bytes and 3 bits"))
    eq(8 + 1, hover.qty_to_bits("1 byte and 1 bit"))
  end)

  it("returns nil rather than zero on anything unrecognised", function()
    -- A zero here would print "0 B @0" on every field of every struct.
    eq(nil, hover.qty_to_bits("4 octets"))
    eq(nil, hover.qty_to_bits("Alignment: 4 bytes"))
    eq(nil, hover.qty_to_bits(""))
    eq(nil, hover.qty_to_bits(nil))
    eq(nil, hover.qty_to_bits(4))
  end)
end)

describe("hover.parse", function()
  it("reads a plain field", function()
    local f = parse("field.plain_int")
    eq("field", f.kind)
    eq("len", f.name)
    eq("unsigned int", f.type)
    eq(4 * 8, f.offset_bits)
    eq(4 * 8, f.size_bits)
    eq(nil, f.pad_bits)
    eq(4 * 8, f.align_bits)
    eq("struct Packet", f.scope)
  end)

  it("peels the padding clause off the size line", function()
    local f = parse("field.char_before_gap")
    eq(1 * 8, f.size_bits)
    eq(3 * 8, f.pad_bits)
    eq(1 * 8, f.align_bits)
  end)

  it("reads alignment off the size line, not an Alignment paragraph", function()
    local f = parse("field.pointer")
    eq(8 * 8, f.align_bits)
    falsy(f.raw:match("\nAlignment:"), "fixture unexpectedly has an Alignment paragraph")
  end)

  it("reads a record", function()
    local f = parse("record.packet")
    eq("struct", f.kind)
    eq("Packet", f.name)
    eq(72 * 8, f.size_bits)
    eq(8 * 8, f.align_bits)
    eq(nil, f.offset_bits, "records never carry an Offset line")
    truthy(hover.is_record(f))
  end)

  it("reads an anonymous record hovered on its keyword", function()
    local f = parse("record.anon_union_member")
    eq("union", f.kind)
    eq("(anonymous union)", f.name)
    eq(8 * 8, f.size_bits)
    eq("struct Anon", f.scope)
  end)

  it("reads a bitfield size in bits", function()
    local f = parse("field.bitfield_aligned")
    eq(64 * 8, f.offset_bits)
    eq(3, f.size_bits)
    eq(4 * 8, f.align_bits)
  end)

  it("reads a bitfield offset that is not byte aligned", function()
    local f = parse("field.bitfield_split")
    eq(64 * 8 + 3, f.offset_bits)
    eq(5, f.size_bits)
  end)

  it("reads bitfield padding in bits", function()
    local f = parse("field.bits_b1")
    eq(1, f.size_bits)
    eq(31, f.pad_bits)
  end)

  it("reports no offset for a union member", function()
    local named = parse("field.union_int")
    eq(nil, named.offset_bits)
    eq(4 * 8, named.size_bits)
    eq(4 * 8, named.pad_bits, "this is the member's own slack, not a hole")
    eq("union Tag", named.scope)

    local anon = parse("field.in_anon_union")
    eq(nil, anon.offset_bits)
    eq("struct Anon::(anonymous union)", anon.scope)
  end)

  it("reports an anon member's inner field relative to the anon record", function()
    local f = parse("field.in_anon_struct")
    eq(4 * 8, f.offset_bits)
    eq("struct Anon::(anonymous struct)", f.scope)
  end)

  it("reports no size for a flexible array member", function()
    local f = parse("field.flex_array")
    eq("char[]", f.type)
    eq(4 * 8, f.offset_bits)
    eq(nil, f.size_bits)
  end)

  it("reports a zero-size record without choking", function()
    local f = parse("record.empty")
    eq(0, f.size_bits)
    eq(1 * 8, f.align_bits)
  end)

  it("gives a typedef name no size, so it is never a record anchor", function()
    local f = parse("typedef.name")
    eq("type-alias", f.kind)
    eq(nil, f.size_bits)
    falsy(hover.is_record(f))
  end)

  it("respects #pragma pack rather than modelling alignment", function()
    eq(1 * 8, parse("field.packed_int").offset_bits)
    eq(5 * 8, parse("record.packed").size_bits)
  end)

  it("returns nil for input that is not a hover body", function()
    eq(nil, hover.parse(nil))
    eq(nil, hover.parse(""))
    eq(nil, hover.parse("Size: 4 bytes"), "no ### header means no symbol")
  end)
end)

describe("hover.contents_value", function()
  it("reads MarkupContent", function()
    eq("x", hover.contents_value({ contents = { kind = "markdown", value = "x" } }))
  end)
  it("reads a bare string", function()
    eq("x", hover.contents_value({ contents = "x" }))
  end)
  it("reads a MarkedString list", function()
    eq("a\nb", hover.contents_value({ contents = { "a", { language = "c", value = "b" } } }))
  end)
  it("returns nil for anything else", function()
    eq(nil, hover.contents_value(nil))
    eq(nil, hover.contents_value({}))
    eq(nil, hover.contents_value({ contents = {} }))
  end)
end)

describe("fixture corpus", function()
  it("reconciles every captured struct: sum(size + pad) == sizeof", function()
    local records = {
      ["record.packet"] = {
        "field.char_before_gap", "field.plain_int", "field.pointer",
        "field.multi_first", "field.multi_second", "field.func_pointer",
        "field.array", "field.double", "field.nested_named",
        "field.bitfield_aligned", "field.bitfield_split", "field.bitfield_last",
        "field.trailing_pad",
      },
      ["record.bits"] = { "field.bits_b1", "field.bits_b2" },
      ["record.packed"] = { "field.packed_char", "field.packed_int" },
      ["record.inner"] = {},
    }
    for record_key, field_keys in pairs(records) do
      if #field_keys > 0 then
        local total = 0
        for _, k in ipairs(field_keys) do
          local f = parse(k)
          total = total + f.size_bits + (f.pad_bits or 0)
        end
        eq(parse(record_key).size_bits, total, record_key)
      end
    end
  end)
end)
