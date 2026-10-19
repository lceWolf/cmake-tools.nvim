local log = require("cmake-tools.log")
local utils = require("cmake-tools.utils")

local ctest = {
  job = nil,
}

function ctest.list_all_tests(build_dir, preset_name, callback)
  local args
  if preset_name then
    args = { "--preset", preset_name, "--show-only=json-v1" }
  else
    args = { "--test-dir", build_dir, "--show-only=json-v1" }
  end

  local handle
  local ok, result = pcall(
    vim.system,
    vim.list_extend({ "ctest" }, args),
    { text = true },
    function(res)
      vim.schedule(function()
        if ctest.job == handle then
          ctest.job = nil
        end

        local decoded
        if res.code == 0 and res.stdout and res.stdout ~= "" then
          local decode_ok, value = pcall(vim.json.decode, res.stdout)
          if decode_ok and type(value) == "table" then
            decoded = value
          end
        end

        if not decoded then
          log.error(
            "Failed to list ctest tests (exit code "
              .. tostring(res.code)
              .. "): "
              .. (res.stderr or "")
          )
          callback({})
          return
        end

        local tests = {}
        for _, item in ipairs(decoded.tests or {}) do
          local labels = {}
          if item["properties"] then
            for _, prop in ipairs(item["properties"]) do
              if prop["name"] == "LABELS" then
                labels = prop["value"] or {}
                break
              end
            end
          end
          table.insert(tests, { name = item["name"], labels = labels })
        end
        callback(tests)
      end)
    end
  )

  if not ok then
    log.error(tostring(result))
    callback({})
    return
  end
  handle = result
  ctest.job = handle
end

--- Collect all labels from test objects with counts
--- @param tests { name: string, labels: string[] }[]
--- @return { label: string, count: number }[] sorted list of labels with their test counts
function ctest.get_all_labels(tests)
  local label_counts = {}
  for _, test in ipairs(tests) do
    for _, label in ipairs(test.labels) do
      label_counts[label] = (label_counts[label] or 0) + 1
    end
  end

  local labels = {}
  for label, count in pairs(label_counts) do
    table.insert(labels, { label = label, count = count })
  end
  table.sort(labels, function(a, b)
    return a.label < b.label
  end)
  return labels
end

function ctest.run(ctest_command, env, config, opt)
  opt = opt or {}

  local args = {}
  if opt.preset then
    vim.list_extend(args, { "--preset", opt.preset })
  else
    vim.list_extend(args, { "--test-dir", opt.build_dir })
  end

  if opt.label then
    vim.list_extend(args, { "-L", opt.label })
  elseif opt.test_name then
    vim.list_extend(args, { "-R", opt.test_name })
  end

  if opt.args then
    table.insert(args, opt.args)
  end

  utils.run(ctest_command, config.env_script, env, args, config.cwd, config.runner, nil)
end

function ctest.stop()
  local job = ctest.job
  if not job or job:is_closing() then
    return
  end

  for _, pid in ipairs(vim.api.nvim_get_proc_children(job.pid)) do
    vim.uv.kill(pid, 9)
  end
  job:kill(9)
end

return ctest
