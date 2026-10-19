local log = require("cmake-tools.log")

---@alias quickfix_show '"always"'|'"only_on_error"'
---@alias quickfix_position '"belowright"'|'"bottom"'|'"top"'
---@alias quickfix_opts_type {show:quickfix_show, position:quickfix_position, size:number}
--
---@class quickfix : executor, runner
local _quickfix = {
  job = nil,
}

function _quickfix.scroll_to_bottom()
  vim.api.nvim_command("cbottom")
end

local function append_to_quickfix(encoding, error, data)
  local line = error and error or data
  if encoding ~= "utf-8" then
    line = vim.fn.iconv(line, encoding, "utf-8")
  end

  vim.fn.setqflist({}, "a", { lines = { line } })
  -- scroll the quickfix buffer to bottom
  if _quickfix.check_scroll() then
    _quickfix.scroll_to_bottom()
  end
end

function _quickfix.show(opts)
  vim.api.nvim_command(opts.position .. " copen " .. opts.size)
  vim.api.nvim_command("wincmd p")
end

function _quickfix.close(opts)
  vim.api.nvim_command("cclose")
end

local function line_reader(emit)
  local pending = ""
  local function emit_line(line)
    emit((line:gsub("\r$", "")))
  end
  local function flush()
    if pending ~= "" then
      local line = pending
      pending = ""
      emit_line(line)
    end
  end
  local function handler(data)
    if data == nil then
      flush()
      return
    end
    pending = pending .. data
    while true do
      local idx = pending:find("\n", 1, true)
      if not idx then
        break
      end
      local line = pending:sub(1, idx - 1)
      pending = pending:sub(idx + 1)
      emit_line(line)
    end
  end
  return handler, flush
end

-- how long the pipes may stay silent after the process exited before they are closed
local DRAIN_TIMEOUT_MS = 100

function _quickfix.run(cmd, env_script, env, args, cwd, opts, on_exit, on_output)
  vim.fn.setqflist({}, " ", { title = cmd .. " " .. table.concat(args, " ") })
  if opts.show == "always" then
    _quickfix.show(opts)
  end

  -- NOTE: env_script is not used by quickfix.run()

  -- uv.spawn replaces the environment, so merge `env` on top of the parent one
  local job_env = vim.fn.environ()
  for k, v in pairs(env or {}) do
    job_env[k] = tostring(v)
  end
  local env_list = {}
  for k, v in pairs(job_env) do
    table.insert(env_list, k .. "=" .. v)
  end

  local job = { command = cmd, done = false }

  -- a newer run owns the quickfix list once this job is no longer the current one
  local function owns_quickfix()
    return _quickfix.job == job
  end

  local function make_reader(is_err)
    return line_reader(function(line)
      if owns_quickfix() then
        if is_err then
          append_to_quickfix(opts.encoding, line, nil)
        else
          append_to_quickfix(opts.encoding, nil, line)
        end
      end
      if is_err then
        on_output(nil, line)
      else
        on_output(line, nil)
      end
    end)
  end

  local stdout_reader, stdout_flush = make_reader(false)
  local stderr_reader, stderr_flush = make_reader(true)

  local function finish(code)
    stdout_flush()
    stderr_flush()
    local current = owns_quickfix()
    if current then
      append_to_quickfix(opts.encoding, "Exited with code " .. code)
      if code ~= 0 and opts.show == "only_on_error" then
        _quickfix.show(opts)
        _quickfix.scroll_to_bottom()
      end
      if code == 0 and opts.auto_close_when_success then
        _quickfix.close(opts)
      end
      _quickfix.job = nil
    end
    job.done = true
    if on_exit ~= nil then
      on_exit(code)
    end
  end

  local stdout = vim.uv.new_pipe(false)
  local stderr = vim.uv.new_pipe(false)

  local function close_handle(handle)
    if handle and not handle:is_closing() then
      handle:close()
    end
  end

  local handle, pid_or_err = vim.uv.spawn(cmd, {
    args = args,
    cwd = cwd,
    env = env_list,
    stdio = { nil, stdout, stderr },
  }, function(code, signal)
    job.exited = true
    code = signal == 0 and code or 128 + signal
    close_handle(job.handle)

    -- Deliver what is still in the pipes, but do not wait for background
    -- children that inherited them and keep them open: stop reading once
    -- the pipes stayed silent for DRAIN_TIMEOUT_MS.
    local open_pipes = 0
    local finished = false
    local timer = vim.uv.new_timer()
    job.drain_timer = timer
    local function complete()
      if finished then
        return
      end
      finished = true
      job.drain_timer = nil
      timer:stop()
      close_handle(timer)
      for _, pipe in ipairs({ stdout, stderr }) do
        if not pipe:is_closing() then
          pipe:read_stop()
          pipe:close()
        end
      end

      -- scheduled after the pending chunks, so all output comes first
      vim.schedule(function()
        finish(code)
      end)
    end
    for _, pipe in ipairs({ stdout, stderr }) do
      if not pipe:is_closing() then
        open_pipes = open_pipes + 1
      end
    end
    job.on_pipe_closed = function()
      open_pipes = open_pipes - 1
      if open_pipes <= 0 then
        complete()
      end
    end
    if open_pipes == 0 then
      complete()
    else
      job.drain_timer_cb = complete
      timer:start(DRAIN_TIMEOUT_MS, 0, complete)
    end
  end)

  if not handle then
    close_handle(stdout)
    close_handle(stderr)
    local msg = string.format('Failed to run "%s": %s', cmd, tostring(pid_or_err))
    vim.schedule(function()
      log.error(msg)
      append_to_quickfix(opts.encoding, msg)
      if opts.show == "only_on_error" then
        _quickfix.show(opts)
        _quickfix.scroll_to_bottom()
      end
      if on_exit ~= nil then
        on_exit(127)
      end
    end)
    return
  end

  job.handle = handle
  job.pid = pid_or_err
  _quickfix.job = job

  local function start_reading(pipe, reader)
    pipe:read_start(function(err, data)
      if err then
        data = nil
      end
      if data ~= nil and job.drain_timer then
        job.drain_timer:start(DRAIN_TIMEOUT_MS, 0, job.drain_timer_cb)
      end
      vim.schedule(function()
        reader(data)
      end)
      if data == nil then
        close_handle(pipe)
        if job.on_pipe_closed then
          job.on_pipe_closed()
        end
      end
    end)
  end
  start_reading(stdout, stdout_reader)
  start_reading(stderr, stderr_reader)
end

---Checks if there is an active job
---@param opts quickfix_opts_type options for this adapter
---@return boolean
function _quickfix.has_active_job(opts)
  if not _quickfix.job or _quickfix.job.done then
    return false
  end
  log.error(
    "A CMake task is already running: "
      .. _quickfix.job.command
      .. " Stop it before trying to run a new CMake task."
  )
  return true
end

---Stop the active job
---@param opts quickfix_opts_type options for this adapter
---@return nil
function _quickfix.stop(opts)
  local job = _quickfix.job
  if not job or job.done or job.exited then
    return
  end

  for _, pid in ipairs(vim.api.nvim_get_proc_children(job.pid)) do
    vim.uv.kill(pid, 9)
  end
  job.handle:kill(9)
end

function _quickfix.check_scroll()
  local function is_cursor_at_last_line()
    local current_buf = vim.api.nvim_win_get_buf(0)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local line_count = vim.api.nvim_buf_line_count(current_buf)

    return cursor_pos[1] == line_count - 1
  end

  local buffer_type = vim.bo.buftype

  if buffer_type == "quickfix" then
    return is_cursor_at_last_line()
  end

  return true
end

function _quickfix.is_installed()
  return true
end

return _quickfix
