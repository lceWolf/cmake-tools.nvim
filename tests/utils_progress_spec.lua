local stub_notification
-- the { stdout, stderr } pairs the fake runner passes to on_output
local outputs

local function stdout(lines)
  return vim.tbl_map(function(line)
    return { line, nil }
  end, lines)
end

local function clear_modules()
  package.loaded["cmake-tools.utils"] = nil
  package.loaded["cmake-tools.notification"] = nil
  package.loaded["cmake-tools.runners"] = nil
  package.loaded["cmake-tools.executors"] = nil
end

describe("utils.run progress notifications", function()
  before_each(function()
    clear_modules()

    stub_notification = {
      enabled = true,
      notify_calls = {},
      notify = function(self, msg, level)
        table.insert(self.notify_calls, { msg = msg, level = level })
      end,
      startSpinner = function() end,
      stopSpinner = function() end,
    }

    package.loaded["cmake-tools.notification"] = {
      new = function(_)
        return stub_notification
      end,
    }

    package.loaded["cmake-tools.runners"] = {
      fake = {
        run = function(_, _, _, _, _, _, on_exit, on_output)
          for _, output in ipairs(outputs) do
            on_output(output[1], output[2])
          end
          on_exit(0)
        end,
      },
    }

    package.loaded["cmake-tools.executors"] = { fake = {} }
  end)

  after_each(function()
    clear_modules()
  end)

  local function progress_calls()
    local calls = {}
    for _, call in ipairs(stub_notification.notify_calls) do
      if call.msg ~= "cmake" and not call.msg:match("^Exited with code") then
        table.insert(calls, call)
      end
    end
    return calls
  end

  local function progress_messages()
    return vim.tbl_map(function(call)
      return call.msg
    end, progress_calls())
  end

  local function run()
    local utils = require("cmake-tools.utils")
    utils.run("cmake", "", {}, {}, vim.uv.cwd(), { name = "fake", opts = {} }, nil)
  end

  it("ignores stdout lines without build progress or diagnostics", function()
    outputs = stdout({
      "[  5%] Building CXX object a.o",
      "Scanning dependencies of target app",
      "make[2]: Entering directory '/build'",
      "[100%] Built target app",
      "[ 12%] Linking",
      "-- Configuring done",
    })

    run()

    assert.same({
      "[  5%] Building CXX object a.o",
      "[100%] Built target app",
      "[ 12%] Linking",
    }, progress_messages())
  end)

  it("does not notify when no line has build progress", function()
    outputs = stdout({ "-- Configuring done", "-- Generating done" })

    run()

    assert.same({}, progress_messages())
  end)

  it("notifies for ninja progress lines", function()
    outputs = stdout({ "[1/3] Building CXX object a.o", "ninja: no work to do.", "[3/3] Linking" })

    run()

    assert.same({ "[1/3] Building CXX object a.o", "[3/3] Linking" }, progress_messages())
  end)

  it("notifies only the headline of a compiler diagnostic on stderr as warning", function()
    outputs = {
      { nil, "a.cpp: In function 'int f()':" },
      { nil, "a.cpp:1:17: error: expected ';' before '}' token" },
      { nil, "    1 | int f(){return 1}" },
      { nil, "      |                 ^" },
      { nil, "" },
      { "[ 50%] Building", nil },
    }

    run()

    assert.same({
      { msg = "a.cpp:1:17: error: expected ';' before '}' token", level = "warn" },
      { msg = "[ 50%] Building", level = "info" },
    }, progress_calls())
  end)

  it("notifies diagnostics on stdout, as ninja forwards them there", function()
    outputs = stdout({
      "[1/2] Building CXX object a.o",
      "FAILED: a.o",
      "a.cpp:3:5: warning: unused variable 'x' [-Wunused-variable]",
      "    3 |   int x;",
      "      |     ^",
    })

    run()

    assert.same({
      { msg = "[1/2] Building CXX object a.o", level = "info" },
      { msg = "a.cpp:3:5: warning: unused variable 'x' [-Wunused-variable]", level = "warn" },
    }, progress_calls())
  end)

  it("notifies cmake and msvc diagnostics", function()
    outputs = {
      { nil, "CMake Error at CMakeLists.txt:3 (add_executable):" },
      { nil, "  Cannot find source file:" },
      { "a.cpp(3): error C2143: syntax error: missing ';' before '}'", nil },
      { "a.cpp(4): warning C4101: 'x': unreferenced local variable", nil },
    }

    run()

    assert.same({
      "CMake Error at CMakeLists.txt:3 (add_executable):",
      "a.cpp(3): error C2143: syntax error: missing ';' before '}'",
      "a.cpp(4): warning C4101: 'x': unreferenced local variable",
    }, progress_messages())
  end)

  it("accepts a list of lines, as toggleterm passes them", function()
    outputs = {
      { { "[ 10%] Building a.o", "noise", "[ 20%] Building b.o", "" }, nil },
      { nil, { "a.cpp:1:1: warning: x", "  ^", "" } },
    }

    run()

    assert.same(
      { "[ 10%] Building a.o", "[ 20%] Building b.o", "a.cpp:1:1: warning: x" },
      progress_messages()
    )
  end)

  it("does not notify when notifications are disabled", function()
    outputs = stdout({ "[ 10%] Building a.o" })
    stub_notification.enabled = false

    run()

    assert.same({}, progress_messages())
  end)
end)
