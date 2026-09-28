local M = {}

M.defaults = {
  -- "manual": nothing happens until :StructLens / :StructLensToggle.
  -- "always": annotate every C buffer, debounced.
  -- "cursor": annotate only the record the cursor is inside.
  mode = "manual",
  filetypes = { "c" },
  -- "inline" folds a hole into the preceding field's text ("1 B @0 +3 B pad");
  -- "virt_lines" gives it its own line underneath.
  holes = "inline",
  units = "auto", -- "auto" | "bytes" | "bits"
  show_offset = true,
  show_total = true,
  waste_threshold = 25, -- percent, above which the total line is highlighted
  debounce_ms = 200,
  max_fields = 512,
  max_row_width = 80,
  hole_indent = "  ",
  viewport_only = true, -- mode = "always" only
  viewport_margin = 50,
  priority = 100,
}

M.options = vim.deepcopy(M.defaults)

local ENUMS = {
  mode = { manual = true, always = true, cursor = true },
  holes = { inline = true, virt_lines = true },
  units = { auto = true, bytes = true, bits = true },
}

---@param opts table?
---@return table options
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  for key, allowed in pairs(ENUMS) do
    if not allowed[merged[key]] then
      vim.notify(
        ("structlens: invalid %s=%q, falling back to %q"):format(key, tostring(merged[key]), M.defaults[key]),
        vim.log.levels.WARN
      )
      merged[key] = M.defaults[key]
    end
  end
  M.options = merged
  return M.options
end

return M
