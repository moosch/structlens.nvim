local locate = require("structlens.locate")
local corpus = dofile("tests/fixtures/hover_samples.lua").corpus

local function find(records, name)
  for _, r in ipairs(records) do
    if r.name == name then
      return r
    end
  end
  error("no record named " .. tostring(name))
end

local function names(record)
  local out = {}
  for _, m in ipairs(record.members) do
    out[#out + 1] = m.name or "<anon>"
  end
  return out
end

describe("locate: treesitter", function()
  local records = locate.from_string(corpus)

  it("finds only records that define a body", function()
    local found = {}
    for _, r in ipairs(records) do
      found[#found + 1] = r.name or "<anon>"
    end
    eq({ "Inner", "Packet", "Bits", "Anon", "Tag", "Packed", "Empty", "FlexArr", "<anon>" }, found)
  end)

  it("splits a multi-declarator line into separate members", function()
    local packet = find(records, "Packet")
    truthy(vim.tbl_contains(names(packet), "b"))
    truthy(vim.tbl_contains(names(packet), "c"))
    local b, c
    for _, m in ipairs(packet.members) do
      if m.name == "b" then b = m end
      if m.name == "c" then c = m end
    end
    eq(b.row, c.row, "int b, c; is one line")
    truthy(b.anchor[2] < c.anchor[2])
  end)

  it("digs the identifier out of a function pointer declarator", function()
    local packet = find(records, "Packet")
    truthy(vim.tbl_contains(names(packet), "cb"))
  end)

  it("marks bitfields", function()
    local bits = find(records, "Bits")
    eq({ "b1", "b2" }, names(bits))
    for _, m in ipairs(bits.members) do
      truthy(m.is_bitfield, m.name .. " should be a bitfield")
    end
  end)

  it("drops an unnamed bitfield instead of asking clangd about it", function()
    eq(2, #find(records, "Bits").members)
  end)

  it("treats a bare anonymous member as its own record", function()
    local anon = find(records, "Anon")
    eq({ "head", "anon_named", "<anon>", "<anon>", "tailc" }, names(anon))
    eq("anon_record", anon.members[3].kind)
    eq("struct", anon.members[3].record.kind)
    eq("union", anon.members[4].record.kind)
    eq(anon.members[3].key, anon.members[3].record.key, "member and record share one hover")
  end)

  it("treats an inline-defined type with a declarator as an ordinary field", function()
    -- `struct { long deep; } anon_named;` has a real Offset of its own.
    local anon = find(records, "Anon")
    local member = anon.members[2]
    eq("anon_named", member.name)
    eq("field", member.kind)
    truthy(member.record, "still descends into the inline type")
    eq({ "deep", "shallow" }, names(member.record))
  end)

  it("anchors a typedef'd anonymous struct on its keyword, not the alias", function()
    -- Hovering TD returns a type-alias with no Size at all.
    local td = records[#records]
    eq(nil, td.name)
    local line = vim.split(corpus, "\n")[td.anchor[1] + 1]
    eq("struct", line:sub(td.anchor[2] + 1, td.anchor[2] + 6))
  end)

  it("reports the closing line for the total anchor", function()
    local packet = find(records, "Packet")
    local line = vim.split(corpus, "\n")[packet.close_row + 1]
    eq("};", line)
  end)

  it("does not return a nested record at top level", function()
    eq(9, #records)
    for _, r in ipairs(records) do
      falsy(r.name == "(anonymous struct)", "nested record leaked to top level")
    end
  end)

  it("emits one anchor per node, with no duplicates", function()
    local anchors = locate.anchors(records)
    local seen = {}
    for _, a in ipairs(anchors) do
      falsy(seen[a.key], "duplicate anchor " .. a.key)
      seen[a.key] = true
    end
    eq(find(records, "Anon").key, locate.anchors({ find(records, "Anon") })[1].key,
      "the record itself comes before its members")
  end)
end)

describe("locate: documentSymbol", function()
  local function sym(kind, name, detail, sl, sc, el, ec, children)
    return {
      kind = kind, name = name, detail = detail,
      range = { start = { line = sl, character = 0 }, ["end"] = { line = el, character = ec } },
      selectionRange = { start = { line = sl, character = sc }, ["end"] = { line = sl, character = sc + #name } },
      children = children,
    }
  end

  local outer = sym(5, "Outer", "struct", 0, 7, 5, 1, {
    sym(8, "m", "char", 1, 7, 1, 9),
    sym(5, "(anonymous struct)", "struct", 2, 2, 2, 36, {
      sym(8, "deep", "long", 2, 16, 2, 20),
      sym(8, "shallow", "int", 2, 26, 2, 33),
    }),
    sym(8, "anon_named", "struct (unnamed)", 2, 37, 2, 47),
    sym(5, "(anonymous union)", "union", 3, 2, 3, 32, {
      sym(8, "u1", "int", 3, 14, 3, 16),
      sym(8, "u2", "char[7]", 3, 23, 3, 25),
    }),
    sym(8, "tail", "char", 4, 7, 4, 11),
  })

  local records = locate.from_document_symbols({ outer })

  it("reads a record off detail, not off SymbolKind", function()
    eq(1, #records)
    eq("struct", records[1].kind)
    eq("Outer", records[1].name)
    eq(5, records[1].close_row, "range.end.line is the closing brace")
  end)

  it("pairs an inline record with the field that declares it", function()
    eq({ "m", "anon_named", "(anonymous union)", "tail" }, names(records[1]))
    local named = records[1].members[2]
    eq("field", named.kind)
    eq("2:37", named.key, "hover the declarator, which has a real Offset")
    eq("2:2", named.record.key, "descend through the keyword hover")
  end)

  it("keeps a bare anonymous member as an anonymous record", function()
    local anon = records[1].members[3]
    eq("anon_record", anon.kind)
    eq("union", anon.record.kind)
    eq("3:2", anon.key)
  end)

  it("anchors every node where clangd will answer a hover", function()
    local anchors = locate.anchors(records)
    local keys = {}
    for _, a in ipairs(anchors) do
      keys[#keys + 1] = a.key
    end
    eq({ "0:7", "1:7", "2:37", "2:2", "2:16", "2:26", "3:2", "3:14", "3:23", "4:7" }, keys)
  end)

  it("skips the placeholder symbol clangd emits for an unnamed bitfield", function()
    local bits = locate.from_document_symbols({
      sym(23, "Bits", "struct", 0, 7, 4, 1, {
        sym(8, "b1", "unsigned int", 1, 15, 1, 17),
        sym(8, "(anonymous)", "int", 2, 2, 2, 5),
        sym(8, "b2", "unsigned int", 3, 15, 3, 17),
      }),
    })
    eq({ "b1", "b2" }, names(bits[1]))
  end)

  it("reads structs reported as either SymbolKind", function()
    for _, kind in ipairs({ 5, 23 }) do
      local r = locate.from_document_symbols({ sym(kind, "S", "struct", 0, 7, 1, 1, {}) })
      eq(1, #r, "kind " .. kind)
      eq("struct", r[1].kind)
    end
  end)

  it("ignores a SymbolInformation-shaped response rather than mangling it", function()
    eq({}, locate.from_document_symbols(nil))
    eq({}, locate.from_document_symbols({}))
    eq({}, locate.from_document_symbols({ { name = "x", kind = 12 } }))
  end)
end)

describe("locate: scoping", function()
  local records = locate.from_string(corpus)

  it("keeps only records overlapping a viewport", function()
    local packet = nil
    for _, r in ipairs(records) do
      if r.name == "Packet" then packet = r end
    end
    local kept = locate.within(records, packet.anchor[1], packet.close_row)
    truthy(#kept >= 1)
    for _, r in ipairs(kept) do
      truthy(r.anchor[1] <= packet.close_row and r.close_row >= packet.anchor[1])
    end
  end)

  it("finds the record the cursor is inside", function()
    local packet
    for _, r in ipairs(records) do
      if r.name == "Packet" then packet = r end
    end
    eq("Packet", locate.containing(records, packet.anchor[1] + 1)[1].name)
    eq({}, locate.containing(records, packet.close_row + 1))
  end)
end)
