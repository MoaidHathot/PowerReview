--- Tests for power-review.session_helpers
--- Pure Lua module — no Neovim runtime needed.
local helpers = require("power-review.session_helpers")

-- ============================================================================
-- Test fixtures
-- ============================================================================

--- Create a minimal session with drafts and threads for testing.
---@return table
local function make_session()
  return {
    id = "test_session",
    pr_id = 42,
    drafts = {
      {
        id = "d1",
        file_path = "src/main.lua",
        line_start = 10,
        body = "Fix this",
        status = "draft",
        author = "user",
        created_at = "2025-01-01T00:00:00Z",
      },
      {
        id = "d2",
        file_path = "src/main.lua",
        line_start = 20,
        body = "AI suggestion",
        status = "pending",
        author = "ai",
        created_at = "2025-01-02T00:00:00Z",
      },
      {
        id = "d3",
        file_path = "src/utils.lua",
        line_start = 5,
        body = "Looks good",
        status = "draft",
        author = "user",
        created_at = "2025-01-03T00:00:00Z",
      },
      {
        id = "d4",
        file_path = "src/main.lua",
        line_start = 30,
        body = "Submitted comment",
        status = "submitted",
        author = "user",
        created_at = "2025-01-04T00:00:00Z",
      },
    },
    threads = {
      {
        id = 101,
        file_path = "src/main.lua",
        line_start = 10,
        status = "active",
        comments = {
          { author = "reviewer1", body = "Please refactor", created_at = "2025-01-01T00:00:00Z" },
        },
      },
      {
        id = 102,
        file_path = "src/utils.lua",
        line_start = 15,
        status = "fixed",
        comments = {
          { author = "reviewer2", body = "Typo here", created_at = "2025-01-02T00:00:00Z" },
          { author = "dev", body = "Fixed", created_at = "2025-01-03T00:00:00Z" },
        },
      },
      {
        id = 103,
        file_path = "src/other.lua",
        line_start = 1,
        status = "active",
        comments = {},
      },
    },
    vote = 10,
  }
end

-- ============================================================================
-- get_drafts_for_file
-- ============================================================================

describe("get_drafts_for_file", function()
  it("returns drafts matching the file path", function()
    local session = make_session()
    local drafts = helpers.get_drafts_for_file(session, "src/main.lua")
    assert.equal(3, #drafts)
  end)

  it("returns empty table when no drafts match", function()
    local session = make_session()
    local drafts = helpers.get_drafts_for_file(session, "nonexistent.lua")
    assert.equal(0, #drafts)
  end)

  it("normalizes backslashes to forward slashes", function()
    local session = make_session()
    local drafts = helpers.get_drafts_for_file(session, "src\\main.lua")
    assert.equal(3, #drafts)
  end)

  it("handles session with no drafts array", function()
    local session = { drafts = nil }
    local drafts = helpers.get_drafts_for_file(session, "foo.lua")
    assert.equal(0, #drafts)
  end)

  it("handles drafts with nil file_path", function()
    local session = {
      drafts = {
        { id = "d1", file_path = nil, body = "test", status = "draft" },
        { id = "d2", file_path = "a.lua", body = "test2", status = "draft" },
      },
    }
    local drafts = helpers.get_drafts_for_file(session, "a.lua")
    assert.equal(1, #drafts)
    assert.equal("d2", drafts[1].id)
  end)
end)

-- ============================================================================
-- get_draft
-- ============================================================================

describe("get_draft", function()
  it("returns the draft with matching ID", function()
    local session = make_session()
    local draft = helpers.get_draft(session, "d2")
    assert.not_nil(draft)
    assert.equal("d2", draft.id)
    assert.equal("AI suggestion", draft.body)
  end)

  it("returns nil for non-existent draft ID", function()
    local session = make_session()
    local draft = helpers.get_draft(session, "nonexistent")
    assert.is_nil(draft)
  end)

  it("handles session with no drafts", function()
    local session = { drafts = nil }
    local draft = helpers.get_draft(session, "d1")
    assert.is_nil(draft)
  end)
end)

-- ============================================================================
-- get_draft_counts
-- ============================================================================

describe("get_draft_counts", function()
  it("counts drafts by status", function()
    local session = make_session()
    local counts = helpers.get_draft_counts(session)
    assert.equal(4, counts.total)
    assert.equal(2, counts.draft)
    assert.equal(1, counts.pending)
    assert.equal(1, counts.submitted)
  end)

  it("returns zero counts for empty drafts", function()
    local session = { drafts = {} }
    local counts = helpers.get_draft_counts(session)
    assert.equal(0, counts.total)
    assert.equal(0, counts.draft)
    assert.equal(0, counts.pending)
    assert.equal(0, counts.submitted)
  end)

  it("handles nil drafts", function()
    local session = { drafts = nil }
    local counts = helpers.get_draft_counts(session)
    assert.equal(0, counts.total)
  end)

  it("ignores unknown statuses gracefully", function()
    local session = {
      drafts = {
        { id = "x", status = "unknown_status" },
        { id = "y", status = "draft" },
      },
    }
    local counts = helpers.get_draft_counts(session)
    assert.equal(2, counts.total)
    assert.equal(1, counts.draft)
    -- "unknown_status" is not a key in counts, so it's not incremented
  end)
end)

-- ============================================================================
-- get_threads_for_file
-- ============================================================================

describe("get_threads_for_file", function()
  it("returns threads matching the file path", function()
    local session = make_session()
    local threads = helpers.get_threads_for_file(session, "src/main.lua")
    assert.equal(1, #threads)
    assert.equal(101, threads[1].id)
  end)

  it("returns empty table when no threads match", function()
    local session = make_session()
    local threads = helpers.get_threads_for_file(session, "nonexistent.lua")
    assert.equal(0, #threads)
  end)

  it("normalizes backslashes", function()
    local session = make_session()
    local threads = helpers.get_threads_for_file(session, "src\\utils.lua")
    assert.equal(1, #threads)
    assert.equal(102, threads[1].id)
  end)

  it("skips threads with nil file_path", function()
    local session = {
      threads = {
        { id = 1, file_path = nil, status = "active" },
        { id = 2, file_path = "a.lua", status = "active" },
      },
    }
    local threads = helpers.get_threads_for_file(session, "a.lua")
    assert.equal(1, #threads)
    assert.equal(2, threads[1].id)
  end)

  it("handles nil threads array", function()
    local session = { threads = nil }
    local threads = helpers.get_threads_for_file(session, "foo.lua")
    assert.equal(0, #threads)
  end)
end)

-- ============================================================================
-- get_vote_choices
-- ============================================================================

describe("get_vote_choices", function()
  it("returns 5 vote choices", function()
    local choices = helpers.get_vote_choices()
    assert.equal(5, #choices)
  end)

  it("each choice has label, value, and key", function()
    local choices = helpers.get_vote_choices()
    for _, c in ipairs(choices) do
      assert.is_string(c.label)
      assert.is_number(c.value)
      assert.is_string(c.key)
    end
  end)

  it("marks current vote when provided", function()
    local choices = helpers.get_vote_choices(10)
    local approved = nil
    for _, c in ipairs(choices) do
      if c.value == 10 then
        approved = c
      end
    end
    assert.not_nil(approved)
    assert.truthy(approved.is_current)
    assert.truthy(approved.label:find("%(current%)"))
  end)

  it("does not mark anything when current_vote does not match", function()
    local choices = helpers.get_vote_choices(99)
    for _, c in ipairs(choices) do
      assert.is_nil(c.is_current)
    end
  end)

  it("does not mark anything when current_vote is nil", function()
    local choices = helpers.get_vote_choices(nil)
    for _, c in ipairs(choices) do
      assert.is_nil(c.is_current)
    end
  end)

  it("includes all standard vote values", function()
    local choices = helpers.get_vote_choices()
    local values = {}
    for _, c in ipairs(choices) do
      values[c.value] = true
    end
    assert.truthy(values[10])
    assert.truthy(values[5])
    assert.truthy(values[0])
    assert.truthy(values[-5])
    assert.truthy(values[-10])
  end)
end)

-- ============================================================================
-- vote_label
-- ============================================================================

describe("vote_label", function()
  it("returns correct label for standard votes", function()
    assert.equal("Approved", helpers.vote_label(10))
    assert.equal("Approved with suggestions", helpers.vote_label(5))
    assert.equal("No vote", helpers.vote_label(0))
    assert.equal("Wait for author", helpers.vote_label(-5))
    assert.equal("Rejected", helpers.vote_label(-10))
  end)

  it("returns Unknown for non-standard vote values", function()
    local label = helpers.vote_label(99)
    assert.truthy(label:find("Unknown"))
    assert.truthy(label:find("99"))
  end)
end)

-- ============================================================================
-- metadata helpers
-- ============================================================================

describe("metadata helpers", function()
  it("uses metadata review progress when available", function()
    local session = {
      metadata = {
        review = {
          reviewed_files = 2,
          changed_since_review = 1,
          unreviewed_files = 3,
          total_files = 6,
        },
      },
      files = { "fallback" },
      reviewed_files = {},
      changed_since_review = {},
    }

    local progress = helpers.get_review_progress(session)

    assert.equal(2, progress.reviewed)
    assert.equal(1, progress.changed)
    assert.equal(3, progress.unreviewed)
    assert.equal(6, progress.total)
  end)

  it("returns metadata table", function()
    local session = { metadata = { files = { total = 4 } } }
    local metadata = helpers.get_metadata(session)
    assert.equal(4, metadata.files.total)
  end)
end)
