local ctest = require("cmake-tools.test.ctest")

describe("ctest.list_all_tests", function()
  local orig_system, cmd, result

  before_each(function()
    cmd = nil
    -- fake ctest output with a json test listing
    result = {
      code = 0,
      stdout = vim.json.encode({
        tests = {
          { name = "unit", properties = { { name = "LABELS", value = { "fast", "core" } } } },
          { name = "integration" },
        },
      }),
    }

    orig_system = vim.system
    vim.system = function(c, _, on_exit)
      cmd = c
      on_exit(result)
      return {}
    end
  end)

  after_each(function()
    vim.system = orig_system
  end)

  local function list(build_dir, preset)
    local tests
    ctest.list_all_tests(build_dir, preset, function(res)
      tests = res
    end)
    vim.wait(5000, function()
      return tests ~= nil
    end, 10)
    return tests
  end

  it("parses names and labels", function()
    local tests = list("/some/build", nil)

    assert.same({
      { name = "unit", labels = { "fast", "core" } },
      { name = "integration", labels = {} },
    }, tests)
    assert.same({ "ctest", "--test-dir", "/some/build", "--show-only=json-v1" }, cmd)
  end)

  it("uses the test preset when given", function()
    list("/some/build", "my-preset")
    assert.same({ "ctest", "--preset", "my-preset", "--show-only=json-v1" }, cmd)
  end)

  it("returns no tests when ctest fails", function()
    result = { code = 1, stdout = "", stderr = "boom" }
    assert.same({}, list("/some/build", nil))
  end)

  it("ignores the output of a failed run even if it is valid json", function()
    result.code = 1
    assert.same({}, list("/some/build", nil))
  end)

  it("returns no tests for output that is not json", function()
    result = { code = 0, stdout = "not json" }
    assert.same({}, list("/some/build", nil))
  end)

  it("returns no tests when ctest cannot be started", function()
    vim.system = function()
      error("ENOENT: no such file or directory: ctest")
    end
    assert.same({}, list("/some/build", nil))
    assert.is_nil(ctest.job)
  end)

  it("stops a running listing", function()
    vim.system = function(_, opts, on_exit)
      return orig_system({ "sleep", "10" }, opts, on_exit)
    end
    local tests
    ctest.list_all_tests("/some/build", nil, function(res)
      tests = res
    end)
    assert.is_not_nil(ctest.job)

    ctest.stop()
    vim.wait(5000, function()
      return tests ~= nil
    end, 10)

    assert.same({}, tests)
    assert.is_nil(ctest.job)
  end)

  it("clears ctest.job once the listing finished", function()
    list("/some/build", nil)
    assert.is_nil(ctest.job)
  end)

  it("does not error when stopping with nothing running", function()
    assert.has_no.errors(function()
      ctest.stop()
    end)
  end)

  it("collects label counts", function()
    local labels = ctest.get_all_labels(list("/some/build", nil))
    assert.same({ { label = "core", count = 1 }, { label = "fast", count = 1 } }, labels)
  end)
end)
