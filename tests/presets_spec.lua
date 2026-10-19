local Presets = require("cmake-tools.presets")

local join = vim.fs.joinpath

local function write_json(path, data)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(data) }, path)
end

local function sorted(list)
  table.sort(list)
  return list
end

describe("Presets", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("find_preset_files", function()
    it("returns nothing for a directory without presets", function()
      assert.is_nil(Presets.find_preset_files(tmp))
      assert.is_false(Presets.exists(tmp))
    end)

    it("returns the user preset file before the project preset file", function()
      write_json(join(tmp, "CMakePresets.json"), { version = 3 })
      write_json(join(tmp, "CMakeUserPresets.json"), { version = 3 })

      local user, project = Presets.find_preset_files(tmp)

      assert.equals(join(tmp, "CMakeUserPresets.json"), user)
      assert.equals(join(tmp, "CMakePresets.json"), project)
      assert.is_true(Presets.exists(tmp))
    end)
  end)

  describe("parse", function()
    it("resolves relative, absolute and missing includes", function()
      local abs_include = join(tmp, "abs", "abs.json")
      write_json(join(tmp, "common", "base.json"), {
        version = 3,
        configurePresets = {
          { name = "base", hidden = true, cacheVariables = { FROM_BASE = "yes" } },
        },
      })
      write_json(abs_include, {
        version = 3,
        configurePresets = { { name = "from_abs", binaryDir = "build/abs" } },
      })
      write_json(join(tmp, "CMakePresets.json"), {
        version = 4,
        include = { "common/base.json", abs_include, "does/not/exist.json" },
        configurePresets = { { name = "dev", inherits = "base", binaryDir = "build/dev" } },
      })

      local presets = Presets:parse(tmp)

      assert.same({ "dev", "from_abs" }, sorted(presets:get_configure_preset_names()))
      assert.equals("yes", presets:get_configure_preset("dev").cacheVariables.FROM_BASE)
    end)

    it("implicitly includes CMakePresets.json from CMakeUserPresets.json", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 3,
        configurePresets = { { name = "project", binaryDir = "build/project" } },
      })
      write_json(join(tmp, "CMakeUserPresets.json"), {
        version = 3,
        configurePresets = { { name = "user", inherits = "project" } },
      })

      local presets = Presets:parse(tmp)

      assert.same({ "project", "user" }, sorted(presets:get_configure_preset_names()))
      assert.equals("build/project", presets:get_configure_preset("user").binaryDir)
    end)

    it("expands ${sourceParentDir} and ${fileDir} in the root preset file", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 3,
        configurePresets = {
          {
            name = "dev",
            binaryDir = "${sourceParentDir}/out",
            cacheVariables = { DIR = "${fileDir}" },
          },
        },
      })

      local preset = Presets:parse(tmp):get_configure_preset("dev")

      assert.equals(vim.fs.dirname(tmp) .. "/out", preset.binaryDirExpanded)
      assert.equals(tmp, preset.cacheVariables.DIR)
    end)

    pending("expands ${fileDir} to the directory of an included preset file")
  end)
end)
