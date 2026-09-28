-- Talks to clangd and drives a refresh to completion.
--
-- Shape of one refresh: bump an epoch, ask for documentSymbol, turn that into a
-- record tree (or fall back to treesitter), then fire one hover per node and
-- wait for all of them before painting anything.
--
-- Measured against clangd 21.1.8, which is why there is no retry and no
-- timeout here:
--   * a hover fired before the TU is parsed still answers, in tens of
--     milliseconds. A nil result means "no symbol here", never "not ready".
--   * a didChange against in-flight hovers returns ContentModified for all of
--     them within a millisecond, so clangd cancels on our behalf.
--   * 40 warm hovers complete in about 11ms, so the request count is not worth
--     optimising.

local config = require("structlens.config")
local hover = require("structlens.hover")
local layout = require("structlens.layout")
local locate = require("structlens.locate")
local marks = require("structlens.marks")
local render = require("structlens.render")

local M = {}

local CONTENT_MODIFIED = -32801
local REQUEST_CANCELLED = -32800
local REAP_MS = 5000

---@type table<integer, table>
local state = {}
M._state = state

---@param bufnr integer
---@return table
local function state_for(bufnr)
  if not state[bufnr] then
    state[bufnr] = { epoch = 0, pending = {}, inflight = {}, debounce = 0 }
  end
  return state[bufnr]
end

---@param bufnr integer
---@return vim.lsp.Client?
function M.client(bufnr)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })
  local client = clients[1]
  if client and client:supports_method("textDocument/hover", bufnr) then
    return client
  end
  return nil
end

---@param st table
local function cancel_inflight(st)
  for _, entry in pairs(st.inflight) do
    for _, id in ipairs(entry.ids) do
      pcall(function()
        entry.client:cancel_request(id)
      end)
    end
  end
  st.inflight = {}
end

function M.clear(bufnr)
  local st = state_for(bufnr)
  st.epoch = st.epoch + 1
  cancel_inflight(st)
  st.pending = {}
  marks.clear(bufnr)
end

--- Convert a byte column to the client's position encoding.
---@param bufnr integer
---@param row integer
---@param col integer
---@param encoding string
---@return integer
local function character_of(bufnr, row, col, encoding)
  local ok, character = pcall(vim.lsp.util.character_offset, bufnr, row, col, encoding)
  return ok and character or col
end

---@param bufnr integer
---@param records table[]
---@param opts table
---@return table[]
local function scope_records(bufnr, records, opts)
  local cfg = config.options
  if opts.scope == "cursor" then
    local row = opts.row or (vim.api.nvim_win_get_cursor(0)[1] - 1)
    return locate.containing(records, row)
  end
  if opts.scope == "viewport" and cfg.viewport_only then
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      local first = vim.fn.line("w0", win) - 1 - cfg.viewport_margin
      local last = vim.fn.line("w$", win) - 1 + cfg.viewport_margin
      return locate.within(records, math.max(first, 0), last)
    end
  end
  return records
end

---@param bufnr integer
---@param epoch integer
local function finish(bufnr, epoch)
  local st = state_for(bufnr)
  local job = st.pending[epoch]
  st.pending[epoch] = nil
  st.inflight[epoch] = nil
  if not job then
    return
  end
  -- Final staleness gates. clangd covers the case where an edit beats the
  -- response; these cover the case where every answer arrives correct and the
  -- buffer changes before we get to paint.
  if epoch ~= st.epoch or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b[bufnr].changedtick ~= job.tick then
    return
  end

  local records = layout.compute(job.records, job.facts)

  local missed, total = 0, 0
  for _, fact in pairs(job.facts) do
    total = total + 1
    if fact == false then
      missed = missed + 1
    end
  end
  if total > 0 and missed / total > 0.2 then
    -- A loud wrong number once beats a silent wrong number forever: if the
    -- hover format ever changes, say so instead of rendering blanks.
    vim.notify_once(
      ("structlens: %d/%d hovers did not parse. clangd's hover format may have changed; "):format(missed, total)
        .. "regenerate tests/fixtures with tests/capture.lua.",
      vim.log.levels.WARN
    )
  end

  local errors = vim.diagnostic.get(bufnr, { severity = vim.diagnostic.severity.ERROR })
  local reason = render.no_layout_reason(records, #errors, errors[1] and errors[1].message)
  if reason then
    vim.notify_once(reason, vim.log.levels.WARN)
  end

  marks.apply(bufnr, render.marks(records, config.options), config.options)
end

---@param bufnr integer
---@param epoch integer
---@param client vim.lsp.Client
---@param records table[]
local function request_hovers(bufnr, epoch, client, records)
  local st = state_for(bufnr)
  local cfg = config.options
  local anchors = locate.anchors(records)

  if #anchors == 0 then
    marks.clear(bufnr)
    return
  end
  if #anchors > cfg.max_fields then
    return
  end

  local job = {
    records = records,
    facts = {},
    want = #anchors,
    got = 0,
    tick = vim.b[bufnr].changedtick,
  }
  st.pending[epoch] = job
  st.inflight[epoch] = { client = client, ids = {} }

  local text_document = vim.lsp.util.make_text_document_params(bufnr)
  for _, anchor in ipairs(anchors) do
    local params = {
      textDocument = text_document,
      position = {
        line = anchor.row,
        character = character_of(bufnr, anchor.row, anchor.col, client.offset_encoding),
      },
    }
    local ok, id = client:request("textDocument/hover", params, function(err, result)
      if st.pending[epoch] ~= job then
        return
      end
      if err and (err.code == CONTENT_MODIFIED or err.code == REQUEST_CANCELLED) then
        st.pending[epoch] = nil
        st.inflight[epoch] = nil
        return
      end
      job.facts[anchor.key] = hover.parse(hover.contents_value(result)) or false
      job.got = job.got + 1
      if job.got >= job.want then
        finish(bufnr, epoch)
      end
    end, bufnr)
    if ok and id then
      table.insert(st.inflight[epoch].ids, id)
    else
      job.want = job.want - 1
    end
  end

  if job.want <= 0 then
    st.pending[epoch] = nil
    st.inflight[epoch] = nil
    return
  end
  if job.got >= job.want then
    finish(bufnr, epoch)
  end

  -- Not a retry and not a timeout: every request terminates one way or another.
  -- This only stops a dropped response leaking the job table forever.
  vim.defer_fn(function()
    if state_for(bufnr).pending[epoch] == job then
      state_for(bufnr).pending[epoch] = nil
      state_for(bufnr).inflight[epoch] = nil
    end
  end, REAP_MS)
end

--- Run one refresh of `bufnr`.
---@param bufnr integer
---@param opts table? { scope = "buffer"|"viewport"|"cursor", row = integer? }
function M.refresh(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr ~= 0 and bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local st = state_for(bufnr)
  st.epoch = st.epoch + 1
  local epoch = st.epoch
  cancel_inflight(st)
  st.pending = {}

  local client = M.client(bufnr)
  if not client then
    marks.clear(bufnr)
    return
  end

  client:request("textDocument/documentSymbol", {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
  }, function(err, result)
    if epoch ~= st.epoch or not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local records = {}
    if not err then
      records = locate.from_document_symbols(result)
    end
    if #records == 0 then
      records = locate.from_treesitter(bufnr)
      if #records == 0 and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1] then
        local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
        if text:match("%f[%w]struct%f[%W]") or text:match("%f[%w]union%f[%W]") then
          -- Both locators came up empty on a buffer that plainly has records.
          -- Most likely the treesitter grammar moved under us.
          vim.notify_once("structlens: no records found in a buffer containing struct/union", vim.log.levels.DEBUG)
        end
      end
    end
    records = scope_records(bufnr, records, opts)
    if #records == 0 then
      marks.clear(bufnr)
      return
    end
    request_hovers(bufnr, epoch, client, records)
  end, bufnr)
end

--- Debounced refresh. The token, not a libuv timer, is what makes a superseded
--- call a no-op -- so there is no handle to close on BufUnload.
---@param bufnr integer
---@param opts table?
function M.schedule(bufnr, opts)
  local st = state_for(bufnr)
  st.debounce = st.debounce + 1
  local token = st.debounce
  vim.defer_fn(function()
    if state_for(bufnr).debounce == token and vim.api.nvim_buf_is_valid(bufnr) then
      M.refresh(bufnr, opts)
    end
  end, config.options.debounce_ms)
end

function M.forget(bufnr)
  state[bufnr] = nil
end

return M
