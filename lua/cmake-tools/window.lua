local function create_window(title)
  local width = math.min(80, vim.o.columns)
  local height = math.min(20, vim.o.lines)
  local bufnr = vim.api.nvim_create_buf(false, false)

  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = "rounded",
  }
  if title and title ~= "" then
    config.title = title
    config.title_pos = "center"
  end

  local win_id = vim.api.nvim_open_win(bufnr, true, config)

  return {
    bufnr = bufnr,
    win_id = win_id,
  }
end

local M = {
  win_id = nil,
  bufh = nil,
  content = nil,
  on_save = nil,
  on_exit = nil,
  title = "",
}

function M.set_content(str)
  local lines = {}
  for s in str:gmatch("[^\r\n]+") do
    table.insert(lines, s)
  end
  M.content = lines
end

function M.is_open()
  return M.win_id ~= nil and vim.api.nvim_win_is_valid(M.win_id)
end

function M.close_menu()
  vim.api.nvim_win_close(M.win_id, true)

  M.win_id = nil
  M.bufh = nil
end

function M.save()
  local str = ""
  local lines = vim.api.nvim_buf_get_lines(M.bufh, 0, -1, true)
  for _, v in ipairs(lines) do
    str = str .. v .. "\n"
  end
  if M.on_save ~= nil and type(M.on_save) == "function" then
    M.on_save(str)
  end
end

function M.exit()
  local str = ""
  local lines = vim.api.nvim_buf_get_lines(M.bufh, 0, -1, true)
  for _, v in ipairs(lines) do
    str = str .. v .. "\n"
  end
  if M.on_exit ~= nil and type(M.on_exit) == "function" then
    M.on_exit(str)
  end
end

function M.open()
  local win_info = create_window(M.title)

  M.win_id = win_info.win_id
  M.bufh = win_info.bufnr

  vim.wo[M.win_id].number = true
  vim.api.nvim_buf_set_name(M.bufh, "cmake-tools.env-config")
  vim.api.nvim_buf_set_lines(M.bufh, 0, #M.content, false, M.content)
  vim.bo[M.bufh].filetype = "lua"
  vim.bo[M.bufh].buftype = "acwrite"
  vim.bo[M.bufh].bufhidden = "delete"

  vim.keymap.set("n", "q", function()
    M.toggle_window()
  end, { silent = true, buffer = M.bufh })

  vim.keymap.set("n", "<ESC>", function()
    M.toggle_window()
  end, { silent = true, buffer = M.bufh })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = M.bufh,
    callback = function()
      M.save()
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    buffer = M.bufh,
    callback = function()
      M.exit()
    end,
  })

  -- autosave optional?
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    buffer = M.bufh,
    callback = function()
      M.save()
    end,
  })

  vim.api.nvim_create_autocmd("BufModifiedSet", {
    buffer = M.bufh,
    command = "set nomodified",
  })
end

function M.toggle_window()
  if M.is_open() then
    M.close_menu()
    return
  end

  M.open()
end

return M
