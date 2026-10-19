local BuildPreset = require("cmake-tools.build_preset")

describe("BuildPreset", function()
  describe("new", function()
    it("sets defaults", function()
      local preset = BuildPreset:new("/work", { name = "b" })

      assert.is_true(preset.valid)
      assert.same({}, preset.environment)
      assert.equals("/work", preset.cwd)
      assert.equals("b", preset.name)
    end)

    it("preserves valid = false", function()
      local preset = BuildPreset:new("/work", { name = "None", valid = false })

      assert.is_false(preset.valid)
      assert.is_false(preset:is_valid())
    end)

    it("keeps an existing environment", function()
      local preset = BuildPreset:new("/work", { name = "b", environment = { A = "1" } })

      assert.same({ A = "1" }, preset.environment)
    end)

    it("works without an object", function()
      local preset = BuildPreset:new("/work")

      assert.is_true(preset.valid)
      assert.equals("/work", preset.cwd)
    end)
  end)

  describe("is_valid", function()
    it("is true by default", function()
      assert.is_true(BuildPreset:new("/work", { name = "b" }):is_valid())
    end)
  end)

  describe("get_build_target", function()
    it("wraps a string target in a list", function()
      local preset = BuildPreset:new("/work", { name = "b", targets = "app" })

      assert.same({ "app" }, preset:get_build_target())
    end)

    it("returns a table of targets unchanged", function()
      local preset = BuildPreset:new("/work", { name = "b", targets = { "app", "lib" } })

      assert.same({ "app", "lib" }, preset:get_build_target())
    end)

    it("returns nil without targets", function()
      assert.is_nil(BuildPreset:new("/work", { name = "b" }):get_build_target())
    end)
  end)

  describe("get_build_type", function()
    it("returns the configuration", function()
      local preset = BuildPreset:new("/work", { name = "b", configuration = "Release" })

      assert.equals("Release", preset:get_build_type())
    end)

    it("returns nil without a configuration", function()
      assert.is_nil(BuildPreset:new("/work", { name = "b" }):get_build_type())
    end)
  end)
end)
