--- Tests for power-review.cli adapter functions
--- Tests adapt_session(), _adapt_session_summaries(), and _vote_string_to_number().
--- These are pure data transformers (no I/O, no CLI spawning).
local vim_mock = require("helpers.vim_mock")

-- Install vim mock BEFORE requiring modules that use vim.*
vim_mock.install()

local cli = require("power-review.cli")

-- ============================================================================
-- Test fixtures
-- ============================================================================

--- Build a minimal CLI v3/v4 nested session (the shape the CLI outputs).
---@return table
local function make_cli_session()
  return {
    version = 4,
    id = "sess-001",
    pull_request = {
      id = 42,
      url = "https://dev.azure.com/org/project/_git/repo/pullrequest/42",
      title = "Add feature X",
      description = "Implements feature X",
      author = { display_name = "Alice" },
      status = "active",
      is_draft = false,
      closed_at = nil,
      source_branch = "refs/heads/feature-x",
      target_branch = "refs/heads/main",
      merge_status = "succeeded",
      reviewers = {
        { display_name = "Bob", vote = 10 },
      },
      labels = { "enhancement" },
      work_items = { { id = 100, title = "Feature X" } },
    },
    provider = {
      type = "azdo",
      organization = "contoso",
      project = "myproject",
      repository = "myrepo",
    },
    git = {
      worktree_path = "/tmp/worktree",
      strategy = "worktree",
    },
    threads = {
      items = {
        { id = "t1", status = "active", comments = {} },
      },
    },
    iteration = {
      iteration_id = 3,
      source_commit = "abc123",
      target_commit = "def456",
    },
    review = {
      reviewed_iteration_id = 2,
      reviewed_source_commit = "aaa111",
      reviewed_files = { "src/foo.lua" },
      changed_since_review = { "src/bar.lua" },
    },
    vote = "Approve",
    metadata = {
      files = { total = 2, added = 1, edited = 1, deleted = 0, renamed = 0 },
      reviewers = { total = 1, required = 1, required_pending = 0 },
    },
    drafts = {
      ["d-1"] = {
        body = "Looks good",
        file_path = "src/foo.lua",
        line_start = 10,
        status = "draft",
        author = "user",
        created_at = "2025-06-01T00:00:00Z",
      },
      ["d-2"] = {
        body = "Needs work",
        file_path = "src/bar.lua",
        line_start = 5,
        status = "pending",
        author = "ai",
        created_at = "2025-06-01T01:00:00Z",
      },
    },
    draft_actions = {
      ["a-1"] = {
        action_type = "thread_status_change",
        status = "draft",
        thread_id = 10,
        from_thread_status = "active",
        to_thread_status = "wontfix",
        created_at = "2025-06-01T02:00:00Z",
      },
    },
    files = { "src/foo.lua", "src/bar.lua" },
    created_at = "2025-06-01T00:00:00Z",
    updated_at = "2025-06-02T00:00:00Z",
  }
end

--- Build a minimal flat (already adapted) session.
---@return table
local function make_flat_session()
  return {
    pr_id = 42,
    pr_title = "Already flat",
    drafts = {},
    threads = {},
    files = {},
  }
end

--- Build raw CLI session summaries (as the CLI returns them).
---@return table[]
local function make_cli_summaries()
  return {
    {
      id = "s-1",
      pull_request = {
        id = 10,
        title = "PR One",
        url = "https://example.com/pr/10",
        status = "active",
      },
      provider = {
        type = "github",
        organization = "org1",
        project = "proj1",
        repository = "repo1",
      },
      draft_count = 3,
      created_at = "2025-01-01T00:00:00Z",
      updated_at = "2025-01-02T00:00:00Z",
    },
    {
      id = "s-2",
      -- Already flat shape (no nested pull_request)
      pr_id = 20,
      pr_title = "PR Two",
      pr_url = "https://example.com/pr/20",
      pr_status = "completed",
      provider_type = "azdo",
      org = "org2",
      project = "proj2",
      repo = "repo2",
      draft_count = 0,
      created_at = "2025-02-01T00:00:00Z",
      updated_at = "2025-02-02T00:00:00Z",
    },
  }
end

-- ============================================================================
-- adapt_session
-- ============================================================================

describe("adapt_session", function()
  it("converts nested CLI v4 session to flat Lua shape", function()
    local input = make_cli_session()
    local s = cli.adapt_session(input)

    -- Top-level fields
    assert.equal(4, s.version)
    assert.equal("sess-001", s.id)

    -- PR fields (flattened from pull_request)
    assert.equal(42, s.pr_id)
    assert.equal("Add feature X", s.pr_title)
    assert.equal("Implements feature X", s.pr_description)
    assert.equal("Alice", s.pr_author)
    assert.equal("active", s.pr_status)
    assert.is_false(s.pr_is_draft)
    assert.is_nil(s.pr_closed_at)
    assert.equal("refs/heads/feature-x", s.source_branch)
    assert.equal("refs/heads/main", s.target_branch)
    assert.equal("succeeded", s.merge_status)
    assert.equal("https://dev.azure.com/org/project/_git/repo/pullrequest/42", s.pr_url)

    -- Provider fields
    assert.equal("azdo", s.provider_type)
    assert.equal("contoso", s.org)
    assert.equal("myproject", s.project)
    assert.equal("myrepo", s.repo)

    -- Git fields
    assert.equal("/tmp/worktree", s.worktree_path)
    assert.equal("worktree", s.git_strategy)

    -- Iteration fields
    assert.equal(3, s.iteration_id)
    assert.equal("abc123", s.source_commit)
    assert.equal("def456", s.target_commit)

    -- Review fields
    assert.equal(2, s.reviewed_iteration_id)
    assert.equal("aaa111", s.reviewed_source_commit)
    assert.same({ "src/foo.lua" }, s.reviewed_files)
    assert.same({ "src/bar.lua" }, s.changed_since_review)

    -- Vote (string -> number)
    assert.equal(10, s.vote)

    -- Metadata
    assert.equal(2, s.metadata.files.total)
    assert.equal(1, s.metadata.reviewers.required)

    -- Files
    assert.same({ "src/foo.lua", "src/bar.lua" }, s.files)

    -- Timestamps
    assert.equal("2025-06-01T00:00:00Z", s.created_at)
    assert.equal("2025-06-02T00:00:00Z", s.updated_at)
  end)

  it("converts drafts from map to sorted array with id field", function()
    local input = make_cli_session()
    local s = cli.adapt_session(input)

    assert.is_table(s.drafts)
    assert.equal(2, #s.drafts)

    -- Sorted by created_at: d-1 (00:00) comes before d-2 (01:00)
    assert.equal("d-1", s.drafts[1].id)
    assert.equal("Looks good", s.drafts[1].body)
    assert.equal("src/foo.lua", s.drafts[1].file_path)

    assert.equal("d-2", s.drafts[2].id)
    assert.equal("Needs work", s.drafts[2].body)
    assert.equal("src/bar.lua", s.drafts[2].file_path)
  end)

  it("extracts threads from threads.items", function()
    local input = make_cli_session()
    local s = cli.adapt_session(input)

    assert.is_table(s.threads)
    assert.equal(1, #s.threads)
    assert.equal("t1", s.threads[1].id)
  end)

  it("converts draft_actions from map to sorted array with id field", function()
    local input = make_cli_session()
    local s = cli.adapt_session(input)

    assert.is_table(s.draft_actions)
    assert.equal(1, #s.draft_actions)
    assert.equal("a-1", s.draft_actions[1].id)
    assert.equal("thread_status_change", s.draft_actions[1].action_type)
  end)

  it("converts draft_operations from map and derives legacy UI views", function()
    local input = make_cli_session()
    input.drafts = nil
    input.draft_actions = nil
    input.draft_operations = {
      ["op-reply"] = {
        operation_type = "Reply",
        body = "reply body",
        thread_id = 100,
        status = "pending",
        created_at = "2025-06-01T01:00:00Z",
      },
      ["op-status"] = {
        operation_type = "ThreadStatusChange",
        thread_id = 100,
        to_thread_status = "Fixed",
        status = "draft",
        created_at = "2025-06-01T02:00:00Z",
      },
      ["op-comment"] = {
        operation_type = "Comment",
        body = "comment body",
        file_path = "src/foo.lua",
        status = "draft",
        created_at = "2025-06-01T00:00:00Z",
      },
    }

    local s = cli.adapt_session(input)

    assert.is_table(s.draft_operations)
    assert.equal(3, #s.draft_operations)
    assert.equal("op-comment", s.draft_operations[1].id)
    assert.equal("op-reply", s.draft_operations[2].id)
    assert.equal("op-status", s.draft_operations[3].id)

    assert.equal(2, #s.drafts)
    assert.equal("op-comment", s.drafts[1].id)
    assert.equal("op-reply", s.drafts[2].id)

    assert.equal(1, #s.draft_actions)
    assert.equal("op-status", s.draft_actions[1].id)
  end)

  it("returns already-flat sessions unchanged", function()
    local flat = make_flat_session()
    local s = cli.adapt_session(flat)

    -- Should be the same table (early return path)
    assert.equal(flat, s)
    assert.equal(42, s.pr_id)
    assert.equal("Already flat", s.pr_title)
  end)

  it("handles missing nested fields gracefully", function()
    -- Minimal input: no pull_request, no provider, no git, etc.
    local input = { id = "bare" }
    local s = cli.adapt_session(input)

    assert.equal("bare", s.id)
    assert.equal(0, s.pr_id)
    assert.equal("", s.pr_title)
    assert.equal("", s.pr_description)
    assert.equal("", s.pr_author)
    assert.equal("active", s.pr_status)
    assert.is_false(s.pr_is_draft)
    assert.equal("", s.source_branch)
    assert.equal("", s.target_branch)
    assert.equal("azdo", s.provider_type)
    assert.equal("", s.org)
    assert.equal("", s.project)
    assert.equal("", s.repo)
    assert.equal("worktree", s.git_strategy)
    assert.is_nil(s.worktree_path)
    assert.is_nil(s.vote)
    assert.same({}, s.drafts)
    assert.same({}, s.draft_actions)
    assert.same({}, s.threads)
    assert.same({}, s.files)
  end)

  it("handles empty drafts map", function()
    local input = make_cli_session()
    input.drafts = {}
    local s = cli.adapt_session(input)

    assert.same({}, s.drafts)
  end)

  it("handles pull_request.author without display_name", function()
    local input = make_cli_session()
    input.pull_request.author = {} -- no display_name field
    local s = cli.adapt_session(input)

    assert.equal("", s.pr_author)
  end)

  it("handles nil pull_request.author", function()
    local input = make_cli_session()
    input.pull_request.author = nil
    local s = cli.adapt_session(input)

    assert.equal("", s.pr_author)
  end)

  it("handles threads without items field", function()
    local input = make_cli_session()
    input.threads = {} -- no .items
    local s = cli.adapt_session(input)

    assert.same({}, s.threads)
  end)
end)

-- ============================================================================
-- _adapt_session_result
-- ============================================================================

describe("_adapt_session_result", function()
  it("attaches open action and session file path", function()
    local result = {
      action = "refreshed",
      session_file_path = "/tmp/powerreview/session.json",
      session = make_cli_session(),
    }

    local s = cli._adapt_session_result(result)

    assert.equal("refreshed", s._open_action)
    assert.equal("/tmp/powerreview/session.json", s._session_file_path)
    assert.equal(42, s.pr_id)
  end)
end)

-- ============================================================================
-- _adapt_session_summaries
-- ============================================================================

describe("_adapt_session_summaries", function()
  it("converts nested CLI summaries to flat shape", function()
    local input = make_cli_summaries()
    local summaries = cli._adapt_session_summaries(input)

    assert.equal(2, #summaries)

    -- First: nested pull_request + provider
    local s1 = summaries[1]
    assert.equal("s-1", s1.id)
    assert.equal(10, s1.pr_id)
    assert.equal("PR One", s1.pr_title)
    assert.equal("https://example.com/pr/10", s1.pr_url)
    assert.equal("active", s1.pr_status)
    assert.equal("github", s1.provider_type)
    assert.equal("org1", s1.org)
    assert.equal("proj1", s1.project)
    assert.equal("repo1", s1.repo)
    assert.equal(3, s1.draft_count)
    assert.equal("2025-01-01T00:00:00Z", s1.created_at)
    assert.equal("2025-01-02T00:00:00Z", s1.updated_at)
  end)

  it("handles already-flat summaries via fallback", function()
    local input = make_cli_summaries()
    local summaries = cli._adapt_session_summaries(input)

    -- Second entry uses flat fields
    local s2 = summaries[2]
    assert.equal("s-2", s2.id)
    assert.equal(20, s2.pr_id)
    assert.equal("PR Two", s2.pr_title)
    assert.equal("https://example.com/pr/20", s2.pr_url)
    assert.equal("completed", s2.pr_status)
    assert.equal("azdo", s2.provider_type)
    assert.equal("org2", s2.org)
    assert.equal("proj2", s2.project)
    assert.equal("repo2", s2.repo)
    assert.equal(0, s2.draft_count)
  end)

  it("handles empty input", function()
    local summaries = cli._adapt_session_summaries({})
    assert.same({}, summaries)
  end)

  it("defaults missing fields", function()
    local summaries = cli._adapt_session_summaries({ { id = "bare" } })

    assert.equal(1, #summaries)
    local s = summaries[1]
    assert.equal("bare", s.id)
    assert.equal(0, s.pr_id)
    assert.equal("", s.pr_title)
    assert.equal("", s.pr_url)
    assert.equal("azdo", s.provider_type)
    assert.equal("", s.org)
    assert.equal("", s.project)
    assert.equal("", s.repo)
    assert.equal(0, s.draft_count)
    assert.equal("", s.created_at)
    assert.equal("", s.updated_at)
  end)
end)

-- ============================================================================
-- _vote_string_to_number
-- ============================================================================

describe("_vote_string_to_number", function()
  -- Standard vote strings (PascalCase as CLI outputs)
  it("maps 'Approve' to 10", function()
    assert.equal(10, cli._vote_string_to_number("Approve"))
  end)

  it("maps 'Approved' to 10", function()
    assert.equal(10, cli._vote_string_to_number("Approved"))
  end)

  it("maps 'ApproveWithSuggestions' to 5", function()
    assert.equal(5, cli._vote_string_to_number("ApproveWithSuggestions"))
  end)

  it("maps 'ApprovedWithSuggestions' to 5", function()
    assert.equal(5, cli._vote_string_to_number("ApprovedWithSuggestions"))
  end)

  it("maps 'NoVote' to 0", function()
    assert.equal(0, cli._vote_string_to_number("NoVote"))
  end)

  it("maps 'None' to 0", function()
    assert.equal(0, cli._vote_string_to_number("None"))
  end)

  it("maps 'WaitForAuthor' to -5", function()
    assert.equal(-5, cli._vote_string_to_number("WaitForAuthor"))
  end)

  it("maps 'Reject' to -10", function()
    assert.equal(-10, cli._vote_string_to_number("Reject"))
  end)

  it("maps 'Rejected' to -10", function()
    assert.equal(-10, cli._vote_string_to_number("Rejected"))
  end)

  -- Case-insensitivity
  it("is case-insensitive", function()
    assert.equal(10, cli._vote_string_to_number("approve"))
    assert.equal(10, cli._vote_string_to_number("APPROVE"))
    assert.equal(5, cli._vote_string_to_number("approvewithsuggestions"))
    assert.equal(-5, cli._vote_string_to_number("waitforauthor"))
    assert.equal(-10, cli._vote_string_to_number("REJECT"))
  end)

  -- Separator handling (hyphens and underscores stripped)
  it("handles hyphens in vote strings", function()
    assert.equal(5, cli._vote_string_to_number("Approve-With-Suggestions"))
    assert.equal(-5, cli._vote_string_to_number("Wait-For-Author"))
    assert.equal(0, cli._vote_string_to_number("No-Vote"))
  end)

  it("handles underscores in vote strings", function()
    assert.equal(5, cli._vote_string_to_number("Approve_With_Suggestions"))
    assert.equal(-5, cli._vote_string_to_number("Wait_For_Author"))
    assert.equal(0, cli._vote_string_to_number("No_Vote"))
  end)

  -- Numeric passthrough
  it("passes through numeric strings", function()
    assert.equal(10, cli._vote_string_to_number("10"))
    assert.equal(5, cli._vote_string_to_number("5"))
    assert.equal(0, cli._vote_string_to_number("0"))
    assert.equal(-5, cli._vote_string_to_number("-5"))
    assert.equal(-10, cli._vote_string_to_number("-10"))
  end)

  -- Nil / empty handling
  it("returns nil for nil input", function()
    assert.is_nil(cli._vote_string_to_number(nil))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(cli._vote_string_to_number(""))
  end)

  it("returns nil for unrecognized vote string", function()
    assert.is_nil(cli._vote_string_to_number("garbage"))
    assert.is_nil(cli._vote_string_to_number("maybe"))
  end)
end)

-- ============================================================================
-- Executable normalization
-- ============================================================================

describe("CLI executable normalization", function()
  local original_system = vim.system
  local original_fn = vim.fn
  local original_executable = cli._executable

  after_each(function()
    vim.system = original_system
    vim.fn = original_fn
    cli._executable = original_executable
  end)

  it("routes bare PowerReview through dnx on Windows", function()
    local captured_cmd

    vim.fn = {
      has = function(feature)
        if feature == "win32" then
          return 1
        end
        return 0
      end,
    }

    vim.system = function(cmd, _opts)
      captured_cmd = cmd
      return {
        wait = function()
          return { code = 0, stdout = "[]", stderr = "" }
        end,
      }
    end

    cli.configure({ executable = "PowerReview" })

    local result, err = cli.list_sessions()

    assert.is_nil(err)
    assert.same({}, result)
    assert.same(
      { "dnx", "--yes", "--add-source", "https://api.nuget.org/v3/index.json", "PowerReview", "--", "sessions", "list" },
      captured_cmd
    )
  end)
end)

-- ============================================================================
-- Diff command wrappers
-- ============================================================================

describe("diff command wrappers", function()
  local original_system = vim.system
  local original_fn = vim.fn
  local original_executable = cli._executable

  before_each(function()
    vim.fn = {
      has = function()
        return 0
      end,
    }
    cli.configure({ executable = "powerreview" })
  end)

  after_each(function()
    vim.system = original_system
    vim.fn = original_fn
    cli._executable = original_executable
  end)

  it("requests patch diff by default", function()
    local captured_cmd
    vim.system = function(cmd, _opts)
      captured_cmd = cmd
      return {
        wait = function()
          return { code = 0, stdout = [[{"file":{"path":"src/main.cs"},"diff":"diff --git"}]], stderr = "" }
        end,
      }
    end

    local result, err = cli.get_file_diff("https://example/pr/1", "src/main.cs")

    assert.is_nil(err)
    assert.equal("diff --git", result.diff)
    assert.same({ "powerreview", "diff", "--pr-url", "https://example/pr/1", "--file", "src/main.cs" }, captured_cmd)
  end)

  it("can request metadata format explicitly", function()
    local captured_cmd
    vim.system = function(cmd, _opts)
      captured_cmd = cmd
      return {
        wait = function()
          return { code = 0, stdout = [[{"path":"src/main.cs","change_type":"Edit"}]], stderr = "" }
        end,
      }
    end

    local result, err = cli.get_file_diff_metadata("https://example/pr/1", "src/main.cs")

    assert.is_nil(err)
    assert.equal("src/main.cs", result.path)
    assert.same(
      { "powerreview", "diff", "--pr-url", "https://example/pr/1", "--file", "src/main.cs", "--format", "metadata" },
      captured_cmd
    )
  end)
end)
