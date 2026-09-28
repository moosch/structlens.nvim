# structlens.nvim

Inline memory-layout annotations for C structs, the way git blame lens shows last commit inline with virtual text on every field and a `sizeof` summary on the struct's closing line.

```c
struct Thing {
  unsigned char kind;                  1 B @0 +3 B pad
  unsigned int  len;                   4 B @4
  char         *data;                  8 B @8
  unsigned int  flags : 3;             3b @16
  unsigned int  more  : 5;             5b @16+3b
  union { int u1; char u2[7]; };       8 B @24  4 B @24 +4 B slack  7 B @24 +1 B slack
  char          tail;                  1 B @32 +7 B pad
};                                     sizeof=40 align=8 10 B pad (25%)
```

**NOTE**: C only. C++ classes, base subobjects, vtables and templates don't work.

## How are sizes calculated?

The plugin models none of C's layout rules itself, so things like `#pragma pack`, `__attribute__((packed, aligned))`, typedefs, bitfields and nested records should all be correct. The sizes come directly from `clangd` via `textDocument/hover`, and the gaps and percentages are simply calculated.

```
sum over direct members of (size + padding) == sizeof(record)
```

**NOTE**: This is meant as a _guide_, it's not always 100% accurate yet.

## Requirements

- Neovim 0.11+
- clangd attached to the buffer (developed against 21.1.8)
- Optional `compile_commands.json` for anything with non-trivial include paths

Treesitter is used as a fallback, but that's all. There are no other depencencies.

## Install

lazy.nvim:

```lua
{
  "moosch/structlens.nvim",
  ft = "c",
  cmd = { "StructLens", "StructLensToggle", "StructLensMode" },
  opts = {},
}
```

## Commands

| Command | Effect |
| --- | --- |
| `:StructLens` | Annotate this buffer |
| `:StructLensToggle` | Toggle annotations in this buffer |
| `:StructLensClear` | Remove annotations from this buffer |
| `:StructLensMode {manual\|always\|cursor}` | Change when annotations appear |
| `:StructLensDebug` | Dump both locator trees and clangd's raw hovers for the record under the cursor |

## Configuration

Defaults:

```lua
require("structlens").setup({
  mode = "manual",        -- "manual" | "always" | "cursor"
  filetypes = { "c" },
  holes = "inline",       -- "inline" ("1 B @0 +3 B pad") | "virt_lines" ("⋯ 3 B hole ⋯")
  units = "auto",         -- "auto" | "bytes" | "bits"
  show_offset = true,
  show_total = true,
  waste_threshold = 25,   -- percent, above which the total line is highlighted
  debounce_ms = 200,
  max_fields = 512,
  max_row_width = 80,
  viewport_only = true,   -- mode = "always" only
  viewport_margin = 50,
  priority = 100,
})
```

- `manual` does nothing until `:StructLens` or `:StructLensToggle`.
- `always` annotates every C buffer and is scoped to the viewport.
- `cursor` annotates only the record the cursor is inside on `CursorHold`.

Highlight groups, all `default`-linked so a colorscheme can override them:

`StructLensSize`, `StructLensOffset`, `StructLensPad`, `StructLensSlack`, `StructLensHole`, `StructLensTotal`, `StructLensWaste`.

## Reading the annotations

| Text | Meaning |
| --- | --- |
| `4 B @8` | 4 bytes, at offset 8 from the start of the outermost record |
| `5b @16+3b` | a bitfield: 5 bits, starting 3 bits into byte 16 |
| `+3 B pad` | 3 bytes the compiler inserted after this field |
| `+4 B slack` | a **union** member's unused tail. |
| `sizeof=40 align=8 10 B pad (25%)` | the record's size, alignment, padding and waste |
| `sizeof=4 align=4 (flexible array)` | the record ends in a flexible array member so `sizeof` excludes |
| `sizeof=8 align=4` with no padding term | the record did not reconcile or has no padding |

Offsets inside an anonymous `struct`/`union` member are added to the enclosing record, so they match `offsetof`.

## Nothing shows up?

`clang` cannot lay out a record that contains an unresolved type so any unknown struct member type strips the size and offset off every member.

General things to check:

- The type really is missing an `#include` in this file.
- There is no `compile_commands.json` entry for this file, so clangd never sees the project's include paths. Point clangd at one or add  `compile_flags.txt`.
- Run `:StructLensDebug`, it prints clangd's raw hover for every member so a hover with a `Type:` but no `Size:` is immediately visible.

Self-referential structs (`struct node { struct node *next; };`) are fine and need no special handling.

## Tests

```
nvim --clean -l tests/run.lua
```

Regenerate `clangd` fixtures after a `clangd` upgrade and diff:

```
nvim --clean -l tests/capture.lua /path/to/clangd > tests/fixtures/hover_samples.lua
```

