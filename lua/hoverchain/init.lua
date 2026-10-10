local uv = vim.uv or vim.loop
local M = {}
local api = vim.api
local go = require("hoverchain.go")
local lsp = require("hoverchain.lsp")

M.config = { border = "rounded", max_width = 100, max_height = 30, keymap = "K", mock = false }
M.state = { pages = {} }

local function notify(message, level)
  vim.notify("[hoverchain] " .. message, level or vim.log.levels.WARN)
end

function M.close()
  local state = M.state
  M.state = { pages = {} }
  if state.session then
    lsp.close(state.session)
  end
  if state.closed_autocmd then
    pcall(api.nvim_del_autocmd, state.closed_autocmd)
  end
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  if state.buf and api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
end

local function draw(page)
  local state = M.state
  local lines = vim.split(page.markdown, "\n", { plain = true })
  local width = math.min(M.config.max_width, math.max(20, vim.o.columns - 4))
  local height = math.min(M.config.max_height, math.max(3, vim.o.lines - 6), #lines)
  if not state.buf or not api.nvim_buf_is_valid(state.buf) then
    state.buf = api.nvim_create_buf(false, true)
    vim.bo[state.buf].bufhidden = "wipe"
    vim.bo[state.buf].filetype = "markdown"
    local opts = { buffer = state.buf, silent = true }
    vim.keymap.set("n", "K", M.hover, vim.tbl_extend("force", opts, { desc = "次のドキュメント" }))
    vim.keymap.set("n", "gd", M.definition, vim.tbl_extend("force", opts, { desc = "定義へ移動" }))
    vim.keymap.set("n", "<CR>", M.hover, opts)
    vim.keymap.set("n", "<C-o>", M.back, vim.tbl_extend("force", opts, { desc = "前のドキュメント" }))
    vim.keymap.set("n", "q", M.close, opts)
    vim.keymap.set("n", "<Esc>", M.close, opts)
    state.closed_autocmd = api.nvim_create_autocmd("WinClosed", {
      group = "Hoverchain",
      callback = function(args)
        if M.state == state and tonumber(args.match) == state.win then
          M.close()
        end
      end,
    })
  end
  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  local config = {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    border = M.config.border,
    style = "minimal",
    title = " "
      .. (page.anchor or "Go")
      .. " · "
      .. #state.pages
      .. "  K:開く  gd:定義  Ctrl-o:戻る  q:閉じる ",
    title_pos = "center",
  }
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_set_config(state.win, config)
    api.nvim_set_current_win(state.win)
  else
    state.win = api.nvim_open_win(state.buf, true, config)
  end
  vim.wo[state.win].wrap = true
  vim.wo[state.win].conceallevel = 2
  vim.wo[state.win].concealcursor = "nc"
  pcall(vim.treesitter.start, state.buf, "markdown")
  api.nvim_win_set_cursor(state.win, page.cursor or { 1, 0 })
end

local function push(page)
  local state = M.state
  if state.win and api.nvim_win_is_valid(state.win) and #state.pages > 0 then
    state.pages[#state.pages].cursor = api.nvim_win_get_cursor(state.win)
  end
  state.pages[#state.pages + 1] = page
  draw(page)
end

local function navigate(jump)
  local state = M.state
  local page = state.pages[#state.pages]
  if not page or state.busy then
    return
  end
  local cursor = api.nvim_win_get_cursor(state.win)
  local line = api.nvim_buf_get_lines(state.buf, cursor[1] - 1, cursor[1], false)[1]
  local target, err = go.target(page, line, cursor[2])
  if not target then
    notify(err)
    return
  end
  if M.config.mock then
    push({
      markdown = "```go\ntype Example struct{}\n```\n\nネット接続不要のデモです。Ctrl-o で戻れます。",
      header = { imports = {} },
      anchor = "Example",
    })
    return
  end
  state.busy = true
  lsp.resolve(state.session, page, target, function(resolve_err, next_page)
    if M.state ~= state then
      return
    end
    state.busy = false
    if resolve_err then
      notify(resolve_err.message or tostring(resolve_err))
    elseif jump then
      local client, origin_win = state.session.client, state.origin_win
      M.close()
      if api.nvim_win_is_valid(origin_win) then
        api.nvim_set_current_win(origin_win)
      end
      vim.lsp.util.show_document(next_page.location, client.offset_encoding, { focus = true })
    else
      push(next_page)
    end
  end)
end

function M.definition()
  navigate(true)
end

function M.back()
  local state = M.state
  if state.session then
    lsp.cancel(state.session)
  end
  state.busy = false
  if #state.pages > 1 then
    table.remove(state.pages)
    draw(state.pages[#state.pages])
  else
    M.close()
  end
end

function M.hover()
  local state = M.state
  if state.win and api.nvim_win_is_valid(state.win) then
    if api.nvim_get_current_win() == state.win then
      navigate(false)
    else
      api.nvim_set_current_win(state.win)
    end
    return
  end
  M.close()
  state = M.state
  state.origin_win = api.nvim_get_current_win()
  if M.config.mock then
    push({
      markdown = "```go\ntype Example struct{}\n```\n\nExample にカーソルを置いて K。",
      header = { imports = {} },
      anchor = "Example",
    })
    return
  end
  local buf = api.nvim_get_current_buf()
  local client = vim.lsp.get_clients({ bufnr = buf, name = "gopls" })[1]
  if not client or not client.initialized then
    notify("このバッファに gopls が接続されていません")
    return
  end
  local session, err = lsp.new(client, buf)
  if not session then
    notify(err)
    return
  end
  state.session, state.busy = session, true
  local params = vim.lsp.util.make_position_params(state.origin_win, client.offset_encoding)
  lsp.page(session, params, function(hover_err, page)
    if M.state ~= state then
      return
    end
    state.busy = false
    if hover_err then
      notify(hover_err.message or tostring(hover_err))
      M.close()
    else
      -- Initial hover signatures are qualified relative to the user's source file.
      page.header.imports = go.header(lsp.source(params.textDocument.uri)).imports
      push(page)
    end
  end)
end

function M.setup(opts)
  M.close()
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  api.nvim_create_augroup("Hoverchain", { clear = true })
  api.nvim_create_user_command("Hoverchain", M.hover, { desc = "Go のドキュメントを辿る", force = true })
  api.nvim_create_user_command("HoverchainClose", M.close, { desc = "ホバーを閉じる", force = true })
  api.nvim_create_autocmd("VimLeavePre", { group = "Hoverchain", callback = M.close })
  local function map(buf)
    if
      M.config.keymap
      and api.nvim_buf_is_valid(buf)
      and vim.bo[buf].filetype == "go"
      and #vim.lsp.get_clients({ bufnr = buf, name = "gopls" }) > 0
    then
      vim.keymap.set(
        "n",
        M.config.keymap,
        M.hover,
        { buffer = buf, silent = true, desc = "Go のドキュメントを辿る" }
      )
    end
  end
  api.nvim_create_autocmd("LspAttach", {
    group = "Hoverchain",
    callback = function(args)
      -- Run after other LspAttach mappings, including configurations using Noice.
      vim.schedule(function()
        map(args.buf)
      end)
    end,
  })
  for _, client in ipairs(vim.lsp.get_clients({ name = "gopls" })) do
    for buf in pairs(client.attached_buffers) do
      map(buf)
    end
  end
end

return M
