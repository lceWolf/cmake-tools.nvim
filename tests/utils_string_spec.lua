local utils = require("cmake-tools.utils")

describe("utils.split_string_by_delimiter", function()
  it("keeps the trailing element", function()
    assert.same({ "a", "b", "c" }, utils.split_string_by_delimiter("a;b;c", ";"))
  end)

  it("ignores a trailing delimiter", function()
    assert.same({ "Debug", "Release" }, utils.split_string_by_delimiter("Debug;Release;", ";"))
  end)

  it("defaults to the ; delimiter", function()
    assert.same({ "a", "b" }, utils.split_string_by_delimiter("a;b"))
  end)

  it("returns a single element without a delimiter", function()
    assert.same({ "a" }, utils.split_string_by_delimiter("a", ";"))
  end)

  it("returns nil for an empty string", function()
    assert.is_nil(utils.split_string_by_delimiter("", ";"))
  end)

  it("returns the requested item", function()
    assert.equals("b", utils.split_string_by_delimiter("a;b;c", ";", 2))
    assert.is_nil(utils.split_string_by_delimiter("a;b", ";", 5))
  end)
end)
