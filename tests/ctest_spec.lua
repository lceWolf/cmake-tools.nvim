local ctest = require("cmake-tools.test.ctest")

local join = vim.fs.joinpath

describe("ctest.list_all_tests", function()
  local tmp, old_path

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    old_path = vim.env.PATH
    vim.env.PATH = tmp .. ":" .. old_path

    -- fake ctest which echoes its arguments and a json test listing
    local json = vim.json.encode({
      tests = {
        { name = "unit", properties = { { name = "LABELS", value = { "fast", "core" } } } },
        { name = "integration" },
      },
    })
    local script = join(tmp, "ctest")
    vim.fn.writefile({
      "#!/bin/sh",
      'echo "$@" > "' .. join(tmp, "args") .. '"',
      "cat <<'JSON'",
      json,
      "JSON",
    }, script)
    vim.fn.setfperm(script, "rwxr-xr-x")
  end)

  after_each(function()
    vim.env.PATH = old_path
    vim.fn.delete(tmp, "rf")
  end)

  local function list(build_dir, preset)
    local tests
    ctest.list_all_tests(build_dir, preset, function(result)
      tests = result
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
    assert.same(
      { "--test-dir /some/build --show-only=json-v1" },
      vim.fn.readfile(join(tmp, "args"))
    )
  end)

  it("uses the test preset when given", function()
    list("/some/build", "my-preset")
    assert.same({ "--preset my-preset --show-only=json-v1" }, vim.fn.readfile(join(tmp, "args")))
  end)

  it("clears ctest.job once the listing finished", function()
    list("/some/build", nil)
    vim.wait(1000, function()
      return ctest.job == nil
    end, 10)
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
