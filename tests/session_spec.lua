local Config = require("cmake-tools.config")

local join = vim.fs.joinpath

local const = {
  cmake_build_directory = "build",
  cmake_generate_options = {},
  cmake_build_options = {},
  cmake_use_preset = false,
  cmake_show_disabled_build_presets = true,
  ctest_show_labels = false,
}

describe("session", function()
  local tmp, saved_env, session, session_dir, project

  -- the file name is the project path without separators and colons
  local function session_file(dir)
    return join(dir, project:gsub("[/\\:]", "") .. ".lua")
  end

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    saved_env = { HOME = vim.env.HOME, XDG_DATA_HOME = vim.env.XDG_DATA_HOME }
    vim.env.HOME = join(tmp, "home")
    vim.env.XDG_DATA_HOME = join(tmp, "data")
    vim.fn.mkdir(vim.env.HOME, "p")

    -- the session directory is computed when the module is loaded
    package.loaded["cmake-tools.session"] = nil
    session = require("cmake-tools.session")
    session.setup(const)
    session_dir = join(tmp, "data", "nvim", "cmake_tools_nvim")
    project = join(tmp, "project")
  end)

  after_each(function()
    vim.env.HOME = saved_env.HOME
    vim.env.XDG_DATA_HOME = saved_env.XDG_DATA_HOME
    package.loaded["cmake-tools.session"] = nil
    vim.fn.delete(tmp, "rf")
  end)

  it("loads nothing for a project without a session", function()
    assert.same({}, session.load(project))
    assert.equals(1, vim.fn.isdirectory(session_dir))
  end)

  it("saves the state that differs from the defaults and loads it again", function()
    local config = Config:new(const)
    config.cwd = project
    config:update_build_dir("build", "build")
    config.build_type = "Release"
    config.build_target = "app"

    session.save(project, config)
    local loaded = session.load(project)

    assert.equals(1, vim.fn.filereadable(session_file(session_dir)))
    assert.equals("Release", loaded.build_type)
    assert.equals("app", loaded.build_target)
    assert.equals(project, loaded.cwd)
    assert.equals(join(project, "build"), loaded.build_directory)
  end)

  it("migrates session files from the legacy cache directory", function()
    local old_dir = join(tmp, "home", ".cache", "cmake_tools_nvim")
    vim.fn.mkdir(old_dir, "p")
    vim.fn.writefile({ 'return { build_type = "Release" }' }, session_file(old_dir))

    local loaded = session.load(project)

    assert.equals("Release", loaded.build_type)
    assert.equals(1, vim.fn.filereadable(session_file(session_dir)))
    assert.equals(0, vim.fn.isdirectory(old_dir))
  end)

  it("keeps a session file that already exists in the new location", function()
    local old_dir = join(tmp, "home", ".cache", "cmake_tools_nvim")
    vim.fn.mkdir(old_dir, "p")
    vim.fn.mkdir(session_dir, "p")
    vim.fn.writefile({ 'return { build_type = "Legacy" }' }, session_file(old_dir))
    vim.fn.writefile({ 'return { build_type = "Current" }' }, session_file(session_dir))

    local loaded = session.load(project)

    assert.equals("Current", loaded.build_type)
    assert.equals(0, vim.fn.isdirectory(old_dir))
  end)
end)
