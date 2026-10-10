local M = {}
local go = require("hoverchain.go")
local uv = vim.uv or vim.loop
local ignored = {}
local contexts = {}

function M.source(uri)
  local path = vim.uri_to_fname(uri)
  local buf = vim.fn.bufnr(path)
  if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or ""
end

local function workspace_context(client, buf)
  local roots = {}
  for _, folder in ipairs(client.workspace_folders or {}) do
    roots[#roots + 1] = vim.uri_to_fname(folder.uri)
  end
  if type(client.config.root_dir) == "string" then
    roots[#roots + 1] = client.config.root_dir
  end
  for i, root in ipairs(roots) do
    roots[i] = (uv.fs_realpath(root) or vim.fs.normalize(root)):gsub("/+$", "")
  end
  local function candidate(path)
    if not path:match("%.go$") then
      return
    end
    local canonical = uv.fs_realpath(path) or vim.fs.normalize(path)
    local inside = #roots == 0
    for _, root in ipairs(roots) do
      inside = inside or canonical:sub(1, #root + 1) == root .. "/"
    end
    if inside then
      local header = go.header(M.source(vim.uri_from_fname(path)))
      if header.package_name then
        contexts[client.id] = path
        return path, header
      end
    end
  end
  local path, header = candidate(vim.api.nvim_buf_get_name(buf))
  if not path and contexts[client.id] then
    path, header = candidate(contexts[client.id])
  end
  if not path then
    local buffers = vim.tbl_keys(client.attached_buffers)
    table.sort(buffers)
    for _, candidate_buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(candidate_buf) then
        path, header = candidate(vim.api.nvim_buf_get_name(candidate_buf))
      end
      if path then
        break
      end
    end
  end
  return path, header
end

function M.new(client, buf)
  local source_path = vim.api.nvim_buf_get_name(buf)
  if source_path == "" or not go.header(M.source(vim.uri_from_bufnr(buf))).package_name then
    return nil, "名前のある Go ファイルで実行してください"
  end
  local path, header = workspace_context(client, buf)
  if not path then
    return nil,
      "問い合わせに使える Go ファイルがありません。同じ gopls のワークスペース内で Go ファイルを開いてください"
  end
  local directory = vim.fs.dirname(path)
  local probe = directory .. "/hoverchain_query_" .. vim.fn.getpid() .. ".go"
  while uv.fs_stat(probe) or vim.fn.bufnr(probe) >= 0 do
    probe = probe:gsub("%.go$", "_.go")
  end
  local session = {
    client = client,
    root_dir = directory,
    package_name = header.package_name,
    probe_uri = vim.uri_from_fname(probe),
    version = 0,
    pending = {},
    generation = 0,
  }
  -- Diagnostics for our in-memory lookup file must not appear in the editor.
  if not ignored[client.id] then
    local entry = { uris = {} }
    ignored[client.id] = entry
    local original = client.handlers["textDocument/publishDiagnostics"]
      or vim.lsp.handlers["textDocument/publishDiagnostics"]
    client.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
      if result and entry.uris[result.uri] then
        return
      end
      return original(err, result, ctx, config)
    end
  end
  ignored[client.id].uris[session.probe_uri] = true
  return session
end

function M.cancel(session)
  session.generation = session.generation + 1
  for id in pairs(session.pending) do
    session.client:cancel_request(id)
  end
  session.pending = {}
end

function M.close(session)
  M.cancel(session)
  if session.version > 0 and not session.client:is_stopped() then
    session.client:notify("textDocument/didClose", { textDocument = { uri = session.probe_uri } })
  end
end

local function request(session, method, params, callback)
  local generation = session.generation
  local id
  local ok
  ok, id = session.client:request(method, params, function(err, result)
    if id then
      session.pending[id] = nil
    end
    if generation == session.generation then
      callback(err, result)
    end
  end)
  if ok then
    session.pending[id] = true
  else
    callback({ message = "gopls にリクエストを送信できませんでした" })
  end
end

local function location(result)
  local first = result and (result[1] or result)
  if not first then
    return nil
  end
  if first.targetUri then
    return { uri = first.targetUri, range = first.targetSelectionRange or first.targetRange }
  end
  return first.uri and first or nil
end

function M.page(session, params, callback)
  request(session, "textDocument/hover", params, function(err, result)
    if err or not result or not result.contents then
      callback(err or { message = "この名前のドキュメントを解決できませんでした" })
      return
    end
    request(session, "textDocument/definition", params, function(deferr, definitions)
      if deferr then
        callback(deferr)
        return
      end
      local loc = location(definitions) or { uri = params.textDocument.uri, range = { start = params.position } }
      if loc.uri == session.probe_uri then
        callback({ message = "この名前の定義を解決できませんでした" })
        return
      end
      local text = go.contents(result)
      local path, anchor = go.metadata(text)
      local header = go.header(M.source(loc.uri))
      callback(nil, {
        markdown = text,
        location = loc,
        header = header,
        package_path = path,
        anchor = anchor,
        type_name = (text:match("^```go\n(.-)\n```") or ""):match("^type%s+([%w_\128-\255]+)"),
        local_package = vim.fs.dirname(vim.uri_to_fname(loc.uri)) == session.root_dir,
      })
    end)
  end)
end

function M.resolve(session, page, target, callback)
  M.cancel(session)
  if target.location then
    M.page(session, { textDocument = { uri = target.location.uri }, position = target.location.range.start }, callback)
    return
  end
  if target.own_package and not page.local_package and not page.package_path then
    callback({ message = "この外部シンボルのパッケージを特定できませんでした" })
    return
  end
  local text, position = go.probe(session, page, target)
  session.version = session.version + 1
  if session.version == 1 then
    session.client:notify("textDocument/didOpen", {
      textDocument = { uri = session.probe_uri, languageId = "go", version = session.version, text = text },
    })
  else
    session.client:notify("textDocument/didChange", {
      textDocument = { uri = session.probe_uri, version = session.version },
      contentChanges = { { text = text } },
    })
  end
  M.page(session, { textDocument = { uri = session.probe_uri }, position = position }, callback)
end

return M
