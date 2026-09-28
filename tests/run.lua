-- Minimal test runner. No plenary, no plugin manager, no rtp setup:
--
--   nvim --clean -l tests/run.lua
--
-- Exits non-zero on any failure, so it drops straight into CI.

package.path = "./lua/?.lua;./lua/?/init.lua;./tests/?.lua;" .. package.path

local passes, failures, scope = 0, {}, {}

function describe(name, fn)
  scope[#scope + 1] = name
  fn()
  scope[#scope] = nil
end

function it(name, fn)
  local trail = table.concat(scope, " > ") .. " > " .. name
  local ok, err = pcall(fn)
  if ok then
    passes = passes + 1
  else
    failures[#failures + 1] = trail .. "\n      " .. tostring(err):gsub("\n", "\n      ")
  end
end

local function render(v)
  if type(v) == "table" then
    return vim.inspect(v):gsub("%s+", " ")
  end
  return tostring(v)
end

function eq(expected, actual, msg)
  local same = expected == actual
  if not same and type(expected) == "table" and type(actual) == "table" then
    same = vim.deep_equal(expected, actual)
  end
  if not same then
    error(("%sexpected %s, got %s"):format(msg and (msg .. ": ") or "", render(expected), render(actual)), 2)
  end
end

function truthy(v, msg)
  if not v then
    error((msg or "expected truthy") .. ", got " .. render(v), 2)
  end
end

function falsy(v, msg)
  if v then
    error((msg or "expected falsy") .. ", got " .. render(v), 2)
  end
end

-- hover.lua and layout.lua carry the entire numeric risk surface, and they are
-- only testable headless for as long as they stay free of Neovim. Enforce it.
local IMPURE = { init = true, config = true, locate = true, lsp = true, marks = true, highlight = true }

describe("purity", function()
  for _, path in ipairs(vim.fn.glob("lua/structlens/*.lua", false, true)) do
    local name = path:match("([^/]+)%.lua$")
    if not IMPURE[name] then
    it(name .. ".lua touches no vim API", function()
      local f = assert(io.open(path, "r"))
      local src = f:read("*a")
      f:close()
      local lineno = 0
      for line in (src .. "\n"):gmatch("(.-)\n") do
        lineno = lineno + 1
        local code = line:gsub("%-%-.*$", "")
        if code:match("[^%w_]vim%.") or code:match("^vim%.") then
          error(("%s:%d references vim.*: %s"):format(path, lineno, line))
        end
      end
    end)
    end
  end
end)

for _, spec in ipairs(vim.fn.glob("tests/*_spec.lua", false, true)) do
  dofile(spec)
end

for _, failure in ipairs(failures) do
  io.write("FAIL  ", failure, "\n")
end
io.write(("\n%d passed, %d failed\n"):format(passes, #failures))
os.exit(#failures == 0 and 0 or 1)
