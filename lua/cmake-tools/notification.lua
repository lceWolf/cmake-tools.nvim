local function get_backend()
  local has_notify, notify = pcall(require, "notify")
  if has_notify then
    return notify
  end
  local has_snacks, snacks = pcall(require, "snacks")
  if has_snacks and snacks.config.notifier.enabled then
    return function(msg, level, opts)
      -- snacks only reuses the window of a notification replaced by `id`,
      -- with `replace` alone the old window stays open
      return snacks.notifier.notify(
        msg,
        level,
        vim.tbl_extend("force", opts, { id = opts.replace })
      )
    end
  end
end

local function render(self)
  if self.closed then
    self.opts.replace = nil
  else
    self.opts.replace = self.id
  end

  self.id = self.backend(self.msg, self.level, self.opts)
  self.opts.replace = nil
  self.closed = false
end

local config = {}
local Notification = {}

function Notification.setup(cfg)
  config = cfg
end

function Notification:new(type)
  local instance = setmetatable({}, self)
  self.__index = self

  instance.spinner_idx = 1
  instance.closed = true
  instance.backend = get_backend()
  instance.enabled = instance.backend ~= nil and config[type].enabled

  instance.spinnerTimer = vim.loop.new_timer()

  return instance
end

function Notification:startSpinner()
  if not self.enabled or self.spinnerRunning then
    return
  end
  self.spinnerRunning = true
  self.spinnerTimer:start(
    config.refresh_rate_ms,
    config.refresh_rate_ms,
    vim.schedule_wrap(function()
      self.spinner_idx = (self.spinner_idx + 1) % #config.spinner

      self.opts.replace = self.id
      self.opts.icon = config.spinner[self.spinner_idx]
      render(self)
    end)
  )
end

function Notification:stopSpinner()
  self.spinnerRunning = false
  self.spinnerTimer:stop()
end

function Notification:notify(msg, level, opts)
  if not self.enabled then
    return
  end

  self.msg = msg or ""
  self.level = level
  self.opts = opts or {}

  local on_close = self.opts.on_close
  local on_open = self.opts.on_open

  self.opts.hide_from_history = true
  self.opts.history = false
  self.opts.title = "CMakeTools"
  self.opts.on_close = function(win)
    self.closed = true
    self.spinner_idx = 1
    if on_close then
      on_close(win)
    end
  end
  self.opts.on_open = function(win)
    self.win = win
    self.width = vim.api.nvim_win_get_width(win)
    if on_open then
      on_open(win)
    end
  end

  render(self)

  -- We have to check for a valid window here as it seems notify invokes the on_close callback async.
  -- Hence checking for self.closed would not work as it gets set too late
  if self.win and vim.api.nvim_win_is_valid(self.win) and self.width then
    -- update the notification width when the message was updated
    local timeDigits = 8
    local headlineLength = (self.opts.icon and (#self.opts.icon + 1) or 0)
      + #self.opts.title
      + 3 -- padding between title and time
      + timeDigits
    vim.api.nvim_win_set_width(self.win, math.max(#self.msg + 1, headlineLength))
  end
end

return Notification
