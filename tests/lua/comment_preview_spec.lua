--- Tests for power-review.ui.comment_preview
--- Pure Lua module — no Neovim runtime needed.
local preview = require("power-review.ui.comment_preview")

-- ============================================================================
-- Test fixtures
-- ============================================================================

local function make_session()
  return {
    id = "test_session",
    pr_id = 42,
    threads = {
      {
        id = 101,
        file_path = "src/main.lua",
        line_start = 10,
        status = "active",
        comments = {
          {
            author = "reviewer1",
            body = "Please refactor this function",
            created_at = "2025-01-15T10:30:00Z",
            is_deleted = false,
          },
          {
            author = "dev",
            body = "Done, thanks!",
            created_at = "2025-01-16T08:00:00Z",
            is_deleted = false,
          },
        },
      },
    },
    drafts = {
      {
        id = "d1",
        file_path = "src/main.lua",
        line_start = 10,
        line_end = 15,
        body = "Consider using a helper function here",
        status = "draft",
        author = "ai",
        thread_id = 101,
        created_at = "2025-01-17T00:00:00Z",
      },
      {
        id = "d2",
        file_path = "src/utils.lua",
        line_start = 5,
        body = "Typo in variable name",
        status = "pending",
        author = "user",
        created_at = "2025-01-18T00:00:00Z",
      },
    },
  }
end

-- ============================================================================
-- format_time
-- ============================================================================

describe("format_time", function()
  it("extracts date from ISO timestamp", function()
    assert.equal("2025-01-15", preview.format_time("2025-01-15T10:30:00Z"))
  end)

  it("returns empty string for nil input", function()
    assert.equal("", preview.format_time(nil))
  end)

  it("returns empty string for empty input", function()
    assert.equal("", preview.format_time(""))
  end)

  it("handles non-standard format by returning first 19 chars", function()
    local result = preview.format_time("not-a-date-but-long-enough-string")
    assert.equal("not-a-date-but-long", result)
  end)
end)

-- ============================================================================
-- status_icons
-- ============================================================================

describe("status_icons", function()
  it("has entries for all standard statuses", function()
    local expected = { "active", "fixed", "wontfix", "closed", "bydesign", "pending", "draft", "submitted" }
    for _, status in ipairs(expected) do
      assert.is_string(preview.status_icons[status], string.format("Missing icon for status '%s'", status))
    end
  end)
end)

-- ============================================================================
-- build (thread)
-- ============================================================================

describe("build (thread item)", function()
  it("returns lines and highlights for a thread", function()
    local session = make_session()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      status = "active",
      author = "reviewer1",
      body = "Please refactor",
      thread_id = 101,
      created_at = "2025-01-15T10:30:00Z",
    }

    local lines, hls = preview.build(item, session)
    assert.is_table(lines)
    assert.is_table(hls)
    assert.truthy(#lines > 0, "Should produce at least one line")
    assert.truthy(#hls > 0, "Should produce at least one highlight")
  end)

  it("includes the file path in output", function()
    local session = make_session()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      status = "active",
      thread_id = 101,
      author = "reviewer1",
      body = "test",
      created_at = "",
    }

    local lines, _ = preview.build(item, session)
    local found = false
    for _, line in ipairs(lines) do
      if line:find("src/main.lua", 1, true) then
        found = true
        break
      end
    end
    assert.truthy(found, "File path should appear in output")
  end)

  it("shows all non-deleted comments from full thread", function()
    local session = make_session()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      status = "active",
      thread_id = 101,
      author = "reviewer1",
      body = "Please refactor",
      created_at = "2025-01-15T10:30:00Z",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("reviewer1"), "Should show first comment author")
    assert.truthy(text:find("dev"), "Should show reply author")
    assert.truthy(text:find("Done, thanks"), "Should show reply body")
  end)

  it("shows reply drafts if any exist for the thread", function()
    local session = make_session()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      status = "active",
      thread_id = 101,
      author = "reviewer1",
      body = "Please refactor",
      created_at = "",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("Draft Replies"), "Should show draft replies section")
  end)

  it("handles range comments in header", function()
    local session = make_session()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      line_end = 20,
      status = "active",
      thread_id = 999, -- non-existent, will use fallback
      author = "tester",
      body = "Range comment",
      created_at = "2025-01-01T00:00:00Z",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("L10%-20"), "Should show range L10-20")
  end)
end)

-- ============================================================================
-- build (draft)
-- ============================================================================

describe("build (draft item)", function()
  it("returns lines and highlights for a draft", function()
    local session = make_session()
    local item = {
      kind = "draft",
      file_path = "src/utils.lua",
      line_start = 5,
      status = "pending",
      author = "user",
      body = "Typo in variable name",
      draft_id = "d2",
      created_at = "2025-01-18T00:00:00Z",
    }

    local lines, hls = preview.build(item, session)
    assert.is_table(lines)
    assert.truthy(#lines > 0)
  end)

  it("shows AI label for AI-authored drafts", function()
    local session = make_session()
    local item = {
      kind = "draft",
      file_path = "src/main.lua",
      line_start = 10,
      status = "draft",
      author = "ai",
      body = "AI suggestion",
      draft_id = "d1",
      created_at = "",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    -- The AI label uses nerd font icon, just check "ai" appears
    assert.truthy(text:find("ai"), "Should show AI author")
  end)

  it("shows draft status", function()
    local session = make_session()
    local item = {
      kind = "draft",
      file_path = "src/utils.lua",
      line_start = 5,
      status = "pending",
      author = "user",
      body = "test body",
      draft_id = "d2",
      created_at = "",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("PENDING"), "Should show status in uppercase")
  end)

  it("handles empty body", function()
    local session = make_session()
    local item = {
      kind = "draft",
      file_path = "src/main.lua",
      line_start = 1,
      status = "draft",
      author = "user",
      body = "",
      draft_id = "dx",
      created_at = "",
    }

    local lines, _ = preview.build(item, session)
    local text = table.concat(lines, "\n")
    assert.truthy(text:find("%(empty%)"), "Should show (empty) for empty body")
  end)
end)

-- ============================================================================
-- build_items
-- ============================================================================

describe("build_items", function()
  it("combines threads and drafts into a unified list", function()
    local session = make_session()
    local mock_get_all_threads = function(s)
      return {
        {
          id = 101,
          type = "remote",
          file_path = "src/main.lua",
          line_start = 10,
          status = "active",
          comments = {
            { author = "reviewer1", body = "Please refactor", created_at = "2025-01-15T10:30:00Z" },
          },
        },
      }
    end

    local items = preview.build_items(session, mock_get_all_threads)
    -- 1 thread + 2 drafts = 3 items
    assert.equal(3, #items)
  end)

  it("skips threads without file_path", function()
    local session = { drafts = {}, threads = {} }
    local mock_get_all_threads = function(_)
      return {
        { id = 1, type = "remote", file_path = nil, status = "active", comments = {} },
        { id = 2, type = "remote", file_path = "a.lua", line_start = 1, status = "active", comments = {} },
      }
    end

    local items = preview.build_items(session, mock_get_all_threads)
    assert.equal(1, #items)
    assert.equal("a.lua", items[1].file_path)
  end)

  it("skips draft-type threads", function()
    local session = { drafts = {}, threads = {} }
    local mock_get_all_threads = function(_)
      return {
        { id = 1, type = "draft", file_path = "a.lua", status = "active", comments = {} },
        { id = 2, type = "remote", file_path = "b.lua", line_start = 1, status = "active", comments = {} },
      }
    end

    local items = preview.build_items(session, mock_get_all_threads)
    assert.equal(1, #items)
    assert.equal("b.lua", items[1].file_path)
  end)

  it("sets correct fields for thread items", function()
    local session = { drafts = {}, threads = {} }
    local mock_get_all_threads = function(_)
      return {
        {
          id = 42,
          type = "remote",
          file_path = "foo.lua",
          line_start = 5,
          line_end = 10,
          status = "fixed",
          comments = {
            { author = "alice", body = "Fix this", created_at = "2025-01-01T00:00:00Z" },
            { author = "bob", body = "Done", created_at = "2025-01-02T00:00:00Z" },
          },
        },
      }
    end

    local items = preview.build_items(session, mock_get_all_threads)
    assert.equal(1, #items)
    local item = items[1]
    assert.equal("thread", item.kind)
    assert.equal("foo.lua", item.file_path)
    assert.equal(5, item.line_start)
    assert.equal(10, item.line_end)
    assert.equal("fixed", item.status)
    assert.equal("alice", item.author)
    assert.equal("Fix this", item.body)
    assert.equal(1, item.reply_count) -- 2 comments - 1 = 1 reply
    assert.equal(42, item.thread_id)
  end)

  it("sets correct fields for draft items", function()
    local session = {
      drafts = {
        {
          id = "d1",
          file_path = "bar.lua",
          line_start = 3,
          line_end = 7,
          status = "pending",
          author = "ai",
          body = "Suggestion",
          thread_id = 99,
          created_at = "2025-02-01T00:00:00Z",
        },
      },
      threads = {},
    }
    local mock_get_all_threads = function(_)
      return {}
    end

    local items = preview.build_items(session, mock_get_all_threads)
    assert.equal(1, #items)
    local item = items[1]
    assert.equal("draft", item.kind)
    assert.equal("bar.lua", item.file_path)
    assert.equal(3, item.line_start)
    assert.equal(7, item.line_end)
    assert.equal("pending", item.status)
    assert.equal("ai", item.author)
    assert.equal("Suggestion", item.body)
    assert.equal(0, item.reply_count)
    assert.equal(99, item.thread_id)
    assert.equal("d1", item.draft_id)
  end)
end)

-- ============================================================================
-- format_display
-- ============================================================================

describe("format_display", function()
  it("returns a non-empty string for thread items", function()
    local item = {
      kind = "thread",
      file_path = "src/main.lua",
      line_start = 10,
      status = "active",
      author = "reviewer",
      body = "Some comment body text here",
      reply_count = 2,
    }

    local display = preview.format_display(item)
    assert.is_string(display)
    assert.truthy(#display > 0)
    assert.truthy(display:find("src/main.lua"), "Should contain file path")
    assert.truthy(display:find("reviewer"), "Should contain author")
  end)

  it("returns a non-empty string for draft items", function()
    local item = {
      kind = "draft",
      file_path = "src/utils.lua",
      line_start = 5,
      status = "draft",
      author = "user",
      body = "Draft body",
      reply_count = 0,
    }

    local display = preview.format_display(item)
    assert.is_string(display)
    assert.truthy(display:find("src/utils.lua"), "Should contain file path")
  end)

  it("shows range for multi-line comments", function()
    local item = {
      kind = "thread",
      file_path = "a.lua",
      line_start = 10,
      line_end = 20,
      status = "active",
      author = "test",
      body = "multi-line",
      reply_count = 0,
    }

    local display = preview.format_display(item)
    assert.truthy(display:find("10%-20"), "Should show range 10-20")
  end)

  it("shows reply count badge when > 0", function()
    local item = {
      kind = "thread",
      file_path = "a.lua",
      line_start = 1,
      status = "active",
      author = "test",
      body = "test",
      reply_count = 3,
    }

    local display = preview.format_display(item)
    assert.truthy(display:find("%(3%)"), "Should show (3) reply badge")
  end)

  it("truncates long body text", function()
    local long_body = string.rep("x", 100)
    local item = {
      kind = "draft",
      file_path = "a.lua",
      line_start = 1,
      status = "draft",
      author = "user",
      body = long_body,
      reply_count = 0,
    }

    local display = preview.format_display(item)
    -- Body should be truncated to 40 chars
    assert.truthy(#display < #long_body + 50, "Display should be shorter than full body")
  end)
end)
