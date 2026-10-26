local Presets = require("cmake-tools.presets")
local Preset = require("cmake-tools.preset")

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

    it("returns only CMakePresets.json when it is the sole file", function()
      write_json(join(tmp, "CMakePresets.json"), { version = 3 })

      local first, second = Presets.find_preset_files(tmp)

      assert.equals(join(tmp, "CMakePresets.json"), first)
      assert.is_nil(second)
      assert.is_true(Presets.exists(tmp))
    end)

    it("finds the kebab-case preset files", function()
      write_json(join(tmp, "cmake-presets.json"), { version = 3 })
      write_json(join(tmp, "cmake-user-presets.json"), { version = 3 })

      local user, project = Presets.find_preset_files(tmp)

      assert.equals(join(tmp, "cmake-user-presets.json"), user)
      assert.equals(join(tmp, "cmake-presets.json"), project)
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

    it("expands ${fileDir} to the directory of the file defining the value", function()
      local sub = join(tmp, "sub")
      write_json(join(sub, "base.json"), {
        version = 4,
        configurePresets = {
          {
            name = "base",
            hidden = true,
            binaryDir = "${fileDir}/build",
            cacheVariables = { BASE_DIR = "${fileDir}" },
            environment = { BASE_DIR = "${fileDir}" },
          },
          { name = "included", cacheVariables = { DIR = "${fileDir}" } },
        },
      })
      write_json(join(tmp, "CMakePresets.json"), {
        version = 4,
        include = { "sub/base.json" },
        configurePresets = {
          { name = "dev", inherits = "base", cacheVariables = { DIR = "${fileDir}" } },
        },
      })

      local presets = Presets:parse(tmp)
      local dev = presets:get_configure_preset("dev")

      assert.equals(sub, presets:get_configure_preset("included").cacheVariables.DIR)
      assert.equals(tmp, dev.cacheVariables.DIR)
      assert.equals(sub, dev.cacheVariables.BASE_DIR)
      assert.equals(sub, dev.environment.BASE_DIR)
      assert.equals(join(sub, "build"), dev.binaryDirExpanded)
    end)

    it("parses a directory with only CMakePresets.json", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 3,
        configurePresets = { { name = "only", binaryDir = "build/only" } },
      })

      local presets = Presets:parse(tmp)

      assert.same({ "only" }, presets:get_configure_preset_names())
    end)

    it("parses kebab-case preset files and implicitly includes cmake-presets.json", function()
      write_json(join(tmp, "cmake-presets.json"), {
        version = 3,
        configurePresets = { { name = "project", binaryDir = "build/project" } },
      })
      write_json(join(tmp, "cmake-user-presets.json"), {
        version = 3,
        configurePresets = { { name = "user", inherits = "project" } },
      })

      local presets = Presets:parse(tmp)

      assert.same({ "project", "user" }, sorted(presets:get_configure_preset_names()))
      assert.equals("build/project", presets:get_configure_preset("user").binaryDir)
    end)

    it("terminates on include cycles and keeps presets from both files", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 4,
        include = { "other.json" },
        configurePresets = { { name = "a", binaryDir = "build/a" } },
      })
      write_json(join(tmp, "other.json"), {
        version = 4,
        include = { "CMakePresets.json" },
        configurePresets = { { name = "b", binaryDir = "build/b" } },
      })

      local names = Presets:parse(tmp):get_configure_preset_names()

      assert.same({ "a", "b" }, sorted(names))
    end)

    it("merges nested objects of the user and project presets", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 3,
        vendor = { project = { x = 1 }, shared = { from = "project", only_project = true } },
        configurePresets = { { name = "project" } },
      })
      -- An explicit include disables the implicit one, so CMakePresets.json is merged separately
      write_json(join(tmp, "extra.json"), { version = 3 })
      write_json(join(tmp, "CMakeUserPresets.json"), {
        version = 3,
        include = { "extra.json" },
        vendor = { user = { y = 2 }, shared = { from = "user" } },
        configurePresets = { { name = "user" } },
      })

      local presets = Presets:parse(tmp)

      assert.same({ "project", "user" }, sorted(presets:get_configure_preset_names()))
      assert.same({
        project = { x = 1 },
        user = { y = 2 },
        shared = { from = "user", only_project = true },
      }, presets.vendor)
    end)

    it("raises an error for invalid JSON", function()
      vim.fn.writefile({ "{ not json" }, join(tmp, "CMakePresets.json"))

      assert.has_error(function()
        Presets:parse(tmp)
      end)
    end)

    describe("with $penv in include paths", function()
      local saved

      before_each(function()
        saved = vim.env.CMT_TEST_INCLUDE_DIR
      end)

      after_each(function()
        vim.env.CMT_TEST_INCLUDE_DIR = saved
      end)

      it("expands $penv{VAR}", function()
        vim.env.CMT_TEST_INCLUDE_DIR = join(tmp, "env_inc")
        write_json(join(tmp, "env_inc", "extra.json"), {
          version = 4,
          configurePresets = { { name = "from_env", binaryDir = "build/env" } },
        })
        write_json(join(tmp, "CMakePresets.json"), {
          version = 4,
          include = { "$penv{CMT_TEST_INCLUDE_DIR}/extra.json" },
          configurePresets = { { name = "dev", binaryDir = "build/dev" } },
        })

        local names = Presets:parse(tmp):get_configure_preset_names()

        assert.same({ "dev", "from_env" }, sorted(names))
      end)
    end)

    it("does not leak an expanded inList condition between presets sharing it", function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 6,
        configurePresets = {
          {
            name = "base",
            hidden = true,
            condition = { type = "inList", string = "${presetName}", list = { "a" } },
          },
          { name = "a", inherits = "base", binaryDir = "build/a" },
          { name = "b", inherits = "base", binaryDir = "build/b" },
        },
      })

      local parsed = Presets:parse(tmp)

      assert.is_false(parsed:get_configure_preset("a", { include_disabled = true }).disabled)
      assert.is_true(parsed:get_configure_preset("b", { include_disabled = true }).disabled)
    end)

    it("resolves a child the same regardless of whether its parent comes first", function()
      local base = {
        name = "base",
        hidden = true,
        cacheVariables = { NAME = "${presetName}" },
        environment = { OUT = "$env{DIR}/out", DIR = "base" },
      }
      local child = { name = "child", inherits = "base", environment = { DIR = "child" } }

      for _, order in ipairs({ { base, child }, { child, base } }) do
        write_json(join(tmp, "CMakePresets.json"), { version = 3, configurePresets = order })

        local parsed = Presets:parse(tmp)
        local preset = parsed:get_configure_preset("child")

        assert.equals("child", preset.cacheVariables.NAME)
        assert.equals("child/out", preset.environment.OUT)

        local resolved_base = parsed:get_configure_preset("base", { include_hidden = true })
        assert.equals("base", resolved_base.cacheVariables.NAME)
        assert.equals("base/out", resolved_base.environment.OUT)
      end
    end)
  end)

  describe("preset lookup", function()
    local presets

    before_each(function()
      write_json(join(tmp, "CMakePresets.json"), {
        version = 6,
        configurePresets = {
          { name = "on", binaryDir = "build/on" },
          { name = "hid", hidden = true, binaryDir = "build/hid" },
          { name = "off", binaryDir = "build/off", condition = { type = "const", value = false } },
        },
        buildPresets = {
          { name = "b_on", configurePreset = "on" },
          { name = "b_off", configurePreset = "off" },
          { name = "b_hid", configurePreset = "hid" },
          { name = "b_missing", configurePreset = "nope" },
          { name = "b_none" },
          { name = "b_hidden", hidden = true },
        },
        testPresets = {
          { name = "t_on", configurePreset = "on" },
          { name = "t_hidden", hidden = true },
        },
      })
      presets = Presets:parse(tmp)
    end)

    it("hides hidden and disabled configure presets by default", function()
      assert.same({ "on" }, presets:get_configure_preset_names())
      assert.is_nil(presets:get_configure_preset("hid"))
      assert.is_nil(presets:get_configure_preset("off"))
      assert.equals("on", presets:get_configure_preset("on").name)
    end)

    it("includes hidden configure presets with include_hidden", function()
      assert.same(
        { "hid", "on" },
        sorted(presets:get_configure_preset_names({ include_hidden = true }))
      )
      assert.equals("hid", presets:get_configure_preset("hid", { include_hidden = true }).name)
      assert.is_nil(presets:get_configure_preset("off", { include_hidden = true }))
    end)

    it("includes disabled configure presets with include_disabled", function()
      assert.same(
        { "off", "on" },
        sorted(presets:get_configure_preset_names({ include_disabled = true }))
      )
      assert.is_true(presets:get_configure_preset("off", { include_disabled = true }).disabled)
      assert.is_nil(presets:get_configure_preset("hid", { include_disabled = true }))
    end)

    it("includes everything with include_hidden and include_disabled", function()
      local names =
        presets:get_configure_preset_names({ include_hidden = true, include_disabled = true })

      assert.same({ "hid", "off", "on" }, sorted(names))
    end)

    it("appends a None entry to buildPresets and testPresets", function()
      local build_none = presets:get_build_preset("None")
      local test_none = presets:get_test_preset("None")

      assert.equals("None", presets.buildPresets[#presets.buildPresets].name)
      assert.equals("None", presets.testPresets[#presets.testPresets].name)
      assert.is_false(build_none.valid)
      assert.is_false(test_none.valid)
    end)

    it("lists test preset names without hidden ones", function()
      assert.same({ "None", "t_on" }, sorted(presets:get_test_preset_names()))
      assert.same(
        { "None", "t_hidden", "t_on" },
        sorted(presets:get_test_preset_names({ include_hidden = true }))
      )
    end)

    it("gets a test preset by name", function()
      local preset = presets:get_test_preset("t_on")

      assert.equals("on", preset.configurePreset)
      assert.is_true(preset:isValid())
      assert.equals(tmp, preset.cwd)
      assert.is_nil(presets:get_test_preset("t_hidden"))
      assert.equals("t_hidden", presets:get_test_preset("t_hidden", { include_hidden = true }).name)
      assert.is_nil(presets:get_test_preset("missing"))
    end)

    it("hides build presets whose configure preset is disabled", function()
      local names = sorted(presets:get_build_preset_names({}))

      assert.is_false(vim.tbl_contains(names, "b_off"))
    end)

    it("shows build presets of disabled configure presets with include_disabled", function()
      local names = presets:get_build_preset_names({ include_disabled = true })

      assert.is_true(vim.tbl_contains(names, "b_off"))
    end)

    it("keeps build presets without a configure preset", function()
      local names = presets:get_build_preset_names({})

      assert.is_true(vim.tbl_contains(names, "b_none"))
      assert.is_true(vim.tbl_contains(names, "None"))
    end)

    it("keeps build presets whose configure preset is hidden", function()
      local names = presets:get_build_preset_names({})

      assert.is_true(vim.tbl_contains(names, "b_hid"))
    end)

    it("drops build presets whose configure preset does not exist", function()
      assert.is_false(vim.tbl_contains(presets:get_build_preset_names({}), "b_missing"))
      assert.is_false(
        vim.tbl_contains(presets:get_build_preset_names({ include_disabled = true }), "b_missing")
      )
    end)

    it("hides hidden build presets unless include_hidden", function()
      assert.is_false(vim.tbl_contains(presets:get_build_preset_names({}), "b_hidden"))
      assert.is_true(
        vim.tbl_contains(presets:get_build_preset_names({ include_hidden = true }), "b_hidden")
      )
    end)
  end)
end)

describe("ConfigurePreset", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  local function new_preset(obj, parents)
    parents = parents or {}
    return Preset:new(tmp, obj, function(name)
      return parents[name]
    end)
  end

  local function is_disabled(condition, extra)
    local obj = vim.tbl_extend("force", { name = "p", condition = condition }, extra or {})
    return new_preset(obj).disabled
  end

  describe("conditions", function()
    it("is enabled without a condition", function()
      assert.is_false(new_preset({ name = "p" }).disabled)
    end)

    it("handles const", function()
      assert.is_false(is_disabled({ type = "const", value = true }))
      assert.is_true(is_disabled({ type = "const", value = false }))
    end)

    it("handles equals", function()
      assert.is_false(is_disabled({ type = "equals", lhs = "a", rhs = "a" }))
      assert.is_true(is_disabled({ type = "equals", lhs = "a", rhs = "b" }))
    end)

    it("handles notEquals", function()
      assert.is_false(is_disabled({ type = "notEquals", lhs = "a", rhs = "b" }))
      assert.is_true(is_disabled({ type = "notEquals", lhs = "a", rhs = "a" }))
    end)

    it("handles inList", function()
      assert.is_false(is_disabled({ type = "inList", string = "a", list = { "x", "a" } }))
      assert.is_true(is_disabled({ type = "inList", string = "c", list = { "x", "a" } }))
    end)

    it("handles notInList", function()
      assert.is_false(is_disabled({ type = "notInList", string = "c", list = { "x", "a" } }))
      assert.is_true(is_disabled({ type = "notInList", string = "a", list = { "x", "a" } }))
    end)

    it("handles anyOf with one true condition", function()
      local cond = {
        type = "anyOf",
        conditions = { { type = "const", value = false }, { type = "const", value = true } },
      }

      assert.is_false(is_disabled(cond))
    end)

    it("disables the preset when every anyOf condition is false", function()
      local cond = {
        type = "anyOf",
        conditions = { { type = "const", value = false }, { type = "const", value = false } },
      }

      assert.is_true(is_disabled(cond))
    end)

    it("handles allOf", function()
      local all_true = {
        type = "allOf",
        conditions = { { type = "const", value = true }, { type = "const", value = true } },
      }
      local one_false = {
        type = "allOf",
        conditions = { { type = "const", value = true }, { type = "const", value = false } },
      }

      assert.is_false(is_disabled(all_true))
      assert.is_true(is_disabled(one_false))
    end)

    it("handles not", function()
      assert.is_true(is_disabled({ type = "not", condition = { type = "const", value = true } }))
      assert.is_false(is_disabled({ type = "not", condition = { type = "const", value = false } }))
    end)

    it("handles nested conditions", function()
      local cond = {
        type = "allOf",
        conditions = {
          { type = "not", condition = { type = "const", value = false } },
          { type = "equals", lhs = "a", rhs = "a" },
        },
      }

      assert.is_false(is_disabled(cond))
    end)

    it("expands macros inside conditions", function()
      assert.is_false(is_disabled({ type = "equals", lhs = "${presetName}", rhs = "p" }))
      assert.is_true(is_disabled({ type = "equals", lhs = "${presetName}", rhs = "other" }))
      assert.is_false(is_disabled({ type = "inList", string = "${presetName}", list = { "p" } }))
    end)

    it("expands environment variables inside conditions", function()
      local cond = { type = "equals", lhs = "$env{MODE}", rhs = "fast" }

      assert.is_false(is_disabled(cond, { environment = { MODE = "fast" } }))
      assert.is_true(is_disabled(cond, { environment = { MODE = "slow" } }))
    end)

    it("inherits the condition from a parent", function()
      local parents = {
        base = { name = "base", hidden = true, condition = { type = "const", value = false } },
      }

      assert.is_true(new_preset({ name = "child", inherits = "base" }, parents).disabled)
    end)

    it("prefers the condition of the child over the parent", function()
      local parents = {
        base = { name = "base", hidden = true, condition = { type = "const", value = false } },
      }
      local child = {
        name = "child",
        inherits = "base",
        condition = { type = "const", value = true },
      }

      assert.is_false(new_preset(child, parents).disabled)
    end)

    it("raises an error for a const condition with a non-boolean value", function()
      assert.has_error(function()
        new_preset({ name = "p", condition = { type = "const", value = "yes" } })
      end)
    end)

    it("raises an error for a condition without a type", function()
      assert.has_error(function()
        new_preset({ name = "p", condition = { value = true } })
      end)
    end)

    it("raises an error for equals without rhs", function()
      assert.has_error(function()
        new_preset({ name = "p", condition = { type = "equals", lhs = "a" } })
      end)
    end)

    it("raises an error for anyOf without a conditions array", function()
      assert.has_error(function()
        new_preset({ name = "p", condition = { type = "anyOf", conditions = "x" } })
      end)
    end)
  end)

  describe("environment", function()
    local saved

    before_each(function()
      saved = { vim.env.CMT_TEST_VAR, vim.env.CMT_TEST_OTHER }
    end)

    after_each(function()
      vim.env.CMT_TEST_VAR = saved[1]
      vim.env.CMT_TEST_OTHER = saved[2]
    end)

    it("inherits the environment from a parent", function()
      local parents = { base = { name = "base", environment = { A = "1" } } }

      local preset = new_preset({ name = "child", inherits = "base" }, parents)

      assert.equals("1", preset.environment.A)
    end)

    it("lets the child override the parent", function()
      local parents = { base = { name = "base", environment = { A = "1", B = "2" } } }

      local preset =
        new_preset({ name = "child", inherits = "base", environment = { A = "x" } }, parents)

      assert.equals("x", preset.environment.A)
      assert.equals("2", preset.environment.B)
    end)

    it("resolves $env{X} referencing another environment entry", function()
      local preset = new_preset({ name = "p", environment = { A = "1", B = "$env{A}/x" } })

      assert.equals("1/x", preset.environment.B)
    end)

    it("resolves a chain of $env references", function()
      local preset = new_preset({
        name = "p",
        environment = { A = "1", B = "$env{A}b", C = "$env{B}c" },
      })

      assert.equals("1bc", preset.environment.C)
    end)

    it("resolves $env references to a parent entry", function()
      local parents = { base = { name = "base", environment = { A = "1" } } }

      local preset =
        new_preset({ name = "child", inherits = "base", environment = { B = "$env{A}!" } }, parents)

      assert.equals("1!", preset.environment.B)
    end)

    it("resolves $penv{X} from the process environment", function()
      vim.env.CMT_TEST_VAR = "from_process"

      local preset = new_preset({ name = "p", environment = { A = "$penv{CMT_TEST_VAR}/x" } })

      assert.equals("from_process/x", preset.environment.A)
    end)

    it("falls back to the process environment for unknown $env{X}", function()
      vim.env.CMT_TEST_OTHER = "fallback"

      local preset = new_preset({ name = "p", environment = { A = "$env{CMT_TEST_OTHER}" } })

      assert.equals("fallback", preset.environment.A)
    end)

    it("resolves unknown variables to an empty string", function()
      vim.env.CMT_TEST_OTHER = nil

      local preset = new_preset({ name = "p", environment = { A = "[$env{CMT_TEST_OTHER}]" } })

      assert.equals("[]", preset.environment.A)
    end)

    it("raises an error for circular references", function()
      assert.has_error(function()
        new_preset({ name = "p", environment = { A = "$env{B}", B = "$env{A}" } })
      end)
    end)

    it("raises an error for a self reference", function()
      assert.has_error(function()
        new_preset({ name = "p", environment = { A = "$env{A}" } })
      end)
    end)
  end)

  describe("inheritance", function()
    it("supports multiple parents where the first parent wins", function()
      local parents = {
        one = {
          name = "one",
          binaryDir = "build/one",
          cacheVariables = { X = "one", ONLY_ONE = "1" },
          environment = { E = "one" },
        },
        two = {
          name = "two",
          binaryDir = "build/two",
          cacheVariables = { X = "two", ONLY_TWO = "2" },
          environment = { E = "two", ONLY_TWO = "2" },
        },
      }

      local preset = new_preset({ name = "child", inherits = { "one", "two" } }, parents)

      assert.equals("one", preset.cacheVariables.X)
      assert.equals("1", preset.cacheVariables.ONLY_ONE)
      assert.equals("2", preset.cacheVariables.ONLY_TWO)
      assert.equals("one", preset.environment.E)
      assert.equals("2", preset.environment.ONLY_TWO)
      assert.equals("build/one", preset.binaryDir)
    end)

    it("inherits through a multi-level chain", function()
      local parents = {
        parent = {
          name = "parent",
          inherits = "grand",
          cacheVariables = { P = "parent" },
          environment = { P = "parent" },
        },
        grand = {
          name = "grand",
          binaryDir = "build/grand",
          cacheVariables = { G = "grand", P = "grand" },
          environment = { G = "grand", P = "grand" },
        },
      }

      local preset = new_preset({ name = "child", inherits = "parent" }, parents)

      assert.equals("grand", preset.cacheVariables.G)
      assert.equals("parent", preset.cacheVariables.P)
      assert.equals("grand", preset.environment.G)
      assert.equals("parent", preset.environment.P)
      assert.equals("build/grand", preset.binaryDir)
    end)

    it("prefers the binaryDir of the nearest ancestor", function()
      local parents = {
        parent = { name = "parent", inherits = "grand", binaryDir = "build/parent" },
        grand = { name = "grand", binaryDir = "build/grand" },
      }

      local preset = new_preset({ name = "child", inherits = "parent" }, parents)

      assert.equals("build/parent", preset.binaryDir)
    end)

    it("ignores unknown parents", function()
      local preset = new_preset({ name = "child", inherits = "missing", binaryDir = "b" })

      assert.equals("b", preset.binaryDir)
    end)

    it("inherits the generator from a parent", function()
      local parents = { base = { name = "base", generator = "Ninja Multi-Config" } }

      local preset = new_preset({ name = "child", inherits = "base" }, parents)

      assert.equals("Ninja Multi-Config", preset.generator)
    end)

    it("inherits other scalar fields such as toolchainFile", function()
      local parents = {
        one = { name = "one", toolchainFile = "one.cmake", installDir = "/one" },
        two = { name = "two", toolchainFile = "two.cmake", toolset = "ts" },
      }

      local preset =
        new_preset({ name = "child", inherits = { "one", "two" }, installDir = "/own" }, parents)

      assert.equals("one.cmake", preset.toolchainFile)
      assert.equals("/own", preset.installDir)
      assert.equals("ts", preset.toolset)
    end)

    it("does not inherit name, hidden or displayName", function()
      local parents = { base = { name = "base", hidden = true, displayName = "Base" } }

      local preset = new_preset({ name = "child", inherits = "base" }, parents)

      assert.equals("child", preset.name)
      assert.is_nil(preset.hidden)
      assert.is_nil(preset.displayName)
    end)

    it("inherits the generator through a multi-level chain", function()
      local parents = {
        parent = { name = "parent", inherits = "grand" },
        grand = { name = "grand", generator = "Ninja" },
      }

      local preset = new_preset({ name = "child", inherits = "parent" }, parents)

      assert.equals("Ninja", preset.generator)
    end)

    it("does not modify or share tables with its parents", function()
      local parents = {
        parent = { name = "parent", inherits = "grand", environment = { P = "p" } },
        grand = {
          name = "grand",
          architecture = { value = "x64" },
          cacheVariables = { G = "g" },
          condition = { type = "const", value = true },
        },
      }
      local snapshot = vim.deepcopy(parents)

      local preset = new_preset({ name = "child", inherits = "parent" }, parents)

      assert.same(snapshot, parents)
      assert.is_nil(getmetatable(parents.parent))
      assert.same({ value = "x64" }, preset.architecture)
      assert.are_not.equal(parents.grand.architecture, preset.architecture)
      assert.are_not.equal(parents.grand.condition, preset.condition)
    end)

    it("inherits a shared ancestor of multiple parents", function()
      local parents = {
        one = { name = "one", inherits = "grand" },
        two = { name = "two", inherits = "grand", cacheVariables = { T = "two" } },
        grand = { name = "grand", cacheVariables = { G = "g" } },
      }

      local preset = new_preset({ name = "child", inherits = { "one", "two" } }, parents)

      assert.same({ G = "g", T = "two" }, preset.cacheVariables)
    end)

    it("stops at inheritance cycles", function()
      local parents = {
        a = { name = "a", inherits = "b", generator = "Ninja" },
        b = { name = "b", inherits = { "a", "child" } },
      }

      local preset = new_preset({ name = "child", inherits = "a" }, parents)

      assert.equals("Ninja", preset.generator)
    end)
  end)

  describe("macros", function()
    local saved

    before_each(function()
      saved = vim.env.CMT_TEST_VAR
    end)

    after_each(function()
      vim.env.CMT_TEST_VAR = saved
    end)

    local function expand(value, extra)
      local obj =
        vim.tbl_extend("force", { name = "dev", cacheVariables = { V = value } }, extra or {})
      return new_preset(obj).cacheVariables.V
    end

    it("expands ${sourceDir}", function()
      assert.equals("./build", expand("${sourceDir}/build"))
    end)

    it("expands ${sourceDirName}", function()
      assert.equals("x-" .. vim.fn.fnamemodify(tmp, ":t"), expand("x-${sourceDirName}"))
    end)

    it("expands ${presetName}", function()
      assert.equals("build/dev", expand("build/${presetName}"))
    end)

    it("expands ${generator}", function()
      assert.equals("gen=Ninja", expand("gen=${generator}", { generator = "Ninja" }))
    end)

    it("expands ${hostSystemName}", function()
      local expected = vim.fn.has("win32") == 1 and "Windows" or vim.uv.os_uname().sysname

      assert.equals(expected, expand("${hostSystemName}"))
    end)

    it("expands ${dollar}", function()
      assert.equals("$x", expand("${dollar}x"))
    end)

    it("expands ${pathListSep} to the platform separator", function()
      local expected = vim.fn.has("win32") == 1 and ";" or ":"

      assert.equals("a" .. expected .. "b", expand("a${pathListSep}b"))
    end)

    it("expands $env{} in cacheVariables from the preset environment", function()
      assert.equals("/r/x", expand("$env{ROOT}/x", { environment = { ROOT = "/r" } }))
    end)

    it("expands $env{} in binaryDir", function()
      local preset = new_preset({
        name = "dev",
        binaryDir = "$env{ROOT}/build/${presetName}",
        environment = { ROOT = "/r" },
      })

      assert.equals("/r/build/dev", preset.binaryDirExpanded)
    end)

    it("expands $penv{} in binaryDir", function()
      vim.env.CMT_TEST_VAR = "/proc_root"

      local preset = new_preset({ name = "dev", binaryDir = "$penv{CMT_TEST_VAR}/build" })

      assert.equals("/proc_root/build", preset.binaryDirExpanded)
    end)

    it("expands macros in binaryDir", function()
      local preset = new_preset({ name = "dev", binaryDir = "${sourceDir}/build/${presetName}" })

      assert.equals("./build/dev", preset.binaryDirExpanded)
    end)

    it("leaves binaryDirExpanded unset without a binaryDir", function()
      assert.is_nil(new_preset({ name = "dev" }).binaryDirExpanded)
    end)

    it("expands the value of object-form cacheVariables", function()
      local preset = new_preset({
        name = "dev",
        cacheVariables = {
          A = { type = "STRING", value = "name-${presetName}" },
          B = { type = "PATH", value = "${sourceDir}/out" },
          C = { type = "BOOL", value = true },
        },
      })

      assert.equals("name-dev", preset.cacheVariables.A)
      assert.equals("./out", preset.cacheVariables.B)
      assert.is_true(preset.cacheVariables.C)
    end)

    it("expands macros in inherited cacheVariables with the child's name", function()
      local parents = {
        base = { name = "base", cacheVariables = { N = "${presetName}" } },
      }

      local preset = new_preset({ name = "child", inherits = "base" }, parents)

      assert.equals("child", preset.cacheVariables.N)
    end)
  end)

  describe("build type", function()
    it("defaults to Debug", function()
      assert.equals("Debug", new_preset({ name = "p" }):get_build_type())
    end)

    it("reads CMAKE_BUILD_TYPE", function()
      local preset = new_preset({ name = "p", cacheVariables = { CMAKE_BUILD_TYPE = "Release" } })

      assert.equals("Release", preset:get_build_type())
    end)

    it("reads CMAKE_BUILD_TYPE from the object form", function()
      local preset = new_preset({
        name = "p",
        cacheVariables = { CMAKE_BUILD_TYPE = { type = "STRING", value = "MinSizeRel" } },
      })

      assert.equals("MinSizeRel", preset:get_build_type())
    end)
  end)

  describe("get_build_configuration_types", function()
    it("returns nil for a single-config generator", function()
      local preset = new_preset({
        name = "p",
        generator = "Ninja",
        cacheVariables = { CMAKE_CONFIGURATION_TYPES = "Debug;Release" },
      })

      assert.is_nil(preset:get_build_configuration_types())
    end)

    it("returns nil without a generator", function()
      local preset = new_preset({
        name = "p",
        cacheVariables = { CMAKE_CONFIGURATION_TYPES = "Debug;Release" },
      })

      assert.is_nil(preset:get_build_configuration_types())
    end)

    it("splits the list for Ninja Multi-Config", function()
      local preset = new_preset({
        name = "p",
        generator = "Ninja Multi-Config",
        cacheVariables = { CMAKE_CONFIGURATION_TYPES = "Debug;Release;RelWithDebInfo" },
      })

      assert.same({ "Debug", "Release", "RelWithDebInfo" }, preset:get_build_configuration_types())
    end)

    it("returns nil when CMAKE_CONFIGURATION_TYPES is missing", function()
      local preset = new_preset({ name = "p", generator = "Ninja Multi-Config" })

      assert.is_nil(preset:get_build_configuration_types())
    end)
  end)
end)
