local config = require("structlens.config")
local highlight = require("structlens.highlight")
local hover = require("structlens.hover")
local locate = require("structlens.locate")
local lsp = require("structlens.lsp")
local marks = require("structlens.marks")

local M = {}

local AUGROUP = "structlens"

---@param bufnr integer
---@return boolean
local function is_target(bufnr)
  return vim.tbl_contains(config.options.filetypes, vim.bo[bufnr].filetype)
end

--- In "manual" mode a buffer stays quiet until it is switched on; the other
--- modes are on for every matching buffer.
---@param bufnr integer
---@return boolean
local function is_on(bufnr)
  if not is_target(bufnr) then
    return false
  end
  if config.options.mode == "manual" then
    return vim.b[bufnr].structlens_on == true
  end
  return vim.b[bufnr].structlens_on ~= false
end

---@param bufnr integer
---@return table opts for lsp.refresh
local function scope_opts(bufnr)
  if config.options.mode == "cursor" then
    return { scope = "cursor", row = vim.api.nvim_win_get_cursor(0)[1] - 1 }
  end
  return { scope = "viewport" }
end

---@param bufnr integer?
function M.refresh(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if is_target(bufnr) then
    lsp.refresh(bufnr, scope_opts(bufnr))
  end
end

---@param bufnr integer?
function M.enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.b[bufnr].structlens_on = true
  M.refresh(bufnr)
end

---@param bufnr integer?
function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  vim.b[bufnr].structlens_on = false
  lsp.clear(bufnr)
end

---@param bufnr integer?
function M.toggle(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if is_on(bufnr) then
    M.disable(bufnr)
  else
    M.enable(bufnr)
  end
end

---@param mode string
function M.set_mode(mode)
  config.setup(vim.tbl_extend("force", config.options, { mode = mode }))
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and is_target(bufnr) then
      marks.clear(bufnr)
      if is_on(bufnr) then
        M.refresh(bufnr)
      end
    end
  end
end

--- Dump what both locators see and what clangd actually said, for the record
--- under the cursor. The first thing to reach for when a number looks wrong.
function M.debug()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local client = lsp.client(bufnr)
  local out = {
    "# structlens debug",
    "",
    ("buffer %d, filetype %s, row %d"):format(bufnr, vim.bo[bufnr].filetype, row + 1),
    ("client: %s"):format(client and (client.name .. " (" .. client.offset_encoding .. ")") or "NONE ATTACHED"),
    ("mode: %s   on: %s"):format(config.options.mode, tostring(is_on(bufnr))),
    "",
  }

  local function dump_tree(label, records)
    out[#out + 1] = "## " .. label .. (" (%d top-level records)"):format(#records)
    local function walk(record, indent)
      out[#out + 1] = ("%s%s %s  anchor=%s close=%d"):format(
        indent, record.kind, record.name or "<anonymous>", record.key, record.close_row
      )
      for _, member in ipairs(record.members) do
        out[#out + 1] = ("%s  . %-14s %-11s anchor=%s%s"):format(
          indent, member.name or "<anonymous>", member.kind, member.key, member.is_bitfield and " bitfield" or ""
        )
        if member.record then
          walk(member.record, indent .. "    ")
        end
      end
    end
    for _, record in ipairs(records) do
      walk(record, "")
    end
    out[#out + 1] = ""
  end

  local function show()
    vim.cmd("vnew")
    local scratch = vim.api.nvim_get_current_buf()
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].bufhidden = "wipe"
    vim.bo[scratch].filetype = "markdown"
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, out)
  end

  dump_tree("treesitter", locate.from_treesitter(bufnr))

  if not client then
    show()
    return
  end

  client:request("textDocument/documentSymbol", {
    textDocument = vim.lsp.util.make_text_document_params(bufnr),
  }, function(err, result)
    local records = err and {} or locate.from_document_symbols(result)
    dump_tree("documentSymbol", records)

    local target = locate.containing(records, row)
    if #target == 0 then
      out[#out + 1] = "No record under the cursor; no hovers to show."
      show()
      return
    end

    local anchors = locate.anchors(target)
    out[#out + 1] = ("## raw hovers (%d anchors)"):format(#anchors)
    local remaining = #anchors
    for _, anchor in ipairs(anchors) do
      client:request("textDocument/hover", {
        textDocument = vim.lsp.util.make_text_document_params(bufnr),
        position = { line = anchor.row, character = anchor.col },
      }, function(_, hover_result)
        local value = hover.contents_value(hover_result)
        out[#out + 1] = ("### anchor %s"):format(anchor.key)
        if value then
          vim.list_extend(out, vim.split(value, "\n"))
        else
          out[#out + 1] = "<null>"
        end
        out[#out + 1] = ""
        remaining = remaining - 1
        if remaining == 0 then
          show()
        end
      end, bufnr)
    end
  end, bufnr)
end

---@param opts table?
function M.setup(opts)
  config.setup(opts)
  highlight.setup()

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })

  vim.api.nvim_create_autocmd("LspAttach", {
    desc = "structlens: annotate once clangd is attached",
    group = group,
    callback = function(event)
      if is_on(event.buf) then
        lsp.schedule(event.buf, scope_opts(event.buf))
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI", "InsertLeave", "WinScrolled" }, {
    desc = "structlens: refresh annotations",
    group = group,
    callback = function(event)
      if config.options.mode ~= "cursor" and is_on(event.buf) then
        lsp.schedule(event.buf, scope_opts(event.buf))
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorHold", {
    desc = "structlens: annotate the record under the cursor",
    group = group,
    callback = function(event)
      if config.options.mode == "cursor" and is_on(event.buf) then
        -- updatetime already debounces this; going through schedule() would
        -- only add lag.
        lsp.refresh(event.buf, scope_opts(event.buf))
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
    desc = "structlens: drop per-buffer state",
    group = group,
    callback = function(event)
      lsp.forget(event.buf)
    end,
  })

  vim.api.nvim_create_user_command("StructLens", function()
    M.enable()
  end, { desc = "Annotate struct field sizes in this buffer" })

  vim.api.nvim_create_user_command("StructLensToggle", function()
    M.toggle()
  end, { desc = "Toggle struct size annotations in this buffer" })

  vim.api.nvim_create_user_command("StructLensClear", function()
    M.disable()
  end, { desc = "Clear struct size annotations in this buffer" })

  vim.api.nvim_create_user_command("StructLensMode", function(cmd)
    M.set_mode(cmd.args)
  end, {
    nargs = 1,
    desc = "Set structlens mode",
    complete = function()
      return { "manual", "always", "cursor" }
    end,
  })

  vim.api.nvim_create_user_command("StructLensDebug", function()
    M.debug()
  end, { desc = "Dump structlens locator trees and raw clangd hovers" })

  return M
end

return M
