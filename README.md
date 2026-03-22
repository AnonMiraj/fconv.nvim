# fconv.nvim

Convert between floating-point numbers and their hexadecimal representations.

Supports multiple floating-point standards:

*   **Float16 (Half)**: 16-bit (e.g., `0x3C00` -> `1.0`)
*   **Float32 (Single)**: 32-bit (e.g., `0x3F800000` -> `1.0`)
*   **Float64 (Double)**: 64-bit (e.g., `0x3FF0000000000000` -> `1.0`)
*   **Float80 (Extended)**: 80-bit (x86 Extended Precision)
*   **Float128 (Quad)**: 128-bit

## Features

*   **Real-time Virtual Text**: View converted values (hex -> float or float -> hex) next to the cursor.
*   **Toggle Conversion (`gs`)**: Replace the text under the cursor (or selection) with its converted equivalent.
*   **Copy to Clipboard (`gy`)**: Copy the converted value without modifying the buffer.
*   **Inspect Value (`gl`)**: Open a floating window with detailed breakdown (Sign, Exponent, Mantissa).
*   **Smart Parsing**:
    *   Handle C-style hex float literals (e.g., `0x1.5p-3`).
    *   Handle digit separators (e.g., `0x7fff'ffff`).
    *   Respect type suffixes (e.g., `1.0f` -> Float32, `1.0f16` -> Float16, `0x...L` -> Float80).
    *   Ignore plain integers (`42`) unless suffixed (`42f`, `42.0`).

## Installation

### using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "anonmiraj/fconv.nvim",
  config = function()
    require("fconv").setup({
       keymaps = {
           toggle = "gs",
           copy = "gy",
           inspect = "gl",
       }
    })
  end
}
```

## Configuration

Customize behavior by passing a table to `setup`.

```lua
require("fconv").setup({
  -- Highlight group for virtual text
  highlight_group = "DiagnosticInfo",

  -- Decimal precision for display
  format_precision = 8, 
  
  -- Default format for conversion (float16, float32, float64, float80, float128)
  default_format = "float64",

  keymaps = {
      toggle = "gs",  -- Toggle Hex/Float
      copy = "gy",    -- Copy converted value
      inspect = "gl", -- Inspect value in floating window
  }
})
```

## Usage

1.  **Cursor Movement**: Move the cursor over a hex string (`0x3C00`) or a float (`1.0`).
2.  **Virtual Text**: The converted value appears as virtual text at the end of the line.
3.  **Commands**:
    *   `gs`: Replace word/selection with converted value.
    *   `gy`: Yank converted value to clipboard (register `+`).
    *   `gl`: Inspect binary representation.

## Supported Formats & Suffixes

Detects format based on:

1.  **Hex Length**:
    *   4 hex digits (e.g., `0xFFFF`) -> Float16
    *   8 hex digits -> Float32
    *   16 hex digits -> Float64
    *   20 hex digits -> Float80
    *   32 hex digits -> Float128
2.  **Suffixes**:
    *   `f16` -> Float16
    *   `f` / `F` -> Float32
    *   (none) -> Float64 (default)
    *   `L` -> Float80
    *   `Q` / `f128` -> Float128
