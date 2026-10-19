local Config = require("cmake-tools.config")
local Types = require("cmake-tools.types")

local join = vim.fs.joinpath

local function write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

local function new_config(cwd)
  local config = Config:new({
    cmake_build_directory = "build",
    cmake_generate_options = {},
    cmake_build_options = {},
    cmake_use_preset = false,
    cmake_show_disabled_build_presets = true,
    ctest_show_labels = false,
  })
  config.cwd = cwd
  config:update_build_dir("build", "build")
  return config
end

describe("Config", function()
  local tmp, config, build, reply

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    config = new_config(tmp)
    build = join(tmp, "build")
    reply = join(build, ".cmake", "api", "v1", "reply")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("update_build_dir", function()
    it("resolves a relative build dir against cwd", function()
      assert.equals(build, config:build_directory_path())
    end)

    it("keeps an absolute build dir", function()
      local abs = join(tmp, "elsewhere")
      config:update_build_dir(abs, abs)
      assert.equals(abs, config:build_directory_path())
      assert.equals(abs, config:no_expand_build_directory_path())
    end)

    it("stores the unexpanded build dir resolved against cwd", function()
      assert.equals(build, config:no_expand_build_directory_path())
    end)

    it("resolves against the project cwd, not the cwd of neovim", function()
      local other = join(tmp, "other")
      vim.fn.mkdir(other, "p")
      config.cwd = other

      config:update_build_dir("out", "out")

      assert.equals(join(other, "out"), config:build_directory_path())
      assert.equals(join(other, "out"), config:no_expand_build_directory_path())
    end)
  end)

  describe("generate_build_directory", function()
    it("creates the build dir and the cmake file api queries", function()
      assert.is_false(config:has_build_directory())

      local result = config:generate_build_directory()

      assert.equals(Types.SUCCESS, result.code)
      assert.is_true(config:has_build_directory())
      local query = join(build, ".cmake", "api", "v1", "query")
      assert.equals(1, vim.fn.filereadable(join(query, "codemodel-v2")))
      assert.equals(1, vim.fn.filereadable(join(query, "cmakeFiles-v1")))
    end)
  end)

  describe("file api replies", function()
    before_each(function()
      write_json(join(reply, "index.json"), {})
      write_json(
        join(reply, "cmakeFiles-v1-abc.json"),
        { inputs = { { path = "CMakeLists.txt" } } }
      )
      write_json(join(reply, "codemodel-v2-abc.json"), {
        configurations = {
          { name = "MinSizeRel", targets = { { name = "min_app", jsonFile = "target-min.json" } } },
          { name = "Release", targets = { { name = "rel_app", jsonFile = "target-rel.json" } } },
          { name = "Debug", targets = { { name = "app", jsonFile = "target-app.json" } } },
        },
      })
      write_json(join(reply, "target-app.json"), {
        name = "app",
        type = "EXECUTABLE",
        artifacts = { { path = "bin/app" } },
      })
    end)

    it("reports NOT_CONFIGURED without reply dir", function()
      vim.fn.delete(reply, "rf")
      assert.equals(Types.NOT_CONFIGURED, config:get_codemodel_targets().code)
      assert.equals(Types.NOT_CONFIGURED, config:get_cmake_files().code)
    end)

    it("reads cmake input files", function()
      local result = config:get_cmake_files()
      assert.equals(Types.SUCCESS, result.code)
      assert.same({ { path = "CMakeLists.txt" } }, result.data)
    end)

    it("picks the targets of the active build type", function()
      config.build_type = "Debug"
      local result = config:get_codemodel_targets()
      assert.equals(Types.SUCCESS, result.code)
      assert.equals("app", result.data[1].name)

      config.build_type = "Release"
      result = config:get_codemodel_targets()
      assert.equals(Types.SUCCESS, result.code)
      assert.equals(1, #result.data)
      assert.equals("rel_app", result.data[1].name)
    end)

    it("falls back to the first configuration", function()
      config.build_type = "Unknown"
      assert.equals("min_app", config:get_codemodel_targets().data[1].name)
    end)

    describe("get_launch_target", function()
      before_each(function()
        config.build_type = "Debug"
        config.launch_target = "app"
      end)

      it("reports a target that is not built yet", function()
        local result = config:get_launch_target()
        assert.equals(Types.SELECTED_LAUNCH_TARGET_NOT_BUILT, result.code)
      end)

      it("returns the artifact path relative to the build dir", function()
        vim.fn.mkdir(join(build, "bin"), "p")
        vim.fn.writefile({}, join(build, "bin", "app"))

        local result = config:get_launch_target()

        assert.equals(Types.SUCCESS, result.code)
        assert.equals(join(build, "bin", "app"), result.data)
        assert.equals("string", type(result.data))
      end)
    end)

    it("lists launch targets with absolute artifact and source paths", function()
      config.build_type = "Debug"
      write_json(join(reply, "target-app.json"), {
        name = "app",
        type = "EXECUTABLE",
        nameOnDisk = "app",
        paths = { build = "." },
        artifacts = { { path = "bin/app" } },
        sources = { { path = "src/main.cpp" }, { path = "/abs/generated.cpp" } },
      })

      local result = config:launch_targets_with_sources()

      assert.equals(Types.SUCCESS, result.code)
      assert.same({ "app" }, result.data.targets)
      assert.same({ join(build, "bin", "app") }, result.data.abs_paths)
      local sources = vim.tbl_map(function(source)
        return source.path
      end, result.data.sources)
      assert.same({ join(tmp, "src", "main.cpp"), "/abs/generated.cpp" }, sources)
    end)

    it("get_build_target returns the artifact path", function()
      config.build_type = "Debug"
      config.build_target = "app"
      vim.fn.mkdir(join(build, "bin"), "p")
      vim.fn.writefile({}, join(build, "bin", "app"))

      local result = config:get_build_target()

      assert.equals(Types.SUCCESS, result.code)
      assert.equals(join(build, "bin", "app"), result.data)
    end)
  end)

  describe("on windows", function()
    local osys = require("cmake-tools.osys")
    local orig

    before_each(function()
      orig = osys.iswin32
      osys.iswin32 = true
    end)

    after_each(function()
      osys.iswin32 = orig
    end)

    local function win_config(build_dir)
      local c = Config:new({
        cmake_build_directory = build_dir,
        cmake_generate_options = {},
        cmake_build_options = {},
        cmake_use_preset = false,
        cmake_show_disabled_build_presets = true,
        ctest_show_labels = false,
      })
      c.cwd = "C:\\proj"
      c:update_build_dir(build_dir, build_dir)
      return c
    end

    it("produces backslash-only paths for a relative build dir", function()
      local c = win_config("build")
      assert.equals("C:\\proj\\build", c:build_directory_path())
      assert.is_nil(c.query_directory:find("/", 1, true))
      assert.is_nil(c.reply_directory:find("/", 1, true))
      assert.equals("C:\\proj\\build\\.cmake\\api\\v1\\reply", c.reply_directory)
    end)

    it("keeps absolute build dirs absolute and normalizes slashes", function()
      local c = win_config("C:/other/build")
      assert.equals("C:\\other\\build", c:build_directory_path())
    end)

    it("produces backslash-only launch target paths", function()
      local c = win_config("build")
      local result = c:get_launch_target_from_info({ artifacts = { { path = "bin/app" } } })
      assert.is_nil(result.data:find("/", 1, true))
      assert.equals("C:\\proj\\build\\", result.data:sub(1, #"C:\\proj\\build\\"))
    end)
  end)
end)
