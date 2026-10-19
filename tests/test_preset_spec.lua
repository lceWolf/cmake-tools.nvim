local TestPreset = require("cmake-tools.test_preset")

describe("TestPreset", function()
  describe("new", function()
    it("sets defaults", function()
      local preset = TestPreset.new("/work", { name = "t" })

      assert.is_true(preset.valid)
      assert.equals("/work", preset.cwd)
      assert.equals("t", preset.name)
    end)

    it("preserves valid = false", function()
      local preset = TestPreset.new("/work", { name = "None", valid = false })

      assert.is_false(preset.valid)
      assert.is_false(preset:isValid())
    end)

    it("works without an object", function()
      local preset = TestPreset.new("/work")

      assert.is_true(preset.valid)
      assert.equals("/work", preset.cwd)
    end)
  end)

  describe("isValid", function()
    it("is true by default", function()
      assert.is_true(TestPreset.new("/work", { name = "t" }):isValid())
    end)
  end)
end)
