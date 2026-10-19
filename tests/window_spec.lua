local window = require("cmake-tools.window")

describe("settings window", function()
  after_each(function()
    if window.is_open() then
      window.close_menu()
    end
    window.title = ""
    window.content = nil
    window.on_save = nil
    window.on_exit = nil
  end)

  it("opens a centered floating window with the content", function()
    window.title = "CMake Settings"
    window.set_content("local a = 1\nreturn a")

    window.toggle_window()

    assert.is_true(window.is_open())
    local cfg = vim.api.nvim_win_get_config(window.win_id)
    local width = math.min(80, vim.o.columns)
    local height = math.min(20, vim.o.lines)
    assert.equals("editor", cfg.relative)
    assert.equals(width, cfg.width)
    assert.equals(height, cfg.height)
    assert.equals(math.floor((vim.o.columns - width) / 2), cfg.col)
    assert.equals(math.max(0, math.floor((vim.o.lines - height) / 2 - 1)), cfg.row)
    assert.is_not_nil(cfg.title)
    assert.same(
      { "local a = 1", "return a" },
      vim.api.nvim_buf_get_lines(window.bufh, 0, -1, false)
    )
    assert.equals("lua", vim.bo[window.bufh].filetype)
    assert.equals("acwrite", vim.bo[window.bufh].buftype)
  end)

  it("calls on_save when the buffer is written", function()
    local saved
    window.on_save = function(str)
      saved = str
    end
    window.set_content("return 1")
    window.toggle_window()

    vim.api.nvim_set_current_win(window.win_id)
    vim.cmd("write")

    assert.equals("return 1\n", saved)
  end)

  it("closes on toggle", function()
    window.set_content("x")
    window.toggle_window()
    window.toggle_window()
    assert.is_false(window.is_open())
  end)
end)
