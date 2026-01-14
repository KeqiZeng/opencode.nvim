---@module 'snacks.picker'
---@module 'mini.pick'

local M = {}

---@class opencode.select.Opts
---
---Picker to use: "mini.pick" | "snacks" | nil (uses `vim.ui.select` by default)
---@field picker? string
---
---Configure the displayed sections.
---@field sections? opencode.select.sections.Opts
---
---Options for mini.pick (passed to `MiniPick.start()`).
---@field mini_pick? table
---
---Options for snacks.picker (passed to `vim.ui.select`).
---@field snacks? table

---@class opencode.select.sections.Opts
---
---Whether to show the prompts section.
---@field prompts? boolean
---
---Commands to display, and their descriptions.
---Or `false` to hide the commands section.
---@field commands? table<opencode.Command|string, string>|false
---
---Whether to show the provider section.
---Always `false` if no provider is available.
---@field provider? boolean

---Select from all `opencode.nvim` functionality.
---
--- - Fetches custom commands from `opencode`.
--- - Highlights and previews items when using `snacks.picker`.
---
---@param opts? opencode.select.Opts Override configured options for this call.
function M.select(opts)
  opts = vim.tbl_deep_extend("force", require("opencode.config").opts.select or {}, opts or {})
  if not require("opencode.config").provider then
    opts.sections.provider = false
  end

  -- TODO: Should merge with prompts' optional contexts
  local context = require("opencode.context").new()

  require("opencode.cli.server")
    .get_port()
    :next(function(port)
      if opts.sections.prompts then
        return require("opencode.promise").new(function(resolve)
          require("opencode.cli.client").get_agents(port, function(agents)
            context.agents = vim.tbl_filter(function(agent)
              return agent.mode == "subagent"
            end, agents)

            resolve(port)
          end)
        end)
      else
        return port
      end
    end)
    :next(function(port)
      if opts.sections.commands then
        return require("opencode.promise").new(function(resolve)
          require("opencode.cli.client").get_commands(port, function(custom_commands)
            resolve(custom_commands)
          end)
        end)
      else
        return {}
      end
    end)
    :next(function(custom_commands)
      local prompts = require("opencode.config").opts.prompts or {}
      local commands = require("opencode.config").opts.select.sections.commands or {}
      for _, command in ipairs(custom_commands) do
        commands[command.name] = command.description
      end

      ---@type snacks.picker.finder.Item[]
      local items = {}

      -- Prompts section
      if opts.sections.prompts then
        table.insert(items, { __group = true, name = "PROMPT", preview = { text = "" } })
        local prompt_items = {}
        for name, prompt in pairs(prompts) do
          local rendered = context:render(prompt.prompt)
          ---@type snacks.picker.finder.Item
          local item = {
            __type = "prompt",
            name = name,
            text = prompt.prompt .. (prompt.ask and "…" or ""),
            highlights = rendered.input, -- `snacks.picker`'s `select` seems to ignore this, so we incorporate it ourselves in `format_item`
            preview = {
              text = context.plaintext(rendered.output),
              extmarks = context.extmarks(rendered.output),
            },
            ask = prompt.ask,
            submit = prompt.submit,
          }
          table.insert(prompt_items, item)
        end
        -- Sort: ask=true, submit=false, name
        table.sort(prompt_items, function(a, b)
          if a.ask and not b.ask then
            return true
          elseif not a.ask and b.ask then
            return false
          elseif not a.submit and b.submit then
            return true
          elseif a.submit and not b.submit then
            return false
          else
            return a.name < b.name
          end
        end)
        for _, item in ipairs(prompt_items) do
          table.insert(items, item)
        end
      end

      -- Commands section
      if type(opts.sections.commands) == "table" then
        table.insert(items, { __group = true, name = "COMMAND", preview = { text = "" } })
        local command_items = {}
        for name, description in pairs(commands) do
          table.insert(command_items, {
            __type = "command",
            name = name, -- TODO: Truncate if it'd run into `text`
            text = description,
            highlights = { { description, "Comment" } },
            preview = {
              text = "",
            },
          })
        end
        table.sort(command_items, function(a, b)
          return a.name < b.name
        end)
        for _, item in ipairs(command_items) do
          table.insert(items, item)
        end
      end

      -- Provider section
      if opts.sections.provider then
        table.insert(items, { __group = true, name = "PROVIDER", preview = { text = "" } })
        table.insert(items, {
          __type = "provider",
          name = "toggle",
          text = "Toggle opencode",
          highlights = { { "Toggle opencode", "Comment" } },
          preview = { text = "" },
        })
        table.insert(items, {
          __type = "provider",
          name = "start",
          text = "Start opencode",
          highlights = { { "Start opencode", "Comment" } },
          preview = { text = "" },
        })
        table.insert(items, {
          __type = "provider",
          name = "stop",
          text = "Stop opencode",
          highlights = { { "Stop opencode", "Comment" } },
          preview = { text = "" },
        })
      end

      for i, item in ipairs(items) do
        item.idx = i -- Store the index for non-snacks formatting
      end

      local function handle_choice(choice)
        if not choice then
          context:resume()
          return
        else
          context:clear()
        end

        if choice.__type == "prompt" then
          ---@type opencode.Prompt
          local prompt = require("opencode.config").opts.prompts[choice.name]
          prompt.context = context
          if prompt.ask then
            require("opencode").ask(prompt.prompt, prompt)
          else
            require("opencode").prompt(prompt.prompt, prompt)
          end
        elseif choice.__type == "command" then
          require("opencode").command(choice.name)
        elseif choice.__type == "provider" then
          if choice.name == "toggle" then
            require("opencode").toggle()
          elseif choice.name == "start" then
            require("opencode").start()
          elseif choice.name == "stop" then
            require("opencode").stop()
          end
        end
      end

      local picker = opts.picker or nil
      local has_mini_pick, MiniPick = pcall(require, "mini.pick")
      local has_snacks = pcall(function()
        return require("snacks").picker
      end)

      if picker == "mini.pick" then
        if not has_mini_pick then
          vim.notify("mini.pick not installed, falling back to vim.ui.select", vim.log.levels.WARN)
          picker = nil
        end
      elseif picker == "snacks" then
        if not has_snacks then
          vim.notify("snacks.nvim not installed, falling back to vim.ui.select", vim.log.levels.WARN)
          picker = nil
        end
      end

      local function format_item(item, is_snacks)
        if is_snacks then
          if item.__group then
            return { { item.name, "Title" } }
          end
          local formatted = vim.deepcopy(item.highlights)
          if item.ask then
            table.insert(formatted, { "…", "Keyword" })
          end
          table.insert(formatted, 1, { item.name, "Keyword" })
          table.insert(formatted, 2, { string.rep(" ", 18 - #item.name) })
          return formatted
        else
          local indent = #tostring(#items) - #tostring(item.idx)
          if item.__group then
            local divider = string.rep("—", (80 - #item.name) / 2)
            return string.rep(" ", indent) .. divider .. item.name .. divider
          end
          return ("%s[%s]%s%s"):format(
            string.rep(" ", indent),
            item.name,
            string.rep(" ", 18 - #item.name),
            item.text or ""
          )
        end
      end

      if picker == "mini.pick" then
        local function format_mini_pick_item(item)
          if item.__group then
            return "── " .. item.name .. " ──"
          end
          local result = string.format("%-16s", item.name)
          if item.ask then
            result = result .. "… "
          else
            result = result .. "  "
          end
          result = result .. (item.text or "")
          return result
        end

        local function mini_pick_preview(buf_id, item)
          if not item or item.__group then
            vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { "" })
            return
          end

          local preview = item.preview
          if preview and preview.text then
            local lines = vim.split(preview.text, "\n")
            vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
            if preview.extmarks then
              for _, extmark in ipairs(preview.extmarks) do
                local row, col, end_row, end_col, hl_group = unpack(extmark)
                vim.api.nvim_buf_set_extmark(buf_id, 0, row, col, {
                  end_row = end_row,
                  end_col = end_col,
                  hl_group = hl_group,
                })
              end
            end
          else
            vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, { "No preview available" })
          end
        end

        local mini_pick_opts = opts.mini_pick or {}
        MiniPick.start(vim.tbl_deep_extend("force", {
          source = {
            items = items,
            name = "opencode",
            show = function(buf_id, items_arr, _query)
              local lines = vim.tbl_map(format_mini_pick_item, items_arr)
              vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
            end,
            preview = mini_pick_preview,
            choose = function(item)
              handle_choice(item)
              return false
            end,
          },
        }, mini_pick_opts))
      elseif picker == "snacks" then
        local snacks_opts = opts.snacks or {}
        vim.ui.select(items, vim.tbl_deep_extend("force", {
          format_item = format_item,
        }, snacks_opts), handle_choice)
      else
        vim.ui.select(items, {
          format_item = format_item,
        }, handle_choice)
      end
    end)
    :catch(function(err)
      vim.notify(err, vim.log.levels.ERROR)
    end)
end

return M
