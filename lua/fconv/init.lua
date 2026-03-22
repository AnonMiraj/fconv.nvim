-- fconv.nvim
-- Convert between floating point formats and hexadecimal.
-- Supports: Float16, Float32, Float64, Float80, Float128.

local M = {}
local ns = vim.api.nvim_create_namespace("fconv")
local enabled = true
local uv = vim.uv or vim.loop

-- Float formats definition
M.formats = {
	float16 = { name = "F16", bits = 16, exp_bits = 5, mant_bits = 10, bias = 15, key = "float16" },
	float32 = { name = "F32", bits = 32, exp_bits = 8, mant_bits = 23, bias = 127, key = "float32" },
	float64 = { name = "F64", bits = 64, exp_bits = 11, mant_bits = 52, bias = 1023, key = "float64" },
	float80 = {
		name = "F80",
		bits = 80,
		exp_bits = 15,
		mant_bits = 64,
		bias = 16383,
		explicit_int = true,
		key = "float80",
	},
	float128 = { name = "F128", bits = 128, exp_bits = 15, mant_bits = 112, bias = 16383, key = "float128" },
}

-- Default configuration
M.config = {
	highlight_group = "DiagnosticInfo",
	format_precision = 8,
	default_format = "float64",
}

-- Format float value. Ensure .0 for integers.
local function format_float(val)
	local s = string.format("%." .. M.config.format_precision .. "g", val)
	if not s:match("[%.eE]") then
		s = s .. ".0"
	end
	return s
end

-- Get Format from Hex Length
function M.get_format_from_hex(hex_val)
	local len = #hex_val
	if len <= 4 then
		return M.formats.float16
	elseif len <= 8 then
		return M.formats.float32
	elseif len <= 16 then
		return M.formats.float64
	elseif len <= 20 then
		return M.formats.float80
	elseif len <= 32 then
		return M.formats.float128
	else
		return M.formats.float64
	end -- Default
end

-- Hex to Binary string helper
local hex_map = {
	["0"] = "0000",
	["1"] = "0001",
	["2"] = "0010",
	["3"] = "0011",
	["4"] = "0100",
	["5"] = "0101",
	["6"] = "0110",
	["7"] = "0111",
	["8"] = "1000",
	["9"] = "1001",
	["A"] = "1010",
	["B"] = "1011",
	["C"] = "1100",
	["D"] = "1101",
	["E"] = "1110",
	["F"] = "1111",
	["a"] = "1010",
	["b"] = "1011",
	["c"] = "1100",
	["d"] = "1101",
	["e"] = "1110",
	["f"] = "1111",
}

local function hex_to_bin(hex)
	local bin = {}
	for i = 1, #hex do
		table.insert(bin, hex_map[hex:sub(i, i)] or "")
	end
	return table.concat(bin)
end

-- Binary string to Number (integer)
local function bin_to_int(bin)
	local n = 0
	for i = 1, #bin do
		if bin:sub(i, i) == "1" then
			n = n * 2 + 1
		else
			n = n * 2
		end
	end
	return n
end

-- Integer to binary string
local function int_to_bin(val, bits)
	local bin = ""
	val = math.floor(val)
	for _ = 1, bits do
		if val % 2 == 1 then
			bin = "1" .. bin
		else
			bin = "0" .. bin
		end
		val = math.floor(val / 2)
	end
	return bin
end

-- Convert binary string to hex string
local function bin_to_hex(bin)
	local hex = ""
	local bin_map_rev = {}
	for k, v in pairs(hex_map) do
		if not k:match("[a-f]") then -- avoid duplicates, prefer upper case
			bin_map_rev[v] = k
		end
	end

	-- Pad to multiple of 4
	local rem = #bin % 4
	if rem ~= 0 then
		bin = string.rep("0", 4 - rem) .. bin
	end

	for i = 1, #bin, 4 do
		local chunk = bin:sub(i, i + 3)
		hex = hex .. (bin_map_rev[chunk] or "?")
	end
	return hex
end

-- Parse float from binary string
local function parse_float_from_bin(bin, fmt)
	local expected_len = fmt.bits
	if #bin < expected_len then
		bin = string.rep("0", expected_len - #bin) .. bin
	elseif #bin > expected_len then
		bin = bin:sub(-expected_len)
	end

	local sign_bit = bin:sub(1, 1)
	local exp_str = bin:sub(2, 1 + fmt.exp_bits)
	local mant_str = bin:sub(2 + fmt.exp_bits, 2 + fmt.exp_bits + fmt.mant_bits)

	local sign = (sign_bit == "1") and -1 or 1
	local exp = bin_to_int(exp_str)

	local int_bit = "1"
	local frac_str = mant_str

	if fmt.explicit_int then
		int_bit = mant_str:sub(1, 1)
		frac_str = mant_str:sub(2)
	end

	local mant_val = 0
	-- Calculate mantissa value (fractional part)
	for i = 1, #frac_str do
		if frac_str:sub(i, i) == "1" then
			mant_val = mant_val + (0.5 ^ i)
		end
	end

	-- Handle Special Cases (Inf, NaN, Denormal)
	local max_exp = (2 ^ fmt.exp_bits) - 1

	if exp == max_exp then
		if mant_val ~= 0 then
			-- Simplified: Non-zero fraction = NaN
			return "NaN", "NaN"
		else
			if fmt.explicit_int and int_bit == "0" then
				return "NaN", "NaN" -- Pseudo-Infinity/Invalid
			end
			return (sign == 1 and "+inf" or "-inf"), "infinity"
		end
	end

	local value = 0
	if exp == 0 then
		-- Subnormal
		value = sign * (2 ^ (1 - fmt.bias)) * mant_val
	else
		-- Normal
		if fmt.explicit_int then
			local explicit_mantissa_val = (int_bit == "1" and 1 or 0) + mant_val
			value = sign * (2 ^ (exp - fmt.bias)) * explicit_mantissa_val
		else
			value = sign * (2 ^ (exp - fmt.bias)) * (1 + mant_val)
		end
	end

	return value, "normal"
end

-- Convert float value to hex string for target format
local function float_to_hex(val, fmt)
	-- Handle zero (and negative zero)
	if val == 0 then
		-- Check for negative zero: 1/x is -inf
		if 1 / val == -math.huge then
			local sign_part = "1"
			local rest_part = string.rep("0", fmt.bits - 1)
			-- For hex output, we need to be careful.
			-- Actually, simplest way for -0 is to construct it manually.
			-- Sign=1, Exp=0, Mant=0.
			return bin_to_hex(sign_part .. rest_part)
		end
		return string.rep("0", fmt.bits / 4)
	end

	local sign = (val < 0) and 1 or 0
	val = math.abs(val)

	if val == math.huge then
		local exp_part = string.rep("1", fmt.exp_bits)
		local mant_part = string.rep("0", fmt.mant_bits)
		if fmt.explicit_int then -- Inf for 80-bit usually 1...0
			mant_part = "1" .. string.rep("0", fmt.mant_bits - 1)
		end
		return bin_to_hex(sign .. exp_part .. mant_part)
	end

	if val ~= val then -- NaN
		local exp_part = string.rep("1", fmt.exp_bits)
		local mant_part = "1" .. string.rep("0", fmt.mant_bits - 1) -- QNaN
		if fmt.explicit_int then
			mant_part = "11" .. string.rep("0", fmt.mant_bits - 2)
		end
		return bin_to_hex(sign .. exp_part .. mant_part)
	end

	local m, e = math.frexp(val)
	-- m is [0.5, 1), we want 1.xxxx * 2^E
	-- 0.5 * 2^e = 1.0 * 2^(e-1)
	-- So normalized mantissa is m * 2, exponent is e - 1
	m = m * 2
	e = e - 1

	local biased_exp = e + fmt.bias

	-- Handle Underflow/Overflow roughly
	if biased_exp <= 0 then
		-- Subnormal handling (simplified)
		-- We need to shift mantissa right by (1 - biased_exp)
		local shift = 1 - biased_exp
		m = m / (2 ^ shift)
		biased_exp = 0
	elseif biased_exp >= (2 ^ fmt.exp_bits) - 1 then
		-- Overflow to Inf
		local exp_part = string.rep("1", fmt.exp_bits)
		local mant_part = string.rep("0", fmt.mant_bits)
		if fmt.explicit_int then
			mant_part = "1" .. string.rep("0", fmt.mant_bits - 1)
		end
		return bin_to_hex(sign .. exp_part .. mant_part)
	end

	local exp_bin = int_to_bin(biased_exp, fmt.exp_bits)
	local mant_bin = ""

	local frac = m
	if not fmt.explicit_int then
		frac = frac - 1.0 -- Remove implicit leading 1
	else
		-- For explicit int (Float80), the mantissa includes the integer bit (usually 1).
		-- Our loop below generates bits by multiplying by 2 and checking for >= 1.0.
		-- To handle the integer bit correctly using the same loop, we divide by 2
		-- effectively treating the number as 0.1xxxx... so the first bit extracted
		-- corresponds to the integer part 2^0.
		frac = frac / 2
	end

	-- Convert fraction to binary
	for _ = 1, fmt.mant_bits do
		frac = frac * 2
		if frac >= 1.0 then
			mant_bin = mant_bin .. "1"
			frac = frac - 1.0
		else
			mant_bin = mant_bin .. "0"
		end
	end

	return bin_to_hex(sign .. exp_bin .. mant_bin)
end

-- Get text target (word under cursor or visual selection)
local function get_text_target(is_visual)
	local line = vim.api.nvim_get_current_line()

	if is_visual then
		local _, r1, c1, _ = (table.unpack or unpack)(vim.fn.getpos("v"))
		local _, r2, c2, _ = (table.unpack or unpack)(vim.fn.getpos("."))

		if r1 ~= r2 then
			print("Multiline selection not supported")
			return nil, nil, nil
		end

		if c1 > c2 then
			c1, c2 = c2, c1
		end

		-- Handle line length safety
		if c2 > #line then
			c2 = #line
		end

		-- Return 0-based start, and exclusive end for API consistency
		return line:sub(c1, c2), c1 - 1, c2
	end

	local col = vim.api.nvim_win_get_cursor(0)[2]
	local start_col, end_col = col, col

	-- Expand selection for Hex or Float
	-- Allowed chars: hex digits, ., x, X, +, -, e, E, f, F, l, L, q, Q, 1, 2, 8 (for suffix f16, f128), ', p, P
	while start_col > 0 and line:sub(start_col, start_col):match("[%w%.%+%-']") do
		start_col = start_col - 1
	end
	while end_col <= #line and line:sub(end_col + 1, end_col + 1):match("[%w%.%+%-']") do
		end_col = end_col + 1
	end

	if start_col < end_col then
		if not line:sub(start_col, start_col):match("[%w%.%+%-']") then
			start_col = start_col + 1
		end
		local word = line:sub(start_col, end_col)

		-- Refine match:
		-- 1. Hex Bits: 0x... (allow ' and U/L/etc)
		-- 2. Hex Float Literal: 0x...p...
		-- 3. Decimal Float: 1.23...
		if
			word:match("^[%+%-]?0[xX][%x']+[uUlL]*$")
			or word:match("^[%+%-]?0[xX][%x%.']+[pP][%+%-]?%d+[fFlLqQ]*$")
			or word:match("^[%+%-]?%d*%.?%d+[eE]?[%+%-]?%d*[fFlLqQ%d]*$")
		then
			return word, start_col - 1, end_col
		end
	end
	return nil, nil, nil
end

local function clean_literal(word)
	-- Remove separators
	local clean = word:gsub("[']", "")

	if clean:match("^[+-]?0[xX].*[pP]") then
		-- Hex Float Literal: remove float suffix (f, l, q) from end so tonumber can parse
		clean = clean:gsub("[fFlLqQ]+$", "")
	elseif clean:match("^[+-]?0[xX]") then
		-- Hex Bits: remove int suffixes (u, U, l, L)
		clean = clean:gsub("[uUlL]+$", "")
	else
		-- Decimal Float: remove float suffixes
		clean = clean:gsub("[fFlLqQ]+%d*$", "")
	end
	return clean
end

local function detect_precision_from_suffix(word)
	if word:match("[fF]16$") then
		return M.formats.float16
	elseif word:match("[fF]32$") then
		return M.formats.float32
	elseif word:match("[fF]64$") then
		return M.formats.float64
	elseif word:match("[fF]128$") then
		return M.formats.float128
	elseif word:match("[qQ]$") then
		return M.formats.float128
	elseif word:match("[fF]$") then
		return M.formats.float32
	elseif word:match("[lL]$") then
		return M.formats.float80
	end
	return nil
end

local function clear_virtual_text()
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
end

function M.toggle_hex_float(opts)
	local is_visual = opts and opts.visual
	local word, start_col, end_col = get_text_target(is_visual)

	if is_visual then
		-- Exit visual mode so we can edit the buffer cleanly
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
	end

	if not word or word == "" or not start_col or not end_col then
		return
	end

	local clean_word = clean_literal(word)
	local result = ""

	-- Case 1: Hex Float Literal (e.g. 0x1.5p-3) -> Decimal Float
	if word:match("[pP]") and word:match("0[xX]") then
		local val = tonumber(clean_word)
		if val then
			local fmt = detect_precision_from_suffix(word)
			local suffix = ""
			if fmt then
				if fmt.bits == 16 then
					suffix = "f16"
				elseif fmt.bits == 32 then
					suffix = "f"
				elseif fmt.bits == 80 then
					suffix = "L"
				elseif fmt.bits == 128 then
					suffix = "Q"
				end
			end
			result = format_float(val) .. suffix
		end

		-- Case 2: Hex Bits (e.g. 0x3F800000) -> Decimal Float
	elseif word:match("^[%+%-]?0[xX]") and not word:match("[pP]") then
		local hex_val = clean_word:gsub("^[%+%-]?0[xX]", "")
		local fmt = M.get_format_from_hex(hex_val)
		if fmt then
			local bin_str = hex_to_bin(hex_val)
			local val, _ = parse_float_from_bin(bin_str, fmt)

			local suffix = ""
			if fmt.bits == 16 then
				suffix = "f16"
			elseif fmt.bits == 32 then
				suffix = "f"
			elseif fmt.bits == 80 then
				suffix = "L"
			elseif fmt.bits == 128 then
				suffix = "Q"
			end

			result = format_float(val) .. suffix
		end

		-- Case 3: Decimal Float (e.g. 1.0) -> Hex Bits
	elseif tonumber(clean_word) then
		local val = tonumber(clean_word)
		local fmt = detect_precision_from_suffix(word) or M.formats[M.config.default_format]

		if word:match("[%.eEfFlLqQ]") then
			result = "0x" .. float_to_hex(val, fmt)
		end
	end

	if result ~= "" then
		local cursor_pos = vim.api.nvim_win_get_cursor(0)
		local row = cursor_pos[1] - 1
		vim.api.nvim_buf_set_text(0, row, start_col, row, end_col, { result })
	end
end

function M.update_display()
	if not enabled then
		return
	end
	clear_virtual_text()

	-- Virtual text only works in normal mode for now
	local word, _, _ = get_text_target(false)
	if not word or word == "" then
		return
	end

	local clean_word = clean_literal(word)
	local text_to_display = ""

	-- Case 1: Hex Float Literal -> Value
	if word:match("[pP]") and word:match("0[xX]") then
		local val = tonumber(clean_word)
		if val then
			local formatted = format_float(val)
			text_to_display = string.format(" → %s (HexFloat)", formatted)
		end

		-- Case 2: Hex Bits -> Value
	elseif word:match("^[%+%-]?0[xX]") and not word:match("[pP]") then
		local hex_val = clean_word:gsub("^[%+%-]?0[xX]", "")
		local fmt = M.get_format_from_hex(hex_val)

		if fmt then
			local bin_str = hex_to_bin(hex_val)
			local val, _ = parse_float_from_bin(bin_str, fmt)

			if _G.type(val) == "string" then
				text_to_display = string.format(" → %s (%s)", val, fmt.name)
			else
				local formatted = format_float(val)
				text_to_display = string.format(" → %s (%s)", formatted, fmt.name)
			end
		end

		-- Case 3: Decimal Float -> Hex Bits
	elseif tonumber(clean_word) then
		local val = tonumber(clean_word)
		local fmt = detect_precision_from_suffix(word) or M.formats[M.config.default_format]

		-- Only convert if it looks like a float (has dot, exponent, or suffix)
		if word:match("[%.eEfFlLqQ]") then
			local hex = float_to_hex(val, fmt)
			text_to_display = string.format(" → 0x%s (%s)", hex, fmt.name)
		end
	end

	if text_to_display ~= "" then
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		vim.api.nvim_buf_set_extmark(0, ns, row, -1, {
			virt_text = { { text_to_display, M.config.highlight_group } },
			hl_mode = "combine",
		})
	end
end

local timer = nil
local function debounce_update()
	if timer then
		timer:stop()
	end
	timer = uv.new_timer()
	timer:start(
		50,
		0,
		vim.schedule_wrap(function()
			if enabled then
				M.update_display()
			end
		end)
	)
end

function M.convert_and_copy(opts)
	local is_visual = opts and opts.visual
	local word, _, _ = get_text_target(is_visual)
	if not word or word == "" then
		return
	end

	if is_visual then
		-- Exit visual mode
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
	end

	local clean_word = clean_literal(word)
	local result = ""

	if word:match("[pP]") and word:match("0[xX]") then
		local val = tonumber(clean_word)
		if val then
			result = format_float(val)
		end
	elseif word:match("^[%+%-]?0[xX]") then
		local hex_val = clean_word:gsub("^[%+%-]?0[xX]", "")
		local fmt = M.get_format_from_hex(hex_val)
		if fmt then
			local bin_str = hex_to_bin(hex_val)
			local val, _ = parse_float_from_bin(bin_str, fmt)
			result = format_float(val)
		end
	elseif tonumber(clean_word) then
		local val = tonumber(clean_word)
		local fmt = detect_precision_from_suffix(word) or M.formats[M.config.default_format]

		if word:match("[%.eEfFlLqQ]") then
			result = "0x" .. float_to_hex(val, fmt)
		end
	end

	if result ~= "" then
		vim.fn.setreg("+", result)
		print("Copied: " .. result)
	else
		print("No valid float/hex found")
	end
end

local function create_floating_window(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local width = 0
	for _, line in ipairs(lines) do
		width = math.max(width, #line)
	end
	local height = #lines

	local opts = {
		relative = "cursor",
		row = 1,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
	}

	local win = vim.api.nvim_open_win(buf, true, opts)

	-- Close on q or Esc
	local close_win = function()
		vim.api.nvim_win_close(win, true)
	end
	vim.keymap.set("n", "q", close_win, { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", close_win, { buffer = buf, nowait = true })
	return buf, win
end

function M.inspect_float(opts)
	local is_visual = opts and opts.visual
	local word, _, _ = get_text_target(is_visual)
	if not word or word == "" then
		print("No float/hex found under cursor/selection")
		return
	end

	if is_visual then
		-- Exit visual mode
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
	end

	local clean_word = clean_literal(word)
	local fmt = nil
	local val = nil
	local hex_val = ""

	-- Identify format and value
	if word:match("[pP]") and word:match("0[xX]") then
		-- Hex Float Literal
		val = tonumber(clean_word)
		fmt = detect_precision_from_suffix(word) or M.formats[M.config.default_format]
		if val then
			hex_val = float_to_hex(val, fmt)
		end
	elseif word:match("^[%+%-]?0[xX]") then
		-- Hex Bits
		hex_val = clean_word:gsub("^[%+%-]?0[xX]", "")
		fmt = M.get_format_from_hex(hex_val)
		local bin = hex_to_bin(hex_val)
		val, _ = parse_float_from_bin(bin, fmt)
	elseif tonumber(clean_word) then
		-- Decimal
		val = tonumber(clean_word)
		fmt = detect_precision_from_suffix(word) or M.formats[M.config.default_format]

		if word:match("[%.eEfFlLqQ]") then
			hex_val = float_to_hex(val, fmt)
		end
	end

	if not fmt or hex_val == "" then
		print("Could not parse value")
		return
	end

	local bin_str = hex_to_bin(hex_val)

	-- Parse components manually for display
	local expected_len = fmt.bits
	if #bin_str < expected_len then
		bin_str = string.rep("0", expected_len - #bin_str) .. bin_str
	elseif #bin_str > expected_len then
		bin_str = bin_str:sub(-expected_len)
	end

	local sign_bit = bin_str:sub(1, 1)
	local exp_str = bin_str:sub(2, 1 + fmt.exp_bits)
	local mant_str = bin_str:sub(2 + fmt.exp_bits, 2 + fmt.exp_bits + fmt.mant_bits)

	local sign_val = (sign_bit == "1") and "-" or "+"
	local exp_val = bin_to_int(exp_str)
	local unbiased_exp = exp_val - fmt.bias

	-- Calculate float value (if val not already set or for consistency)
	if not val then
		val, _ = parse_float_from_bin(bin_str, fmt)
	end

	local val_str = ""
	if type(val) == "string" then
		val_str = val
	else
		val_str = format_float(val)
	end

	-- Mantissa display
	local mant_val = 0
	for i = 1, #mant_str do
		if mant_str:sub(i, i) == "1" then
			mant_val = mant_val + (0.5 ^ i)
		end
	end
	local mant_disp = string.format("%.10f", mant_val):gsub("0+$", ""):gsub("%.$", "")
	if mant_disp == "" then
		mant_disp = "0"
	end

	local lines = {
		string.format("Format:   %s", fmt.name),
		string.format("Value:    %s", val_str),
		string.format("Hex:      0x%s", hex_val),
		string.format("Binary:   %s %s %s", sign_bit, exp_str, mant_str),
		string.rep("-", 40),
		string.format("Sign:     %s (%s)", sign_val, sign_bit),
		string.format("Exponent: %d (0x%X) -> Unbiased: %d", exp_val, exp_val, unbiased_exp),
		string.format("Mantissa: %s (Fraction)", mant_disp),
	}

	local buf, _ = create_floating_window(lines)

	-- Highlights
	local exp_len = #exp_str
	local mant_len = #mant_str

	vim.api.nvim_buf_set_extmark(buf, ns, 3, 10, { end_col = 11, hl_group = "FloatViewerSign" })
	vim.api.nvim_buf_set_extmark(buf, ns, 3, 12, { end_col = 12 + exp_len, hl_group = "FloatViewerExp" })
	vim.api.nvim_buf_set_extmark(
		buf,
		ns,
		3,
		13 + exp_len,
		{ end_col = 13 + exp_len + mant_len, hl_group = "FloatViewerMant" }
	)

	vim.api.nvim_buf_set_extmark(buf, ns, 5, 10, { end_col = #lines[6], hl_group = "FloatViewerSign" })
	vim.api.nvim_buf_set_extmark(buf, ns, 6, 10, { end_col = #lines[7], hl_group = "FloatViewerExp" })
	vim.api.nvim_buf_set_extmark(buf, ns, 7, 10, { end_col = #lines[8], hl_group = "FloatViewerMant" })
end

function M.init()
	vim.api.nvim_create_user_command("FloatViewerCopy", function(cmd_opts)
		if cmd_opts.range > 0 then
			M.convert_and_copy({ visual = true })
		else
			M.convert_and_copy()
		end
	end, { range = true })

	vim.api.nvim_create_user_command("FloatViewerToggle", function(cmd_opts)
		if cmd_opts.range > 0 then
			M.toggle_hex_float({ visual = true })
		else
			M.toggle_hex_float()
		end
	end, { range = true })

	vim.api.nvim_create_user_command("FloatViewerInspect", function(cmd_opts)
		if cmd_opts.range > 0 then
			M.inspect_float({ visual = true })
		else
			M.inspect_float()
		end
	end, { range = true })
end

function M.setup(opts)
	opts = opts or {}
	M.config = vim.tbl_deep_extend("force", M.config, opts)

	-- Always enable auto update
	vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
		group = vim.api.nvim_create_augroup("FloatViewerAuto", { clear = true }),
		callback = debounce_update,
	})

	-- Init commands
	M.init()

	-- Highlights for inspection
	vim.api.nvim_set_hl(0, "FloatViewerSign", { link = "Number", default = true })
	vim.api.nvim_set_hl(0, "FloatViewerExp", { link = "Function", default = true })
	vim.api.nvim_set_hl(0, "FloatViewerMant", { link = "String", default = true })

	-- Optional Keymaps
	if opts.keymaps then
		-- Default keys
		local keys = opts.keymaps
		if type(keys) ~= "table" then
			keys = {}
		end

		local toggle = keys.toggle or "gs"
		local copy = keys.copy or "gy"
		local inspect = keys.inspect or "gl"

		vim.keymap.set("n", toggle, M.toggle_hex_float, { desc = "Toggle Float/Hex (Buffer)" })
		vim.keymap.set("x", toggle, function()
			M.toggle_hex_float({ visual = true })
		end, { desc = "Toggle Float/Hex (Selection)" })

		vim.keymap.set("n", copy, M.convert_and_copy, { desc = "Copy Converted Float/Hex" })
		vim.keymap.set("x", copy, function()
			M.convert_and_copy({ visual = true })
		end, { desc = "Copy Converted Float/Hex (Selection)" })

		vim.keymap.set("n", inspect, M.inspect_float, { desc = "Inspect Float/Hex" })
		vim.keymap.set("x", inspect, function()
			M.inspect_float({ visual = true })
		end, { desc = "Inspect Float/Hex (Selection)" })
	end
end

-- Export private functions for testing
M._private = {
	hex_to_bin = hex_to_bin,
	bin_to_hex = bin_to_hex,
	bin_to_int = bin_to_int,
	int_to_bin = int_to_bin,
	parse_float_from_bin = parse_float_from_bin,
	float_to_hex = float_to_hex,
	format_float = format_float,
}

return M
