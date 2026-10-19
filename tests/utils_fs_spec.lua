local utils = require("cmake-tools.utils")
local Types = require("cmake-tools.types")

local join = vim.fs.joinpath

describe("utils fs helpers", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp, "rf")
  end)

  describe("mkdir", function()
    it("creates nested directories", function()
      local dir = join(tmp, "a", "b", "c")
      assert.is_true(utils.mkdir(dir))
      assert.is_true(utils.is_dir(dir))
    end)

    it("succeeds when the directory already exists", function()
      assert.is_true(utils.mkdir(tmp))
    end)

    it("returns false when the path is an existing file", function()
      local file = join(tmp, "f.txt")
      assert.is_true(utils.touch(file))
      local result
      assert.has_no.errors(function()
        result = utils.mkdir(file)
      end)
      assert.is_false(result)
    end)

    it("returns false when a parent is a file", function()
      local file = join(tmp, "f.txt")
      assert.is_true(utils.touch(file))
      local result
      assert.has_no.errors(function()
        result = utils.mkdir(join(file, "sub"))
      end)
      assert.is_false(result)
    end)
  end)

  describe("is_file / is_dir / file_exists", function()
    it("distinguishes files from directories", function()
      local file = join(tmp, "f.txt")
      assert.is_true(utils.touch(file))

      assert.is_true(utils.is_file(file))
      assert.is_false(utils.is_dir(file))
      assert.is_true(utils.is_dir(tmp))
      assert.is_false(utils.is_file(tmp))
      assert.is_true(utils.file_exists(file))
      assert.is_true(utils.file_exists(tmp))
    end)

    it("returns false for missing paths", function()
      local missing = join(tmp, "missing")
      assert.is_false(utils.is_file(missing))
      assert.is_false(utils.is_dir(missing))
      assert.is_false(utils.file_exists(missing))
    end)
  end)

  describe("touch", function()
    it("does not truncate an existing file", function()
      local file = join(tmp, "f.txt")
      vim.fn.writefile({ "keep" }, file)
      assert.is_true(utils.touch(file))
      assert.same({ "keep" }, vim.fn.readfile(file))
    end)

    it("returns false when the parent directory is missing", function()
      assert.is_false(utils.touch(join(tmp, "nope", "f.txt")))
    end)
  end)

  describe("read_file", function()
    it("returns the whole content", function()
      local file = join(tmp, "f.txt")
      vim.fn.writefile({ "a", "b" }, file)
      assert.equals("a\nb\n", utils.read_file(file))
    end)

    it("returns nil for missing files", function()
      assert.is_nil(utils.read_file(join(tmp, "missing")))
    end)
  end)

  describe("read_json", function()
    it("decodes the file", function()
      local file = join(tmp, "f.json")
      vim.fn.writefile({ '{"a": 1}' }, file)
      assert.same({ a = 1 }, utils.read_json(file))
    end)

    it("names the file when it cannot be read", function()
      local file = join(tmp, "missing.json")
      local ok, err = pcall(utils.read_json, file)
      assert.is_false(ok)
      assert.truthy(err:find(file, 1, true))
    end)

    it("names the file when it cannot be parsed", function()
      local file = join(tmp, "bad.json")
      vim.fn.writefile({ "{" }, file)
      local ok, err = pcall(utils.read_json, file)
      assert.is_false(ok)
      assert.truthy(err:find(file, 1, true))
    end)
  end)

  describe("rmfile", function()
    it("removes an existing file", function()
      local file = join(tmp, "f.txt")
      utils.touch(file)
      utils.rmfile(file)
      assert.is_false(utils.file_exists(file))
    end)

    it("ignores missing files", function()
      assert.has_no.errors(function()
        utils.rmfile(join(tmp, "missing"))
      end)
    end)
  end)

  describe("abspath", function()
    it("keeps absolute paths and strips the trailing separator of directories", function()
      assert.equals(vim.fn.resolve(tmp), vim.fn.resolve(utils.abspath(tmp .. "/")))
      assert.is_nil(utils.abspath(tmp):match("/$"))
    end)

    it("makes relative paths absolute", function()
      local abs = utils.abspath("some/relative/dir")
      assert.equals(1, vim.fn.isabsolutepath(abs))
      assert.truthy(abs:match("some/relative/dir$"))
    end)

    it("keeps the filesystem root", function()
      assert.equals("/", utils.abspath("/"))
    end)

    it("resolves relative paths against the given base and collapses '..'", function()
      assert.equals("/src/build/x", utils.abspath("../build/./x/", "/src/proj"))
    end)

    it("expands a leading '~'", function()
      assert.equals(utils.join(vim.uv.os_homedir(), "build"), utils.abspath("~/build", "/src"))
    end)

    it("keeps macros untouched", function()
      assert.equals(
        "/src/out/${variant:buildType}",
        utils.abspath("out/${variant:buildType}", "/src")
      )
    end)
  end)

  describe("join", function()
    it("normalizes the joined path", function()
      assert.equals("/a/c/d", utils.join("/a/b/", "../c", "", "./d/"))
    end)

    it("keeps relative paths relative", function()
      assert.equals("a/b", utils.join("a", "b"))
    end)
  end)

  describe("is_absolute", function()
    it("does not treat '~' or relative paths as absolute", function()
      assert.is_true(utils.is_absolute("/a"))
      assert.is_false(utils.is_absolute("~/a"))
      assert.is_false(utils.is_absolute("a/b"))
    end)
  end)

  describe("on Windows", function()
    local osys = require("cmake-tools.osys")

    before_each(function()
      osys.iswin32 = true
    end)

    after_each(function()
      osys.iswin32 = vim.fn.has("win32") == 1
    end)

    it("uses backslashes and collapses '..'", function()
      assert.equals("C:\\proj\\out\\Debug", utils.join("c:/proj/src", "..\\out", "Debug/"))
    end)

    it("keeps the drive root", function()
      assert.equals("C:\\", utils.normalize("C:/"))
    end)

    it("keeps UNC paths", function()
      assert.equals("\\\\srv\\share\\build", utils.join("\\\\srv\\share", "build"))
    end)

    it("detects drive letter and UNC paths as absolute", function()
      assert.is_true(utils.is_absolute("C:\\proj"))
      assert.is_true(utils.is_absolute("c:/proj"))
      assert.is_true(utils.is_absolute("\\\\srv\\share"))
      assert.is_false(utils.is_absolute("proj\\build"))
      assert.is_false(utils.is_absolute("~\\proj"))
    end)

    it("resolves relative paths against a drive base", function()
      assert.equals("C:\\proj\\out\\Debug", utils.abspath("out/Debug", "C:\\proj"))
      assert.equals("D:\\other", utils.abspath("D:/other", "C:\\proj"))
    end)
  end)

  describe("get_cmake_configuration", function()
    it("finds CMakeLists.txt in cwd", function()
      utils.touch(join(tmp, "CMakeLists.txt"))
      local result = utils.get_cmake_configuration(tmp)
      assert.equals(Types.SUCCESS, result.code)
      assert.equals(join(tmp, "CMakeLists.txt"), result.data)
    end)

    it("fails without CMakeLists.txt", function()
      local result = utils.get_cmake_configuration(tmp)
      assert.equals(Types.CANNOT_FIND_CMAKE_CONFIGURATION_FILE, result.code)
    end)
  end)
end)
