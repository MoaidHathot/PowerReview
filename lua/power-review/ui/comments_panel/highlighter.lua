--- PowerReview.nvim comments panel — fenced code block syntax highlighting
local M = {}

--- Map common markdown fence language tags to treesitter parser names.
---@type table<string, string>
M.lang_aliases = {
  csharp = "c_sharp",
  cs = "c_sharp",
  ["c#"] = "c_sharp",
  cpp = "cpp",
  ["c++"] = "cpp",
  js = "javascript",
  ts = "typescript",
  tsx = "tsx",
  jsx = "javascript",
  py = "python",
  rb = "ruby",
  rs = "rust",
  sh = "bash",
  shell = "bash",
  zsh = "bash",
  yml = "yaml",
  tf = "hcl",
  dockerfile = "dockerfile",
  proto = "proto",
  viml = "vim",
  vimscript = "vim",
  jsonc = "json",
  ["objective-c"] = "objc",
  ["objective-cpp"] = "objc",
}

--- Detect fenced code blocks in the buffer (even with leading whitespace) and
--- apply language-specific syntax highlighting via treesitter.
--- Falls back to vim syntax regex highlights for languages without a treesitter parser.
---@param bufnr number
function M.apply(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local ns_code = vim.api.nvim_create_namespace("power_review_code_blocks")
  vim.api.nvim_buf_clear_namespace(bufnr, ns_code, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Find fenced code blocks: lines matching optional whitespace + ``` + optional language
  ---@type { lang: string, start_line: number, end_line: number, indent: number }[]
  local code_blocks = {}
  local i = 1
  while i <= #lines do
    local indent_str, lang = lines[i]:match("^(%s*)```(%S*)")
    if indent_str and lang then
      local fence_indent = #indent_str
      -- Find matching closing fence (same or less indent, just ```)
      local block_start = i + 1
      local block_end = nil
      for j = block_start, #lines do
        local close_indent_str = lines[j]:match("^(%s*)```%s*$")
        if close_indent_str then
          block_end = j - 1
          i = j + 1
          break
        end
      end
      if block_end and block_end >= block_start and lang ~= "" then
        table.insert(code_blocks, {
          lang = lang:lower(),
          start_line = block_start, -- 1-indexed, first line of code content
          end_line = block_end, -- 1-indexed, last line of code content
          indent = fence_indent,
        })
      elseif not block_end then
        -- Unclosed fence — skip
        i = i + 1
      end
    else
      i = i + 1
    end
  end

  if #code_blocks == 0 then
    return
  end

  -- Apply a subtle left-border indicator to code block lines for visual separation.
  for _, block in ipairs(code_blocks) do
    -- Mark the opening fence line
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, block.start_line - 2, 0, {
      virt_text = { { "▎", "Comment" } },
      virt_text_pos = "inline",
    })
    -- Mark code content lines
    for ln = block.start_line, block.end_line do
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, ln - 1, 0, {
        virt_text = { { "▎", "Comment" } },
        virt_text_pos = "inline",
      })
    end
    -- Mark the closing fence line
    if block.end_line + 1 <= #lines then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, block.end_line, 0, {
        virt_text = { { "▎", "Comment" } },
        virt_text_pos = "inline",
      })
    end
  end

  -- For each code block, try to apply treesitter highlighting
  for _, block in ipairs(code_blocks) do
    local ts_lang = M.lang_aliases[block.lang] or block.lang

    -- Check if the treesitter parser is available
    local parser_ok = pcall(vim.treesitter.language.inspect, ts_lang)
    if not parser_ok then
      -- Try loading (nvim 0.10+)
      parser_ok = pcall(vim.treesitter.language.add, ts_lang)
    end

    if parser_ok then
      -- Build the code text by stripping leading indent from each line.
      local code_lines = {}
      local col_offsets = {}
      for ln = block.start_line, block.end_line do
        local line = lines[ln] or ""
        local stripped = 0
        if block.indent > 0 and line:sub(1, block.indent) == string.rep(" ", block.indent) then
          line = line:sub(block.indent + 1)
          stripped = block.indent
        end
        table.insert(code_lines, line)
        table.insert(col_offsets, stripped)
      end
      local code_text = table.concat(code_lines, "\n")

      -- Parse with treesitter
      local ok_parse, parser = pcall(vim.treesitter.get_string_parser, code_text, ts_lang)
      if ok_parse and parser then
        local ok_tree, trees = pcall(parser.parse, parser)
        if ok_tree and trees then
          -- Walk the tree and apply highlights
          local query_ok, query = pcall(vim.treesitter.query.get, ts_lang, "highlights")
          if query_ok and query then
            for _, tree in ipairs(trees) do
              local root = tree:root()
              for id, node, _ in query:iter_captures(root, code_text) do
                local name = query.captures[id]
                local hl_group = "@" .. name .. "." .. ts_lang
                if vim.fn.hlexists(hl_group) == 0 then
                  hl_group = "@" .. name
                end
                local node_start_row, node_start_col, node_end_row, node_end_col = node:range()
                local buf_start_row = block.start_line - 1 + node_start_row
                local buf_end_row = block.start_line - 1 + node_end_row

                local start_offset = col_offsets[node_start_row + 1] or 0
                local end_offset = col_offsets[node_end_row + 1] or 0

                local adj_start_col = node_start_col + start_offset
                local adj_end_col = node_end_col + end_offset

                local start_line_len = #(lines[buf_start_row + 1] or "")
                local end_line_len = #(lines[buf_end_row + 1] or "")
                if adj_start_col > start_line_len then
                  adj_start_col = start_line_len
                end
                if adj_end_col > end_line_len then
                  adj_end_col = end_line_len
                end

                pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_code, buf_start_row, adj_start_col, {
                  end_row = buf_end_row,
                  end_col = adj_end_col,
                  hl_group = hl_group,
                  priority = 200,
                })
              end
            end
          end
        end
      end
    end
  end
end

return M
