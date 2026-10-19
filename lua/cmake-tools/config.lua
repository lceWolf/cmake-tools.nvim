local Result = require("cmake-tools.result")
local utils = require("cmake-tools.utils")
local Types = require("cmake-tools.types")
local variants = require("cmake-tools.variants")
local Presets = require("cmake-tools.presets")
local kits = require("cmake-tools.kits")

---@class Config.BaseSettings
---@field env table
---@field build_dir string
---@field working_dir string
---@field use_preset boolean
---@field generate_options string[]
---@field build_options string[]
---@field show_disabled_build_presets boolean
---@field ctest_show_labels boolean

---@class Config
---@field build_directory string?
---@field query_directory string?
---@field reply_directory string?
---@field build_type string?
---@field variant table?
---@field build_target string|string[]|nil
---@field launch_target string?
---@field kit string?
---@field configure_preset string?
---@field build_preset string?
---@field test_preset string?
---@field selected_test string?
---@field base_settings Config.BaseSettings
---@field target_settings table
---@field executor table?
---@field runner table?
---@field env_script string
---@field cwd string
local Config = {}
Config.__index = Config

---@param const Const
---@return Config
function Config:new(const)
  local obj = {
    base_settings = {
      env = {},
      build_dir = "",
      working_dir = "${dir.binary}",
      use_preset = true,
      generate_options = {},
      build_options = {},
      show_disabled_build_presets = true,
      ctest_show_labels = false,
    }, -- general config
    target_settings = {}, -- target specific config
    env_script = " ",
    cwd = vim.loop.cwd(),
  }
  setmetatable(obj, Config)

  obj:update_build_dir(const.cmake_build_directory, const.cmake_build_directory)

  obj.base_settings.generate_options = const.cmake_generate_options
  obj.base_settings.build_options = const.cmake_build_options
  obj.base_settings.use_preset = const.cmake_use_preset

  obj.base_settings.show_disabled_build_presets = const.cmake_show_disabled_build_presets
  obj.base_settings.ctest_show_labels = const.ctest_show_labels

  obj.executor = const.cmake_executor
  obj.runner = const.cmake_runner

  return obj
end

---@return string
function Config:build_directory_path()
  return self.build_directory
end

---@return boolean
function Config:has_build_directory()
  return self.build_directory ~= nil and utils.is_dir(self.build_directory)
end

---The reason for storing no expand build directory is to make cwd selecting easier
---@return string
function Config:no_expand_build_directory_path()
  return self.base_settings.build_dir
end

---@param build_dir string|function string or a function returning string containing path to the build dir
---@param no_expand_build_dir string|function
function Config:update_build_dir(build_dir, no_expand_build_dir)
  if type(build_dir) == "function" then
    build_dir = build_dir()
  end
  if type(build_dir) ~= "string" then
    error("build_dir needs to be a string or function returning string path to the build_directory")
  end
  if type(no_expand_build_dir) == "function" then
    no_expand_build_dir = no_expand_build_dir()
  end
  if type(no_expand_build_dir) ~= "string" then
    error(
      "no_expand_build_dir needs to be a string or function returning string path to the build_directory"
    )
  end

  build_dir = utils.abspath(build_dir, self.cwd)
  self.build_directory = build_dir
  self.query_directory = utils.join(build_dir, ".cmake", "api", "v1", "query")
  self.reply_directory = utils.join(build_dir, ".cmake", "api", "v1", "reply")

  self.base_settings.build_dir = utils.abspath(no_expand_build_dir, self.cwd)
end

---Prepare build directory with macro expansion
---@param kit_list table all the kits
---@return string
function Config:prepare_build_directory(kit_list)
  -- macro expansion:
  --       ${kit}
  --       ${kitGenerator}
  --       ${variant:xx}
  -- get the detailed info of the selected kit
  local build_dir = self:no_expand_build_directory_path()
  local kit = self.kit
  local variant = self.variant
  local kit_info = nil
  if kit_list then
    for _, item in ipairs(kit_list) do
      if item.name == kit then
        kit_info = item
      end
    end
  end
  build_dir = build_dir:gsub("${kit}", kit_info and kit_info.name or "")
  build_dir = build_dir:gsub("${kitGenerator}", kit_info and kit_info.generator or "")

  build_dir = build_dir:gsub("${variant:(%w+)}", function(v)
    if variant and variant[v] then
      return variant[v]
    end

    return ""
  end)

  return build_dir
end

---@return string[]
function Config:generate_options()
  return self.base_settings.generate_options and self.base_settings.generate_options or {}
end

---@return string[]
function Config:build_options()
  return self.base_settings.build_options and self.base_settings.build_options or {}
end

---@return boolean
function Config:show_disabled_build_presets()
  return self.base_settings.show_disabled_build_presets
end

---@return boolean
function Config:ctest_show_labels()
  return self.base_settings.ctest_show_labels
end

---@return cmake.Result
function Config:generate_build_directory()
  if not utils.mkdir(self.build_directory) then
    return Result:new(Types.CANNOT_CREATE_DIRECTORY, false, "cannot create directory")
  end
  return self:generate_query_files()
end

---@return cmake.Result
function Config:generate_query_files()
  local query_directory = self.query_directory
  if not utils.mkdir(query_directory) then
    return Result:new(Types.CANNOT_CREATE_DIRECTORY, false, "cannot create directory")
  end

  local codemodel_file = utils.join(query_directory, "codemodel-v2")
  if not utils.is_file(codemodel_file) then
    if not utils.touch(codemodel_file) then
      return Result:new(
        Types.CANNOT_CREATE_CODEMODEL_QUERY_FILE,
        nil,
        "Unable to create file " .. codemodel_file
      )
    end
  end

  local cmakeFiles_file = utils.join(query_directory, "cmakeFiles-v1")
  if not utils.is_file(cmakeFiles_file) then
    if not utils.touch(cmakeFiles_file) then
      return Result:new(
        Types.CANNOT_CREATE_CODEMODEL_QUERY_FILE,
        nil,
        "Unable to create file " .. cmakeFiles_file
      )
    end
  end

  return Result:new(Types.SUCCESS, true, "yeah, that could be")
end

---@param dir string
---@param prefix string
---@return string?
local function find_reply_file(dir, prefix)
  for name, type in vim.fs.dir(dir) do
    if type == "file" and vim.startswith(name, prefix) then
      return utils.join(dir, name)
    end
  end
end

---@return cmake.Result
function Config:get_cmake_files()
  -- if reply_directory exists
  if not utils.is_dir(self.reply_directory) then
    return Result:new(Types.NOT_CONFIGURED, nil, "Configure fail")
  end

  local found_file = find_reply_file(self.reply_directory, "cmakeFiles")
  if not found_file then
    return Result:new(Types.CANNOT_FIND_CODEMODEL_FILE, nil, "Unable to find codemodel file")
  end
  local codemodel_json = utils.read_json(found_file)
  return Result:new(Types.SUCCESS, codemodel_json["inputs"], "find it")
end

---@return cmake.Result
function Config:get_codemodel_targets()
  -- if reply_directory exists
  if not utils.is_dir(self.reply_directory) then
    return Result:new(Types.NOT_CONFIGURED, nil, "Configure fail")
  end

  local found_file = find_reply_file(self.reply_directory, "codemodel")
  if not found_file then
    return Result:new(Types.CANNOT_FIND_CODEMODEL_FILE, nil, "Unable to find codemodel file")
  end
  local codemodel_json = utils.read_json(found_file)
  for _, config in ipairs(codemodel_json["configurations"]) do
    if config["name"] == self.build_type then
      return Result:new(Types.SUCCESS, config["targets"], "find it")
    end
  end
  return Result:new(Types.SUCCESS, codemodel_json["configurations"][1]["targets"], "find it") -- Return the first else
end

---@param codemodel_target table
---@return table
function Config:get_code_model_target_info(codemodel_target)
  return utils.read_json(utils.join(self.reply_directory, codemodel_target["jsonFile"]))
end

---Check if launch target is built
---@return cmake.Result
function Config:check_launch_target()
  -- 1. not configured
  if not utils.is_dir(self.build_directory) then
    return Result:new(Types.NOT_CONFIGURED, nil, "You need to configure it first")
  end

  -- 2. not select launch target yet
  if not self.launch_target then
    return Result:new(Types.NOT_SELECT_LAUNCH_TARGET, nil, "You need to select launch target first")
  end

  local codemodel_targets = self:get_codemodel_targets()
  if codemodel_targets.code ~= Types.SUCCESS then
    return codemodel_targets
  end
  codemodel_targets = codemodel_targets.data

  for _, target in ipairs(codemodel_targets) do
    if self.launch_target == target["name"] then
      local target_info = self:get_code_model_target_info(target)
      local type = target_info["type"]:lower():gsub("_", " ")
      if type ~= "executable" then
        -- 3. selected target cannot execute
        return Result:new(Types.NOT_EXECUTABLE, nil, "You need to select a executable target")
      end
      return Result:new(Types.SUCCESS, target_info, "Success")
    end
  end

  return Result:new(
    Types.NOT_A_LAUNCH_TARGET,
    nil,
    "Unable to find the following target: " .. self.launch_target
  )
end

---@param target_info table
---@return cmake.Result
function Config:get_launch_target_from_info(target_info)
  -- relative artifact paths are based on the build directory
  local target_path = utils.abspath(target_info["artifacts"][1]["path"], self.build_directory)

  if not utils.is_file(target_path) then
    return Result:new(
      Types.SELECTED_LAUNCH_TARGET_NOT_BUILT,
      target_path,
      "Selected target is not built: " .. target_path
    )
  end

  return Result:new(Types.SUCCESS, target_path, "yeah, that's good")
end

---Retrieve launch target path
---@return cmake.Result
function Config:get_launch_target()
  local check_result = self:check_launch_target()
  if check_result.code ~= Types.SUCCESS then
    return check_result
  end
  local target_info = check_result.data

  return self:get_launch_target_from_info(target_info)
end

---Check if build target exists
---@return cmake.Result
function Config:check_build_target()
  -- 1. not configured
  if not utils.is_dir(self.build_directory) then
    return Result:new(Types.NOT_CONFIGURED, nil, "You need to configure it first")
  end

  -- 2. not select build target yet
  if not self.build_target then
    return Result:new(Types.NOT_SELECT_BUILD_TARGET, nil, "You need to select Build target first")
  end

  local codemodel_targets = self:get_codemodel_targets()
  if codemodel_targets.code ~= Types.SUCCESS then
    return codemodel_targets
  end
  codemodel_targets = codemodel_targets.data

  for _, target in ipairs(codemodel_targets) do
    if self.build_target == target["name"] then
      local target_info = self:get_code_model_target_info(target)
      -- local type = target_info["type"]:lower():gsub("_", " ")
      return Result:new(Types.SUCCESS, target_info, "Success")
    end
  end

  return Result:new(
    Types.NOT_A_BUILD_TARGET,
    nil,
    "Unable to find the following target: " .. self.build_target
  )
end

---Retrieve build target path
---@return cmake.Result
function Config:get_build_target()
  local check_result = self:check_build_target()
  if check_result.code ~= Types.SUCCESS then
    return check_result
  end
  local target_info = check_result.data
  -- relative artifact paths are based on the build directory
  local target_path = utils.abspath(target_info["artifacts"][1]["path"], self.build_directory)

  if not utils.is_file(target_path) then
    return Result:new(
      Types.SELECTED_LAUNCH_TARGET_NOT_BUILT,
      nil,
      "Selected target is not built: " .. target_path
    )
  end

  return Result:new(Types.SUCCESS, target_path, "yeah, that's good")
end

---Check if this launch target is debuggable using variants.debuggable
---@return cmake.Result
function Config:validate_for_debugging()
  local build_type = self.build_type

  if not build_type or not variants.debuggable(build_type, self.cwd) then
    return Result:new(Types.CANNOT_DEBUG_LAUNCH_TARGET, false, "cannot debug it")
  end
  return Result:new(Types.SUCCESS, true, "Yeah, it may be")
end

---@param config Config
---@param opt { has_all: boolean, only_executable: boolean, query_sources: boolean? }
---@return cmake.Result
local function get_targets(config, opt)
  local targets, display_targets, paths, abs_paths = {}, {}, {}, {}
  local sources = {}
  if opt.has_all then
    table.insert(targets, "all")
    table.insert(display_targets, "all")
  end
  local codemodel_targets = config:get_codemodel_targets()
  if codemodel_targets.code ~= Types.SUCCESS then
    return codemodel_targets
  end

  codemodel_targets = codemodel_targets.data
  for _, target in ipairs(codemodel_targets) do
    local target_info = config:get_code_model_target_info(target)
    local target_name = target_info["name"]
    local target_name_on_disk = target_info["nameOnDisk"]
    if target_name:find("_autogen") == nil then
      local type = target_info["type"]:lower():gsub("_", " ")
      local display_name = target_name .. " (" .. type .. ")"
      local path = target_info["paths"]["build"]
      if target_name_on_disk ~= nil then -- only executables have name on disk?
        path = path .. "/" .. target_name_on_disk
      end
      local abs_path = ""
      if type == "executable" then
        abs_path = utils.abspath(target_info["artifacts"][1]["path"], config.build_directory)
      end
      if not (opt.only_executable and (type ~= "executable")) then
        if target_name == config.build_target then
          table.insert(targets, 1, target_name)
          table.insert(display_targets, 1, display_name)
          table.insert(paths, 1, path)
          table.insert(abs_paths, 1, abs_path)
        else
          table.insert(targets, target_name)
          table.insert(display_targets, display_name)
          table.insert(paths, path)
          table.insert(abs_paths, abs_path)
        end
      end
      if opt.query_sources then -- get all source files related to this target
        for _, source in ipairs(target_info["sources"]) do
          local source_abs_path = utils.abspath(source["path"], config.cwd)
          table.insert(
            sources,
            { path = source_abs_path, type = type, name = target_name, display_name = display_name }
          )
        end
      end
    end
  end

  if opt.query_sources then
    return Result:new(Types.SUCCESS, {
      targets = targets,
      display_targets = display_targets,
      paths = paths,
      abs_paths = abs_paths,
      sources = sources,
    }, "Success!")
  else
    return Result:new(
      Types.SUCCESS,
      { targets = targets, display_targets = display_targets, paths = paths, abs_paths = abs_paths },
      "Success!"
    )
  end
end

---@return table
function Config:get_code_model_info()
  local codemodel_targets = self:get_codemodel_targets()
  if codemodel_targets.code ~= Types.SUCCESS then
    return codemodel_targets
  end

  local result = {}

  codemodel_targets = codemodel_targets.data
  for _, target in ipairs(codemodel_targets) do
    local target_info = self:get_code_model_target_info(target)
    local name = target_info["name"]
    result[name] = target_info
  end
  return result
end

---@return cmake.Result
function Config:launch_targets()
  return get_targets(self, { has_all = false, only_executable = true })
end

---@return cmake.Result
function Config:build_targets()
  return get_targets(self, { has_all = true, only_executable = false })
end

---@return cmake.Result
function Config:launch_targets_with_sources()
  return get_targets(self, { has_all = false, only_executable = true, query_sources = true })
end

local _virtual_targets = nil

function Config:update_targets()
  _virtual_targets =
    get_targets(self, { has_all = false, only_executable = false, query_sources = true })
end

---@return cmake.Result?
function Config:build_targets_with_sources()
  if not _virtual_targets then
    self:update_targets()
  end
  return _virtual_targets
end

---Update build type from configure and build presets
function Config:update_build_type()
  local presets_exists = self.base_settings.use_preset and Presets.exists(self.cwd)
  if not presets_exists then
    return
  end
  local presets = Presets:parse(self.cwd)
  if not presets then
    return
  end
  if not self.configure_preset then
    return
  end
  local configure_preset =
    presets:get_configure_preset(self.configure_preset, { include_hidden = true })
  if not configure_preset then
    return
  end

  self.build_type = configure_preset:get_build_type()

  if not self.build_preset then
    return
  end
  local build_preset = presets:get_build_preset(self.build_preset)
  if not build_preset then
    return
  end
  local configuration_types = configure_preset:get_build_configuration_types()

  if not configuration_types then
    return
  end
  local build_type_from_build_preset = build_preset:get_build_type()

  if not build_type_from_build_preset then
    return
  end
  local exists = false
  for _, Item in ipairs(configuration_types) do
    if Item == build_type_from_build_preset then
      exists = true
      break
    end
  end
  if exists then
    self.build_type = build_type_from_build_preset
  end
end

---Update build target from build preset
function Config:update_build_target()
  local presets_exists = self.base_settings.use_preset and Presets.exists(self.cwd)
  if not presets_exists then
    return
  end

  local presets = Presets:parse(self.cwd)
  if not presets then
    return
  end
  if not self.configure_preset then
    return
  end
  local configure_preset =
    presets:get_configure_preset(self.configure_preset, { include_hidden = true })
  if not configure_preset then
    return
  end

  if not self.build_preset then
    return
  end
  local build_preset = presets:get_build_preset(self.build_preset)
  if not build_preset then
    return
  end
  local build_target = build_preset:get_build_target()
  if build_target ~= nil then
    self.build_target = build_target
  end
end

---Update build directory from kits or configure preset
function Config:update_build_directory()
  local kits_config = kits.parse(self.cmake_kits_path, self.cwd)
  if kits_config then
    local build_dir = self:prepare_build_directory(kits_config)
    self:update_build_dir(build_dir, self:no_expand_build_directory_path())
    return
  end

  local presets_exists = self.base_settings.use_preset and Presets.exists(self.cwd)
  if not presets_exists then
    return
  end
  local presets = Presets:parse(self.cwd)
  if presets then
    if not self.configure_preset then
      return
    end
    local configure_preset =
      presets:get_configure_preset(self.configure_preset, { include_hidden = true })
    if not configure_preset then
      return
    end

    local build_directory, no_expand_build_directory =
      configure_preset.binaryDirExpanded, configure_preset.binaryDir
    if build_directory ~= "" then
      self:update_build_dir(build_directory, no_expand_build_directory)
    end
  end
end

return Config
