--- Tests for power-review.utils.version
--- Pure comparison logic — no Neovim runtime needed for meets_minimum/format.
--- The check() function is tested with a vim.version() mock.

-- ============================================================================
-- meets_minimum (pure, no vim dependency)
-- ============================================================================

-- We can require the module without vim mock because meets_minimum and format
-- don't touch vim.* at module load time. Only check() uses vim.version().
local version = require("power-review.utils.version")

describe("meets_minimum", function()
  local min = { major = 0, minor = 10, patch = 0 }

  -- Exact match
  it("returns true for exact match", function()
    assert.is_true(version.meets_minimum({ major = 0, minor = 10, patch = 0 }, min))
  end)

  -- Higher patch
  it("returns true for higher patch", function()
    assert.is_true(version.meets_minimum({ major = 0, minor = 10, patch = 5 }, min))
  end)

  -- Higher minor
  it("returns true for higher minor", function()
    assert.is_true(version.meets_minimum({ major = 0, minor = 11, patch = 0 }, min))
  end)

  -- Higher major
  it("returns true for higher major", function()
    assert.is_true(version.meets_minimum({ major = 1, minor = 0, patch = 0 }, min))
  end)

  -- Lower patch (same major.minor)
  it("returns false for lower patch", function()
    -- min patch is 0, can't go lower — test with a non-zero minimum
    local min2 = { major = 0, minor = 10, patch = 3 }
    assert.is_false(version.meets_minimum({ major = 0, minor = 10, patch = 2 }, min2))
  end)

  -- Lower minor
  it("returns false for lower minor", function()
    assert.is_false(version.meets_minimum({ major = 0, minor = 9, patch = 5 }, min))
  end)

  -- Lower major
  it("returns false for lower major (hypothetical)", function()
    local min3 = { major = 1, minor = 0, patch = 0 }
    assert.is_false(version.meets_minimum({ major = 0, minor = 99, patch = 99 }, min3))
  end)

  -- Uses M.MIN_VERSION as default when minimum omitted
  it("defaults to M.MIN_VERSION when minimum not specified", function()
    assert.is_true(version.meets_minimum({ major = 0, minor = 10, patch = 0 }))
    assert.is_false(version.meets_minimum({ major = 0, minor = 9, patch = 0 }))
  end)
end)

-- ============================================================================
-- format
-- ============================================================================

describe("format", function()
  it("formats version as major.minor.patch", function()
    assert.equal("0.10.0", version.format({ major = 0, minor = 10, patch = 0 }))
  end)

  it("formats multi-digit versions", function()
    assert.equal("1.23.456", version.format({ major = 1, minor = 23, patch = 456 }))
  end)

  it("formats zero version", function()
    assert.equal("0.0.0", version.format({ major = 0, minor = 0, patch = 0 }))
  end)
end)

-- ============================================================================
-- check (requires vim.version mock)
-- ============================================================================

describe("check", function()
  local original_vim

  before_each(function()
    original_vim = _G.vim
  end)

  after_each(function()
    _G.vim = original_vim
  end)

  it("returns nil when version meets minimum", function()
    _G.vim = {
      version = function()
        return { major = 0, minor = 10, patch = 2 }
      end,
    }
    assert.is_nil(version.check())
  end)

  it("returns nil for exact minimum version", function()
    _G.vim = {
      version = function()
        return { major = 0, minor = 10, patch = 0 }
      end,
    }
    assert.is_nil(version.check())
  end)

  it("returns error message when version is too old", function()
    _G.vim = {
      version = function()
        return { major = 0, minor = 9, patch = 5 }
      end,
    }
    local err = version.check()
    assert.is_string(err)
    assert.truthy(err:find("Requires Neovim >= 0.10.0"))
    assert.truthy(err:find("0.9.5"))
  end)

  it("returns error message for very old version", function()
    _G.vim = {
      version = function()
        return { major = 0, minor = 7, patch = 0 }
      end,
    }
    local err = version.check()
    assert.is_string(err)
    assert.truthy(err:find("0.7.0"))
  end)
end)
