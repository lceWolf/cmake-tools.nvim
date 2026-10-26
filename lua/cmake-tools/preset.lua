local osys = require("cmake-tools.osys")
local utils = require("cmake-tools.utils")

---@class ConfigurePreset: CMakeConfigurePreset
local Preset = {}
Preset.__index = Preset

local function expandMacro(self, str)
  if type(str) == "table" and str.value ~= nil then
    str = str.value
  end

  if type(str) ~= "string" then
    return str
  end

  str = str:gsub("%$env{(.-)}", function(envVar)
    return self.environment[envVar] or vim.env[envVar] or ""
  end)

  str = str:gsub("%$penv{(.-)}", function(envVar)
    return vim.env[envVar] or ""
  end)

  -- macro expansion
  local cwd = utils.normalize(self.cwd)
  local source_relative = vim.fn.fnamemodify(cwd, ":t")
  str = str:gsub("${sourceDir}", ".") -- sourceDir is relative to the CMakePresests.json file, and should be relative
  str = str:gsub("${sourceParentDir}", function()
    return utils.normalize(vim.fs.dirname(cwd))
  end)
  str = str:gsub("${sourceDirName}", source_relative)
  str = str:gsub("${presetName}", self.name)
  if self.generator then
    str = str:gsub("${generator}", self.generator)
  end
  str = str:gsub("${hostSystemName}", osys.iswin32 and "Windows" or vim.loop.os_uname().sysname)
  str = str:gsub("${fileDir}", function()
    return self.fileDir or self.cwd
  end)
  str = str:gsub("${dollar}", "$")
  str = str:gsub("${pathListSep}", osys.iswin32 and ";" or ":")

  return str
end

local function resolveBuildDir(self)
  if not self.binaryDir then
    return
  end
  self.binaryDirExpanded = expandMacro(self, self.binaryDir)
end

local function resolveCacheVariables(self)
  for key, var in pairs(self.cacheVariables or {}) do
    self.cacheVariables[key] = expandMacro(self, var)
  end
end

local function resolveConditions(self)
  local function evalCondition(preset)
    local function eval(cond)
      if type(cond) ~= "table" then
        error("condition field has to be a JSON object")
      end

      local ctype = cond.type
      if not ctype then
        error("condition field missing required field 'type'")
      end

      local function equals()
        if type(cond.lhs) ~= "string" then
          error("condition field missing required string field 'lhs'")
        elseif type(cond.rhs) ~= "string" then
          error("condition field missing required string field 'rhs'")
        end
        return expandMacro(self, cond.lhs) == expandMacro(self, cond.rhs)
      end

      local function inList()
        if type(cond.string) ~= "string" then
          error("condition field missing required string field 'string'")
        end
        if not vim.isarray(cond.list) then
          error("condition field missing required array field 'list'")
        end

        local str = expandMacro(self, cond.string)

        for _, entry in ipairs(cond.list) do
          if type(entry) ~= "string" then
            error("list field must be of type string")
          end
          if str == expandMacro(self, entry) then
            return true
          end
        end

        return false
      end

      if ctype == "const" then
        if type(cond.value) ~= "boolean" then
          error("condition type 'const' requires a boolean field 'value'")
        end
        return cond.value
      elseif ctype == "equals" then
        return equals()
      elseif ctype == "notEquals" then
        return not equals()
      elseif ctype == "inList" then
        return inList()
      elseif ctype == "notInList" then
        return not inList()
      elseif ctype == "anyOf" then
        if not vim.isarray(cond.conditions) then
          error("conditions field must be of type array")
        end
        for _, nestedCond in ipairs(cond.conditions) do
          if eval(nestedCond) then
            return true
          end
        end
        return false
      elseif ctype == "allOf" then
        if not vim.isarray(cond.conditions) then
          error("conditions field must be of type array")
        end
        for _, nestedCond in ipairs(cond.conditions) do
          if not eval(nestedCond) then
            return false
          end
        end
        return true
      elseif ctype == "not" then
        if type(cond.condition) ~= "table" then
          error("condition field 'condition' must be of type object")
        end
        return not eval(cond.condition)
      else
        -- matches and notMatches currently not supported due to lua's limited regex support
        -- for now, lets just pass the check and let cmake handle the rest
        return true
      end
    end

    if not preset.condition then
      return
    end
    return eval(preset.condition)
  end

  -- The condition is inherited like any other field, so only our own one needs to be checked
  self.disabled = evalCondition(self) == false
end

local function resolveEnvVars(self)
  local function resolve(value, visitedKeys)
    if type(value) ~= "string" then
      return value -- Only resolve string values
    end

    -- Resolve placeholders in the format $env{key}
    value = value:gsub("%$env{(.-)}", function(envVar)
      -- Prevent infinite recursion: a key should not refer to itself
      if visitedKeys[envVar] then
        error("Circular reference detected for key: " .. envVar)
      end

      local envValue = self.environment[envVar]
      if envValue == nil then
        return vim.env[envVar] or ""
      end

      -- Mark this key as visited to detect circular references
      visitedKeys[envVar] = true
      local ret = resolve(envValue, visitedKeys)
      visitedKeys[envVar] = nil -- Unmark the key after resolving

      return ret
    end)

    return value:gsub("%$penv{(.-)}", function(envVar)
      return vim.env[envVar] or ""
    end)
  end

  -- Loop through all the keys in the table and resolve their values
  for key, value in pairs(self.environment) do
    self.environment[key] = resolve(value, { [key] = true })
  end
end

local NON_INHERITED_FIELDS = {
  name = true,
  hidden = true,
  inherits = true,
  description = true,
  displayName = true,
  cwd = true,
  environment = true,
  cacheVariables = true,
  disabled = true,
  binaryDirExpanded = true,
  fileDir = true,
}

-- Replaces ${fileDir} in all strings of value. Tables are modified in place.
local function expandFileDir(value, file_dir)
  if type(value) == "string" then
    return (value:gsub("%${fileDir}", function()
      return file_dir
    end))
  elseif type(value) == "table" then
    for key, nested in pairs(value) do
      value[key] = expandFileDir(nested, file_dir)
    end
  end
  return value
end

local function parentNames(preset)
  if type(preset.inherits) == "string" then
    return { preset.inherits }
  elseif type(preset.inherits) == "table" then
    return preset.inherits
  end
  return {}
end

-- Returns fresh copies of the fields 'preset' provides to its children, including the ones it
-- inherits itself. The presets returned by 'get_preset' are only read, never modified.
local function flattenInheritance(preset, get_preset, visiting)
  local fields = {
    environment = vim.deepcopy(preset.environment or {}),
    cacheVariables = vim.deepcopy(preset.cacheVariables or {}),
  }
  for key, value in pairs(preset) do
    if not NON_INHERITED_FIELDS[key] then
      fields[key] = vim.deepcopy(value)
    end
  end

  -- ${fileDir} is the directory of the file that defines a value, so it is expanded before the
  -- fields of parents from other files are merged in
  if preset.fileDir then
    expandFileDir(fields, preset.fileDir)
  end

  -- Earlier parents win and each parent brings along everything it inherits itself
  for _, name in ipairs(parentNames(preset)) do
    local parent = not visiting[name] and get_preset(name)
    if parent then
      visiting[name] = true
      local inherited = flattenInheritance(parent, get_preset, visiting)
      visiting[name] = nil

      fields.environment = vim.tbl_deep_extend("keep", fields.environment, inherited.environment)
      fields.cacheVariables =
        vim.tbl_deep_extend("keep", fields.cacheVariables, inherited.cacheVariables)
      for key, value in pairs(inherited) do
        if fields[key] == nil then
          fields[key] = value
        end
      end
    end
  end

  return fields
end

local function parseTree(self, get_preset)
  for key, value in pairs(flattenInheritance(self, get_preset, { [self.name] = true })) do
    self[key] = value
  end
end

---@param cwd string
---@param obj CMakeConfigurePreset?
---@param get_preset fun(name: string): CMakeConfigurePreset?
---@return ConfigurePreset
function Preset:new(cwd, obj, get_preset)
  local instance = setmetatable(obj or {}, self)
  instance.environment = instance.environment or {}
  instance.cwd = cwd

  parseTree(instance, get_preset)
  resolveEnvVars(instance)
  resolveCacheVariables(instance)
  resolveBuildDir(instance)
  -- We have to resolve the environment first as the condition might depend on envVars
  resolveConditions(instance)

  return instance
end

---@return string
function Preset:get_build_type()
  return self.cacheVariables and self.cacheVariables.CMAKE_BUILD_TYPE or "Debug"
end

---@return string[]|nil
function Preset:get_build_configuration_types()
  local generator = self.generator
  local multi_configuration_generator = { "Visual Studio", "Xcode", "Ninja Multi-Config" }
  local support_multi_configuration = false
  for i, val in ipairs(multi_configuration_generator) do
    if val == generator then
      support_multi_configuration = true
    end
  end
  if not support_multi_configuration then
    return nil
  end
  if self.cacheVariables == nil then
    return nil
  end
  if self.cacheVariables.CMAKE_CONFIGURATION_TYPES == nil then
    return nil
  end
  local configuration_types = self.cacheVariables.CMAKE_CONFIGURATION_TYPES

  return utils.split_string_by_delimiter(configuration_types, ";")
end

return Preset
