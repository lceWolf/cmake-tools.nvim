local notifications = { runner = { enabled = true } }

local function new_notification()
  package.loaded["cmake-tools.notification"] = nil
  local notification = require("cmake-tools.notification")
  notification.setup(notifications)
  return notification:new("runner")
end

local function recorder(calls)
  return function(msg, level, opts)
    table.insert(calls, { msg = msg, level = level, id = opts.id, replace = opts.replace })
    return 1
  end
end

local function stub_notify(calls)
  package.loaded.notify = recorder(calls)
end

local function stub_snacks(enabled, calls)
  package.loaded.snacks = {
    config = { notifier = { enabled = enabled } },
    notifier = { notify = recorder(calls) },
  }
end

describe("notification backend", function()
  after_each(function()
    package.loaded.notify = nil
    package.loaded.snacks = nil
    package.loaded["cmake-tools.notification"] = nil
  end)

  it("uses nvim-notify when it is installed", function()
    local notify_calls, snacks_calls = {}, {}
    stub_notify(notify_calls)
    stub_snacks(true, snacks_calls)

    local ntfy = new_notification()
    ntfy:notify("cmake", "info")

    assert.is_true(ntfy.enabled)
    assert.same({ { msg = "cmake", level = "info", replace = nil } }, notify_calls)
    assert.same({}, snacks_calls)
  end)

  it("falls back to the snacks notifier and replaces its notification by id", function()
    local calls = {}
    stub_snacks(true, calls)

    local ntfy = new_notification()
    ntfy:notify("cmake", "info")
    ntfy:notify("[ 50%] Building", "info")

    assert.is_true(ntfy.enabled)
    assert.same({
      { msg = "cmake", level = "info", id = nil, replace = nil },
      { msg = "[ 50%] Building", level = "info", id = 1, replace = 1 },
    }, calls)
  end)

  it("is disabled when the snacks notifier is disabled", function()
    local calls = {}
    stub_snacks(false, calls)

    local ntfy = new_notification()
    ntfy:notify("cmake", "info")

    assert.is_false(ntfy.enabled)
    assert.same({}, calls)
  end)

  it("is disabled without a notification plugin", function()
    local ntfy = new_notification()

    assert.is_false(ntfy.enabled)
  end)
end)
