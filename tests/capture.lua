-- Regenerate tests/fixtures/hover_samples.lua.
--
--   nvim --clean -l tests/capture.lua [path/to/clangd] > tests/fixtures/hover_samples.lua

local uv = vim.uv or vim.loop

local CORPUS = [[
struct Inner { int p; short q; };

struct Packet {
  unsigned char kind;
  unsigned int  len;
  char         *data;
  int           b, c;
  void        (*cb)(int);
  char          buf[10];
  double        dbl;
  struct Inner  inner;
  unsigned int  flags : 3;
  unsigned int  more  : 5;
  unsigned int  last  : 1;
  char          tail;
};

struct Bits {
  unsigned int b1 : 1;
  int             : 0;
  unsigned int b2 : 4;
};

struct Anon {
  int head;
  struct { long deep; int shallow; } anon_named;
  struct { char s1; int s2; };
  union { int u1; char u2[7]; };
  char tailc;
};

union Tag {
  int  ui;
  char uc[7];
};

#pragma pack(push, 1)
struct Packed {
  char pc;
  int  pi;
};
#pragma pack(pop)

struct Empty { };

struct FlexArr {
  int  n;
  char data[];
};

typedef struct { int t1; char t2; } TD;
]]

local PROBES = {
  { "record.packet", "struct Packet" },
  { "record.inner", "struct Inner {" },
  { "record.bits", "struct Bits" },
  { "record.anon", "struct Anon" },
  { "record.union_tag", "union Tag" },
  { "record.packed", "struct Packed" },
  { "record.empty", "struct Empty" },
  { "record.flexarr", "struct FlexArr" },
  { "record.typedef_anon", "struct { int t1;" },
  { "record.anon_struct_member", "struct { char s1;" },
  { "record.anon_union_member", "union { int u1;" },
  { "record.anon_named_type", "struct { long deep;" },

  { "field.char_before_gap", "kind;" },
  { "field.plain_int", "len;" },
  { "field.pointer", "data;" },
  { "field.multi_first", "b, c;" },
  { "field.multi_second", " c;", 1 },
  { "field.func_pointer", "cb)(int)" },
  { "field.array", "buf[10]" },
  { "field.double", "dbl;" },
  { "field.nested_named", "inner;" },
  { "field.bitfield_aligned", "flags : 3" },
  { "field.bitfield_split", "more  : 5" },
  { "field.bitfield_last", "last  : 1" },
  { "field.trailing_pad", "tail;" },

  { "field.bits_b1", "b1 : 1" },
  { "field.bits_b2", "b2 : 4" },

  { "field.anon_head", "head;" },
  { "field.anon_named_member", "anon_named;" },
  { "field.in_anon_named", "shallow;" },
  { "field.in_anon_struct_first", "s1;" },
  { "field.in_anon_struct", "s2;" },
  { "field.in_anon_union", "u1;" },
  { "field.in_anon_union_arr", "u2[7]" },
  { "field.anon_tail", "tailc;" },

  { "field.union_int", "ui;" },
  { "field.union_array", "uc[7]" },

  { "field.packed_char", "pc;" },
  { "field.packed_int", "pi;" },

  { "field.flex_len", "int  n;", 5 },
  { "field.flex_array", "data[];" },

  { "typedef.name", "TD;" },
}

local function die(msg)
  io.stderr:write("capture: " .. msg .. "\n")
  os.exit(1)
end

--- Byte offset of a substring that must be unique as a 0-indexed (row, col).
local function locate(text, needle, offset)
  local first = text:find(needle, 1, true)
  if not first then
    die("probe substring not found: " .. needle)
  end
  if text:find(needle, first + 1, true) then
    die("probe substring is not unique: " .. needle)
  end
  first = first + (offset or 0)
  local prefix = text:sub(1, first - 1)
  local _, newlines = prefix:gsub("\n", "")
  local line_start = (prefix:find("\n[^\n]*$") or 0) + 1
  return newlines, first - line_start
end

local clangd = arg and arg[1] or "clangd"

local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
local handle
handle = uv.spawn(clangd, {
  args = { "--log=error" },
  stdio = { stdin, stdout, nil },
}, function()
  if handle then
    handle:close()
  end
end)
if not handle then
  die("could not spawn " .. clangd)
end

local next_id = 0
local function send(msg)
  local body = vim.json.encode(msg)
  stdin:write(("Content-Length: %d\r\n\r\n%s"):format(#body, body))
end
local function request(method, params)
  next_id = next_id + 1
  send({ jsonrpc = "2.0", id = next_id, method = method, params = params })
  return next_id
end

local inbox, responses = "", {}
stdout:read_start(function(err, chunk)
  assert(not err, err)
  if not chunk then
    return
  end
  inbox = inbox .. chunk
  while true do
    local header_end = inbox:find("\r\n\r\n", 1, true)
    if not header_end then
      return
    end
    local len = tonumber(inbox:sub(1, header_end):match("[Cc]ontent%-[Ll]ength: (%d+)"))
    if not len or #inbox < header_end + 3 + len then
      return
    end
    local body = inbox:sub(header_end + 4, header_end + 3 + len)
    inbox = inbox:sub(header_end + 4 + len)
    local ok, msg = pcall(vim.json.decode, body)
    if ok and type(msg) == "table" and msg.id then
      responses[msg.id] = msg
    end
  end
end)

local function pump(predicate, timeout_ms)
  local deadline = uv.now() + timeout_ms
  while not predicate() do
    uv.run("once")
    uv.update_time()
    if uv.now() > deadline then
      die("timed out waiting for clangd")
    end
  end
end

local URI = "file:///structlens/capture.c"

local init_id = request("initialize", {
  processId = vim.NIL,
  rootUri = vim.NIL,
  capabilities = {
    general = { positionEncodings = { "utf-16" } },
    textDocument = { hover = { contentFormat = { "markdown" } } },
  },
})
pump(function()
  return responses[init_id] ~= nil
end, 30000)

send({ jsonrpc = "2.0", method = "initialized", params = vim.empty_dict() })
send({
  jsonrpc = "2.0",
  method = "textDocument/didOpen",
  params = {
    textDocument = { uri = URI, languageId = "c", version = 1, text = CORPUS },
  },
})

local ids = {}
for _, probe in ipairs(PROBES) do
  local key, needle, offset = probe[1], probe[2], probe[3]
  local row, col = locate(CORPUS, needle, offset)
  ids[key] = request("textDocument/hover", {
    textDocument = { uri = URI },
    position = { line = row, character = col },
  })
end

pump(function()
  for _, id in pairs(ids) do
    if responses[id] == nil then
      return false
    end
  end
  return true
end, 60000)

local function quote(s)
  return '"' .. s:gsub("[\\\"]", "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r") .. '"'
end

local out = {}
out[#out + 1] = "-- GENERATED by tests/capture.lua against a real clangd. Do not hand-edit."
out[#out + 1] = "-- Regenerate after every clangd upgrade and diff the result."
out[#out + 1] = "return {"
out[#out + 1] = "  corpus = " .. quote(CORPUS) .. ","
out[#out + 1] = "  samples = {"
for _, probe in ipairs(PROBES) do
  local key = probe[1]
  local result = responses[ids[key]].result
  local value = result and result.contents and result.contents.value or nil
  out[#out + 1] = ("    [%s] = %s,"):format(quote(key), value and quote(value) or "false")
end
out[#out + 1] = "  },"
out[#out + 1] = "}"
io.write(table.concat(out, "\n"), "\n")

stdin:close()
stdout:read_stop()
os.exit(0)
