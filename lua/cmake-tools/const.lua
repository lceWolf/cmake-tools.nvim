local osys = require("cmake-tools.osys")

-- Error format used to parse command output into quickfix entries. The quickfix
-- executor/runner parses with this instead of the global 'errorformat', so a build is
-- matched the same way regardless of how the rest of the config sets that option
local quickfix_errorformat = table.concat({
  -- Lines that must not become entries. make points its "*** [Makefile:42: all]"
  -- summaries at the generated makefile, and gcc/clang frame a diagnostic with an
  -- include trace and a caret/source-context block.
  "%-Gg%\\?make[%*\\d]: *** [%f:%l:%m",
  "%-Gg%\\?make: *** [%f:%l:%m",
  "%-GIn file included from %f:%l:",
  "%-GIn file included from %f:%l",
  "%-G%*[ ]from %f:%l:",
  "%-G%*[ 0123456789]|%.%#",
  -- cmake itself, for configure/generate output. %t picks up the E/W.
  "CMake %trror at %f:%l (%m):",
  "CMake %tarning at %f:%l (%m):",
  "CMake %tarning (dev) at %f:%l (%m):",
  "CMake Deprecation %tarning at %f:%l (%m):",
  -- gcc/clang, with and without a column
  "%f:%l:%c: fatal %trror: %m",
  "%f:%l:%c: %trror: %m",
  "%f:%l:%c: %tarning: %m",
  "%f:%l:%c: %tote: %m",
  "%f:%l:%c: %m",
  "%f:%l: fatal %trror: %m",
  "%f:%l: %trror: %m",
  "%f:%l: %tarning: %m",
  "%f:%l: %m",
  -- MSVC / MSBuild
  "%f(%l\\,%c) %#: %trror %m",
  "%f(%l\\,%c) %#: %tarning %m",
  "%f(%l) %#: %trror %m",
  "%f(%l) %#: %tarning %m",
  -- make directory tracking, so a build that reports relative paths resolves them
  -- against the directory make announced rather than against Neovim's cwd
  "%D%*\\a[%*\\d]: Entering directory %*[`']%f'",
  "%X%*\\a[%*\\d]: Leaving directory %*[`']%f'",
  "%D%*\\a: Entering directory %*[`']%f'",
  "%X%*\\a: Leaving directory %*[`']%f'",
}, ",")

---@class Const
local const = {
  cmake_command = "cmake", -- this is used to specify cmake command path
  ctest_command = "ctest", -- this is used to specify ctest command path
  ctest_show_labels = false, -- show test labels in the test picker (when true, labels from ctest are shown as filterable entries)
  cmake_use_preset = true, -- when `false`, this is used to define if the `--preset` option should be use on cmake commands
  cmake_regenerate_on_save = true, -- auto generate when save CMakeLists.txt
  cmake_generate_options = { "-DCMAKE_EXPORT_COMPILE_COMMANDS=1" }, -- this will be passed when invoke `CMakeGenerate`
  cmake_build_options = {}, -- this will be passed when invoke `CMakeBuild`
  cmake_show_disabled_build_presets = true,
  cmake_build_directory = function()
    if osys.iswin32 then
      return "out\\${variant:buildType}"
    end
    return "out/${variant:buildType}"
  end, -- this is used to specify generate directory for cmake
  cmake_compile_commands_options = {
    action = "soft_link", -- available options: soft_link, copy, lsp, none
    -- soft_link: this will automatically make a soft link from compile commands file to target
    -- copy:      this will automatically copy compile commands file to target
    -- lsp:       this will automatically set compile commands file location using lsp
    -- none:      this will make this option ignored
    ---@type string|fun(): string
    target = vim.loop.cwd, -- path or function returning path to directory, this is used only if action == "soft_link" or action == "copy"
  },
  cmake_kits_path = nil, -- this is used to specify global cmake kits path, see CMakeKits for detailed usage
  cmake_variants_message = {
    short = { show = true }, -- whether to show short message
    long = { show = true, max_length = 40 }, -- whether to show long message
  },
  cmake_dap_configuration = { -- debug settings for cmake
    name = "cpp",
    type = "codelldb",
    request = "launch",
    stopOnEntry = false,
    runInTerminal = true,
    console = "integratedTerminal",
  },
  cmake_executor = { -- executor to use
    name = "quickfix", -- name of the executor
    opts = {}, -- the options the executor will get, possible values depend on the executor type. See `default_opts` for possible values.
    default_opts = { -- a list of default and possible values for executors
      quickfix = {
        show = "always", -- "always", "only_on_error"
        position = "belowright", -- "bottom", "top"
        size = 10,
        encoding = "utf-8",
        auto_close_when_success = true, -- typically, you can use it with the "always" option; it will auto-close the quickfix buffer if the execution is successful.
        errorformat = quickfix_errorformat, -- see `quickfix_errorformat` above
      },
      toggleterm = {
        direction = "float", -- 'vertical' | 'horizontal' | 'tab' | 'float'
        close_on_exit = false, -- whether close the terminal when exit
        auto_scroll = true, -- auto scroll on new input
        scroll_on_error = false, -- scroll to bottom on error
        auto_focus = true, -- auto focus the terminal on activation
        focus_on_error = false, -- focus on error
        singleton = true, -- single instance, autocloses the opened one, if present
      },
      overseer = {
        new_task_opts = {
          strategy = nil, -- use overseer's default for this
        }, -- options to pass into the `overseer.new_task` command
        on_new_task = function(task)
          require("overseer").open({ enter = false, direction = "right" })
        end, -- a function that gets overseer.Task when it is created, before calling `task:start`
      },
      vimux = {},
      terminal = {
        name = "Executor Terminal",
        prefix_name = "[CMakeTools]: ", -- This must be included and must be unique, otherwise the terminals will not work. Do not use a simple spacebar " ", or any generic name
        split_direction = "horizontal", -- "horizontal", "vertical"
        split_size = 11,

        -- Window handling
        single_terminal_per_instance = true, -- Single instance, multiple windows
        single_terminal_per_tab = true, -- Single instance per tab
        keep_terminal_static_location = true, -- Static location of the instance if avialable
        auto_resize = true, -- Resize the terminal if it already exists

        -- Running Tasks
        start_insert = false, -- If you want to enter terminal with :startinsert upon using :CMakeRun
        focus = false, -- Focus on terminal when cmake task is launched.
        do_not_add_newline = false, -- Do not hit enter on the command inserted when using :CMakeRun, allowing a chance to review or modify the command before hitting enter.
      },
    },
  },
  cmake_runner = { -- executor to use
    name = "terminal", -- name of the runner
    opts = {}, -- the options the runner will get, possible values depend on the runner type. See `default_opts` for possible values.
    default_opts = { -- a list of default and possible values for runners
      quickfix = {
        show = "always", -- "always", "only_on_error"
        position = "belowright", -- "bottom", "top"
        size = 10,
        encoding = "utf-8",
        auto_close_when_success = true, -- typically, you can use it with the "always" option; it will auto-close the quickfix buffer if the execution is successful.
        errorformat = quickfix_errorformat, -- see `quickfix_errorformat` above
      },
      toggleterm = {
        direction = "float", -- 'vertical' | 'horizontal' | 'tab' | 'float'
        close_on_exit = false, -- whether close the terminal when exit
        auto_scroll = true, -- auto scroll on new input
        scroll_on_error = false, -- scroll to bottom on error
        auto_focus = true, -- auto focus the terminal on activation
        focus_on_error = false, -- focus on error
        singleton = true, -- single instance, autocloses the opened one, if present
      },
      overseer = {
        new_task_opts = {
          strategy = nil,
        }, -- options to pass into the `overseer.new_task` command
        on_new_task = function(task)
          require("overseer").open({ enter = false, direction = "right" })
        end, -- a function that gets overseer.Task when it is created, before calling `task:start`
      },
      vimux = {},
      terminal = {
        name = "Runner Terminal",
        prefix_name = "[CMakeTools]: ", -- This must be included and must be unique, otherwise the terminals will not work. Do not use a simple spacebar " ", or any generic name
        split_direction = "horizontal", -- "horizontal", "vertical"
        split_size = 11,

        -- Window handling
        single_terminal_per_instance = true, -- Single instance, multiple windows
        single_terminal_per_tab = true, -- Single instance per tab
        keep_terminal_static_location = true, -- Static location of the instance if avialable
        auto_resize = true, -- Resize the terminal if it already exists

        -- Running Tasks
        start_insert = false, -- If you want to enter terminal with :startinsert upon using :CMakeRun
        focus = false, -- Focus on terminal when cmake task is launched.
        do_not_add_newline = false, -- Do not hit enter on the command inserted when using :CMakeRun, allowing a chance to review or modify the command before hitting enter.
        use_shell_alias = false, -- Hide the implementation details used to run the built target by using a shell alias
      },
    },
  },
  cmake_notifications = {
    runner = { enabled = true },
    executor = { enabled = true },
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }, -- icons used for progress display
    refresh_rate_ms = 100, -- how often to iterate icons
  },
  cmake_virtual_text_support = true, -- Show the target related to current file using virtual text (at right corner)
  cmake_use_scratch_buffer = false, -- A buffer that shows what cmake-tools has done
}

local const_mt = {}
const_mt.__index = const_mt

--- Setup const with user-provided values
---@param values Const user configuration overrides
function const_mt.setup(values)
  local merged = vim.tbl_deep_extend("force", const, values)
  for k, v in pairs(merged) do
    const[k] = v
  end

  const.cmake_executor.opts = vim.tbl_deep_extend(
    "force",
    const.cmake_executor.default_opts[const.cmake_executor.name],
    const.cmake_executor.opts or {}
  )
  const.cmake_runner.opts = vim.tbl_deep_extend(
    "force",
    const.cmake_runner.default_opts[const.cmake_runner.name],
    const.cmake_runner.opts or {}
  )
end

return setmetatable(const, const_mt)
