local osys = require("cmake-tools.osys")
local Result = require("cmake-tools.result")
local Types = require("cmake-tools.types")
local notification = require("cmake-tools.notification")
local scratch = require("cmake-tools.scratch")

---@alias executor_conf {name:string, opts:table}
---@alias runner_conf {name:string, opts:table}

local utils = {}

---Save all named, modified, normal buffers
function utils.save_all_named_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].modified
      and vim.bo[buf].buftype == ""
      and vim.api.nvim_buf_get_name(buf) ~= ""
    then
      vim.api.nvim_buf_call(buf, function()
        vim.cmd("silent! write")
      end)
    end
  end
end

function utils.get_cmake_configuration(cwd)
  local cmakelists = utils.join(cwd, "CMakeLists.txt")
  if not utils.is_file(cmakelists) then
    return Result:new(
      Types.CANNOT_FIND_CMAKE_CONFIGURATION_FILE,
      nil,
      "Cannot find CMakeLists.txt at cwd (" .. cwd .. ")."
    )
  end
  return Result:new(Types.SUCCESS, cmakelists, "cmake-tools has found CMakeLists.txt.")
end

-- Get string representation for object o
function utils.dump(o)
  if type(o) == "table" then
    local s = "{ "
    for k, v in pairs(o) do
      if type(k) ~= "number" then
        k = '"' .. k .. '"'
      end
      s = s .. "[" .. k .. "] = " .. utils.dump(v) .. ","
    end
    return s .. "} "
  else
    return tostring(o)
  end
end

function utils.get_path(str, sep)
  sep = sep or (osys.iswin32 and "\\" or "/")
  return str:match("(.*" .. sep .. ")")
end

---@param dir string
---@return boolean success
function utils.mkdir(dir)
  if utils.is_dir(dir) then
    return true
  end
  pcall(vim.fn.mkdir, dir, "p")
  return utils.is_dir(dir)
end

---@param file string
function utils.rmfile(file)
  if utils.file_exists(file) then
    os.remove(file)
  end
end

---@param path string
---@return boolean
function utils.file_exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

---@param path string
---@return boolean
function utils.is_file(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "file"
end

---@param path string
---@return boolean
function utils.is_dir(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

---Create an empty file if it does not exist yet
---@param path string
---@return boolean success
function utils.touch(path)
  local file = io.open(path, "a")
  if not file then
    return false
  end
  file:close()
  return true
end

---@param path string
---@return string|nil content
---@return string|nil err
function utils.read_file(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content
end

---@param path string
---@return table
function utils.read_json(path)
  local content, err = utils.read_file(path)
  if not content then
    error(string.format("cmake-tools: cannot read %s: %s", path, err), 2)
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    error(string.format("cmake-tools: cannot parse %s: %s", path, decoded), 2)
  end
  return decoded
end

---@param path string
---@return string
function utils.normalize(path)
  local normalized = vim.fs.normalize(path, { expand_env = false, win = osys.iswin32 })
  if osys.iswin32 then
    -- nvim 0.10 keeps the drive letter case, later versions uppercase it
    normalized = normalized:gsub("^%a:", string.upper):gsub("/", "\\")
  end
  return normalized
end

---@param path string
---@return boolean
function utils.is_absolute(path)
  if osys.iswin32 then
    -- drive letter or UNC path
    return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
  end
  return path:sub(1, 1) == "/"
end

---@param ... string
---@return string
function utils.join(...)
  local segments = vim.tbl_filter(function(segment)
    return segment ~= ""
  end, { ... })
  return utils.normalize(table.concat(segments, "/"))
end

---Normalized absolute path, relative paths are resolved against base
---@param path string
---@param base string? defaults to the current working directory
---@return string
function utils.abspath(path, base)
  path = utils.normalize(path)
  if utils.is_absolute(path) then
    return path
  end
  return utils.join(base or vim.uv.cwd(), path)
end

function utils.deepcopy(orig, copies)
  copies = copies or {}
  local orig_type = type(orig)
  local copy
  if orig_type == "table" then
    if copies[orig] then
      copy = copies[orig]
    else
      copy = {}
      copies[orig] = copy
      for orig_key, orig_value in next, orig, nil do
        copy[utils.deepcopy(orig_key, copies)] = utils.deepcopy(orig_value, copies)
      end
      setmetatable(copy, utils.deepcopy(getmetatable(orig), copies))
    end
  else -- number, string, boolean, etc
    copy = orig
  end
  return copy
end

function utils.copyfile(src, target)
  if utils.file_exists(src) then
    -- if we don't always use terminal
    local cmd = table.concat({
      "exec",
      "'!cmake -E copy",
      utils.shell_quote(src),
      utils.shell_quote(target) .. "'",
    }, " ")
    vim.cmd(cmd)
  end
end

function utils.softlink(src, target)
  if not utils.file_exists(src) then
    return
  end

  local stat = vim.loop.fs_lstat(target)
  if stat then
    if stat.type == "link" then
      if vim.loop.fs_readlink(target) == src then
        return
      end
    else
      -- target is a regular file, remove it first
      os.remove(target)
    end
  end

  local cmd = table.concat({
    "exec",
    "'!cmake -E create_symlink",
    utils.shell_quote(src),
    utils.shell_quote(target) .. "'",
  }, " ")
  vim.cmd(cmd)
end

function utils.shell_quote(str)
  -- If the string already contains a double quote, assume the caller has handled quoting/escaping and leave it untouched
  if not string.find(str, '"') and string.find(str, " ") then
    return '"' .. str .. '"'
  else
    return str
  end
end

--- Get the appropriate executor by name
---@param name string
---@return executor
function utils.get_executor(name)
  return require("cmake-tools.executors")[name]
end

--- Get the appropriate runner by name
---@param name string
---@return runner
function utils.get_runner(name)
  return require("cmake-tools.runners")[name]
end

---@param executor_data executor_conf
function utils.show_executor(executor_data)
  utils.get_executor(executor_data.name).show(executor_data.opts)
end

---@param runner_data runner_conf
function utils.show_runner(runner_data)
  utils.get_runner(runner_data.name).show(runner_data.opts)
end

---@param executor_data executor_conf
function utils.close_executor(executor_data)
  utils.get_executor(executor_data.name).close(executor_data.opts)
end

---@param runner_data runner_conf
function utils.close_runner(runner_data)
  utils.get_runner(runner_data.name).close(runner_data.opts)
end

---@param executor_data executor_conf
function utils.stop_executor(executor_data)
  utils.get_executor(executor_data.name).stop(executor_data.opts)
end

---@param runner_data runner_conf
function utils.stop_runner(runner_data)
  utils.get_runner(runner_data.name).stop(runner_data.opts)
end

--- Check if exists active job.
---@param runner_data executor_conf the runner
---@param executor_data executor_conf the executor
-- @return true if exists else false
function utils.has_active_job(runner_data, executor_data)
  return utils.get_executor(executor_data.name).has_active_job(executor_data.opts)
  -- or utils.get_runner(runner_data.name).has_active_job(runner_data.opts)
end

-- build progress of make, e.g. [ 12%], or ninja, e.g. [3/10]
local function is_progress_line(line)
  return line:match("^%[%s*%d+%%%]") ~= nil or line:match("^%[%d+/%d+%]") ~= nil
end

-- the headline of a compiler or cmake diagnostic, not the source excerpt or notes that follow it,
-- e.g. "a.cpp:1:17: error: ...", "a.cpp(1): warning C4101: ..." or "CMake Error at ..."
local function is_diagnostic_line(line)
  return line:find("error:") ~= nil
    or line:find("warning:") ~= nil
    or line:find(": error %u+%d+") ~= nil
    or line:find(": warning %u+%d+") ~= nil
    or line:find("^CMake Error") ~= nil
    or line:find("^CMake Warning") ~= nil
end

local notify_update_line = function(ntfy)
  return function(out, err)
    if not ntfy.enabled then
      return
    end
    local data = err or out
    -- some backends (e.g. toggleterm) pass a list of lines instead of a single line
    local lines = type(data) == "table" and data or { data }
    for _, line in ipairs(lines) do
      -- check both streams, ninja forwards the compiler output to stdout
      local level = type(line) == "string"
        and (is_diagnostic_line(line) and "warn" or is_progress_line(line) and "info")
      if level then
        ntfy:startSpinner()
        ntfy:notify(line, level)
      end
    end
  end
end

---Apply wrap_call to a command, prepending the wrapper command and its arguments
---@param wrap_call string[]|nil table of wrapper command and its arguments
---@param cmd string the original command
---@param args table the original arguments
---@return string cmd the new command
---@return table args the new arguments
function utils.apply_wrap_call(wrap_call, cmd, args)
  if not wrap_call or #wrap_call == 0 then
    return cmd, args
  end
  local new_cmd = wrap_call[1]
  local new_args = {}
  for i = 2, #wrap_call do
    table.insert(new_args, wrap_call[i])
  end
  table.insert(new_args, cmd)
  vim.list_extend(new_args, args)
  return new_cmd, new_args
end

---Run a command using specified executor, this is used by generate, build, clean, install, etc.
---@param cmd string the executable to execute
---@param env_script string environment setup script
---@param env table environment variables
---@param args table arguments to the executable
---@param cwd string the directory to run in
---@param runner runner_conf the executor or runner
---@param callback nil|function extra arguments, f.e on_success is a callback to be called when the process finishes
---@return nil
function utils.run(cmd, env_script, env, args, cwd, runner, callback)
  -- save all
  utils.save_all_named_buffers()

  local ntfy = notification:new("runner")

  ntfy:notify(cmd, "info")

  if scratch.buffer ~= nil then
    local _mes =
      { "[RUN]:", cmd, table.concat(args, " "), "<ENV>", table.concat(env, " "), "{CWD}", cwd }
    scratch.append(table.concat(_mes, " "))
  end

  utils.get_runner(runner.name).run(cmd, env_script, env, args, cwd, runner.opts, function(code)
    ntfy:stopSpinner()
    local msg = "Exited with code " .. code
    local icon = ""
    local level = nil -- use the previously defined level
    if code ~= 0 then
      level = "error"
      icon = ""
    end
    ntfy:notify(msg, level, { icon = icon, timeout = 3000 })
    if type(callback) == "function" then
      if code == 0 then
        callback(Result:new(Types.SUCCESS, nil, nil))
      else
        callback(Result:new(Types.CMAKE_RUN_FAILED, nil, "Process exited with code " .. code))
      end
    end
  end, notify_update_line(ntfy))
end

---Run a command using specified executor, this is used by generate, build, clean, install, etc.
---@param cmd string the executable to execute
---@param env_script string environment setup script
---@param env table environment variables
---@param args table arguments to the executable
---@param cwd string the directory to run in
---@param executor executor_conf the executor or runner
---@param callback nil|fun(cmake.Result) extra arguments, f.e on_success is a callback to be called when the process exits with a 0 exit code
---@return nil
function utils.execute(cmd, env_script, env, args, cwd, executor, callback)
  -- save all
  utils.save_all_named_buffers()

  local ntfy = notification:new("executor")
  ntfy:notify(cmd, "info")

  if scratch.buffer ~= nil then
    local _mes =
      { "[EXECUTE]:", cmd, table.concat(args, " "), "<ENV>", table.concat(env, " "), "{CWD}", cwd }
    scratch.append(table.concat(_mes, " "))
  end

  utils
    .get_executor(executor.name)
    .run(cmd, env_script, env, args, cwd, executor.opts, function(code)
      ntfy:stopSpinner()
      local msg = "Exited with code " .. code
      local level = nil -- use the previously defined level
      local icon = ""
      if code ~= 0 then
        level = "error"
        icon = ""
      end
      ntfy:notify(msg, level, { icon = icon, timeout = 3000 })
      if type(callback) == "function" then
        if code == 0 then
          callback(Result:new(Types.SUCCESS, nil, nil))
        else
          callback(
            Result:new(
              Types.CMAKE_RUN_FAILED,
              nil,
              string.format(
                "Process %s %s (cwd=%s) exited with code %d",
                cmd,
                table.concat(args, " "),
                cwd,
                code
              )
            )
          )
        end
      end
    end, notify_update_line(ntfy))
end

function utils.get_nested(tbl, ...)
  local value = tbl
  for _, key in ipairs({ ... }) do
    value = value and value[key]
    if value == nil then
      return nil
    end
  end
  return value
end

function utils.split_string_by_delimiter(s, delimiter, item)
  local delimiter1 = delimiter or ";"
  local answer = vim.split(s, delimiter1, { plain = true, trimempty = true })
  if #answer == 0 then
    return nil
  elseif item then -- does the user want an entry verses a parsed table?
    if #answer >= item then
      return answer[item]
    else
      return nil
    end
  else
    return answer
  end
end

return utils
