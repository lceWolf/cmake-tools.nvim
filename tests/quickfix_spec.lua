local quickfix = require("cmake-tools.quickfix")

local opts = {
  show = "only_on_error",
  position = "belowright",
  size = 10,
  encoding = "utf-8",
  auto_close_when_success = false,
}

local function qf_lines()
  return vim.tbl_map(function(item)
    return item.text
  end, vim.fn.getqflist())
end

local function run(cmd, args)
  local result = { outputs = {} }
  quickfix.run(cmd, "", {}, args, vim.uv.cwd(), opts, function(code)
    result.code = code
  end, function(data, err)
    table.insert(result.outputs, data or err)
  end)
  vim.wait(5000, function()
    return result.code ~= nil
  end, 10)
  return result
end

describe("quickfix runner", function()
  after_each(function()
    quickfix.stop(opts)
    vim.fn.setqflist({}, "r")
    vim.cmd("silent! cclose")
  end)

  it("streams stdout and stderr lines into the quickfix list and reports the exit code", function()
    local result = run("sh", { "-c", "echo out; echo err >&2; printf partial; exit 3" })

    assert.equals(3, result.code)
    local lines = qf_lines()
    assert.is_true(vim.tbl_contains(lines, "out"))
    assert.is_true(vim.tbl_contains(lines, "err"))
    assert.is_true(vim.tbl_contains(lines, "partial"))
    assert.equals("Exited with code 3", lines[#lines])
    assert.is_true(vim.tbl_contains(result.outputs, "out"))
  end)

  it("passes env and cwd to the process", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    local code
    quickfix.run(
      "sh",
      "",
      { CMAKE_TOOLS_SPEC = "hello" },
      { "-c", "echo $CMAKE_TOOLS_SPEC; pwd" },
      tmp,
      opts,
      function(c)
        code = c
      end,
      function() end
    )
    vim.wait(5000, function()
      return code ~= nil
    end, 10)

    local lines = qf_lines()
    assert.equals(0, code)
    assert.is_true(vim.tbl_contains(lines, "hello"))
    assert.is_true(vim.tbl_contains(lines, vim.fn.resolve(tmp)) or vim.tbl_contains(lines, tmp))
    vim.fn.delete(tmp, "rf")
  end)

  it("reports an active job until it is stopped", function()
    local code
    quickfix.run("sleep", "", {}, { "10" }, vim.uv.cwd(), opts, function(c)
      code = c
    end, function() end)

    assert.is_true(quickfix.has_active_job(opts))

    quickfix.stop(opts)
    vim.wait(5000, function()
      return code ~= nil
    end, 10)

    assert.is_not.equals(0, code)
    assert.is_false(quickfix.has_active_job(opts))
  end)

  it("finishes when the process exits even if a background child holds the pipes", function()
    local code
    local pidfile = vim.fn.tempname()
    finally(function()
      local pid = tonumber((vim.fn.readfile(pidfile)[1] or ""))
      if pid then
        vim.uv.kill(pid, 9)
      end
      vim.fn.delete(pidfile)
    end)

    local start = vim.uv.hrtime()
    local script = "sleep 3 & echo $! > " .. vim.fn.shellescape(pidfile) .. "; echo started"
    quickfix.run("sh", "", {}, { "-c", script }, vim.uv.cwd(), opts, function(c)
      code = c
    end, function() end)
    vim.wait(1500, function()
      return code ~= nil
    end, 10)

    assert.equals(0, code)
    assert.is_true((vim.uv.hrtime() - start) / 1e6 < 2500)
    assert.is_true(vim.tbl_contains(qf_lines(), "started"))
    assert.is_false(quickfix.has_active_job(opts))
  end)

  it("does not let a stale job write into the quickfix list of a newer run", function()
    local code_a, code_b
    quickfix.run("sleep", "", {}, { "10" }, vim.uv.cwd(), opts, function(c)
      code_a = c
    end, function() end)
    quickfix.stop(opts)
    -- the second run starts before the first job's exit has been processed
    quickfix.run("sleep", "", {}, { "10" }, vim.uv.cwd(), opts, function(c)
      code_b = c
    end, function() end)
    vim.wait(5000, function()
      return code_a ~= nil
    end, 10)
    vim.wait(100)

    assert.is_not_nil(code_a)
    assert.is_nil(code_b)
    for _, line in ipairs(qf_lines()) do
      assert.is_nil(line:find("Exited with code", 1, true))
    end
    assert.is_true(quickfix.has_active_job(opts))

    quickfix.stop(opts)
    vim.wait(5000, function()
      return code_b ~= nil
    end, 10)
    assert.is_not_nil(code_b)
  end)

  it("has an active job until finish has run", function()
    local code
    local active_in_exit
    quickfix.run("sh", "", {}, { "-c", "echo hi" }, vim.uv.cwd(), opts, function(c)
      code = c
      active_in_exit = quickfix.has_active_job(opts)
    end, function() end)
    assert.is_true(quickfix.has_active_job(opts))
    vim.wait(5000, function()
      return code ~= nil
    end, 10)
    assert.is_false(active_in_exit)
    assert.is_false(quickfix.has_active_job(opts))
  end)

  it("reports a missing command asynchronously and opens the quickfix on error", function()
    local code
    quickfix.run("cmake-tools-does-not-exist", "", {}, { "x" }, vim.uv.cwd(), opts, function(c)
      code = c
    end, function() end)
    assert.is_nil(code)
    vim.wait(5000, function()
      return code ~= nil
    end, 10)

    assert.equals(127, code)
    local found = false
    for _, line in ipairs(qf_lines()) do
      if line:find("cmake-tools-does-not-exist", 1, true) then
        found = true
      end
    end
    assert.is_true(found)
    assert.is_true(vim.fn.getqflist({ winid = 0 }).winid ~= 0)
    assert.is_false(quickfix.has_active_job(opts))
  end)

  it("strips CRLF line endings", function()
    local result = run("sh", { "-c", "printf 'a\\r\\nb\\r\\n'" })
    assert.equals(0, result.code)
    assert.same({ "a", "b" }, { result.outputs[1], result.outputs[2] })
    local lines = qf_lines()
    assert.same({ "a", "b", "Exited with code 0" }, lines)
  end)

  it("delivers long output completely and in order", function()
    local result = run("seq", { "1", "5000" })
    assert.equals(0, result.code)
    assert.equals(5000, #result.outputs)
    for i = 1, 5000 do
      assert.equals(tostring(i), result.outputs[i])
    end
    local lines = qf_lines()
    assert.equals(5001, #lines)
    assert.equals("5000", lines[5000])
    assert.equals("Exited with code 0", lines[5001])
  end)
end)
