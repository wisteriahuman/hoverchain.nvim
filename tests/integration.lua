local api = vim.api
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
local hc = require("hoverchain")
hc.setup()
local fixtures = root .. "/tests/fixtures"
vim.cmd.edit(fixtures .. "/main.go")
vim.bo.filetype = "go"
local origin = api.nvim_get_current_buf()
local capabilities = vim.lsp.protocol.make_client_capabilities()
capabilities.workspace.didChangeWatchedFiles.dynamicRegistration = false
local id = vim.lsp.start({
  name = "gopls",
  cmd = { "gopls", "serve" },
  root_dir = fixtures,
  settings = { gopls = vim.empty_dict() },
  capabilities = capabilities,
})
local client = assert(vim.lsp.get_client_by_id(id))
local function wait(check, message)
  assert(vim.wait(20000, check, 20), message)
end
wait(function()
  return client.initialized
end, "gopls did not initialize")
wait(function()
  return vim.fn.maparg("K", "n", false, true).callback == hc.hover
end, "Go K mapping was not installed")
local function place(buf, needle, word)
  for n, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(needle, 1, true) then
      local col = assert(line:find(word, 1, true)) - 1
      api.nvim_win_set_cursor(0, { n, col })
      return
    end
  end
  error("not found: " .. needle)
end
local function follow(needle, word)
  local count = #hc.state.pages
  if api.nvim_get_current_win() ~= hc.state.win then
    hc.hover()
    assert(api.nvim_get_current_win() == hc.state.win and #hc.state.pages == count, "second K did not focus hover")
  end
  place(hc.state.buf, needle, word)
  hc.hover()
  wait(function()
    return #hc.state.pages == count + 1
  end, "could not follow: " .. needle)
  return hc.state.pages[#hc.state.pages]
end
place(origin, "_ = b.API", "API")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "initial hover failed")
assert(api.nvim_get_current_buf() == origin, "first K moved focus away from source")
assert(hc.state.pages[1].markdown:find("field API *api.Client", 1, true))
local page = follow("field API *api.Client", "Client")
assert(page.anchor == "Client" and page.package_path == "example.com/hoverchain-tests/model")
page = follow("List() *Request", "List")
assert(page.anchor == "Client.List")
assert(page.location.uri:find("/model/client.go", 1, true))
page = follow("List() *Request", "Request")
assert(page.anchor == "Request")
page = follow("Do() *http.Response", "Do")
assert(page.anchor == "Request.Do")
page = follow("See [http.Response]", "Response")
assert(page.anchor == "Response" and page.package_path == "net/http")
local depth = #hc.state.pages
hc.back()
assert(#hc.state.pages == depth - 1 and hc.state.pages[#hc.state.pages].anchor == "Request.Do")
hc.close()
assert(api.nvim_get_current_buf() == origin)
assert(not vim.bo[origin].modified, "source file was modified")

-- Standard-library methods, including source imports with internal packages.
place(origin, "\tHTTP", "HTTP")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "HTTP field hover failed")
page = follow("field HTTP *http.Client", "Client")
assert(page.anchor == "Client" and page.package_path == "net/http")
page = follow("Do(req *Request)", "Do")
assert(page.anchor == "Client.Do")
page = follow("Do(req *Request)", "Request")
assert(page.anchor == "Request" and page.package_path == "net/http")

-- After gd into a dependency, new hover sessions must keep their query file
-- inside the importing workspace, never inside GOROOT or a module cache.
place(hc.state.buf, "type Request struct", "Request")
hc.definition()
wait(function()
  return hc.state.win == nil
end, "dependency gd failed")
local dependency = api.nvim_get_current_buf()
assert(api.nvim_buf_get_name(dependency):find("/net/http/request.go", 1, true))
vim.lsp.buf_attach_client(dependency, id)
place(dependency, "type Request struct", "Request")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "dependency source hover failed")
assert(api.nvim_get_current_buf() == dependency, "dependency hover stole focus")
page = follow("Clone(ctx context.Context) *Request", "Clone")
assert(page.anchor == "Request.Clone")
local dependency_probe = vim.uri_to_fname(hc.state.session.probe_uri)
assert(vim.fs.dirname(dependency_probe) == fixtures, "query file escaped importing workspace")
assert(vim.uv.fs_stat(dependency_probe) == nil, "query file was written to disk")
assert(not vim.bo[dependency].modified, "dependency source was modified")
hc.close()
vim.cmd.edit(fixtures .. "/main.go")

-- Promoted methods must resolve to their actual declaring receiver.
place(origin, "_ = b.API", "API")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "API hover failed")
follow("field API *api.Client", "Client")
page = follow("Promoted() int", "Promoted")
assert(page.anchor == "Embedded.Promoted")
hc.close()

-- gd jumps from a hover into the real source, then cleans up the lookup document.
place(origin, "_ = b.API", "API")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "API hover failed")
follow("field API *api.Client", "Client")
local probe = hc.state.session.probe_uri
place(hc.state.buf, "List() *Request", "List")
hc.definition()
wait(function()
  return #hc.state.pages == 0
end, "gd did not close hover")
assert(api.nvim_buf_get_name(0):find("/model/client.go", 1, true))
assert(api.nvim_get_current_line():find("func (*Client) List", 1, true))
assert(vim.uv.fs_stat(vim.uri_to_fname(probe)) == nil, "lookup file was written to disk")

-- Closing while a request is pending must not resurrect the popup.
vim.cmd.edit(fixtures .. "/main.go")
place(origin, "_ = b.API", "API")
hc.hover()
hc.close()
vim.wait(300, function()
  return false
end, 20)
assert(#hc.state.pages == 0 and hc.state.win == nil)
assert(not vim.bo[origin].modified)

-- Two presses before the first response still enter the same preview.
hc.hover()
local pending_session = hc.state.session
hc.hover()
assert(hc.state.session == pending_session, "second K restarted the pending request")
wait(function()
  return #hc.state.pages == 1 and api.nvim_get_current_win() == hc.state.win
end, "rapid KK did not focus hover")
hc.close()

-- Import aliases in an unsaved buffer must be used without writing that buffer.
local before = api.nvim_buf_get_lines(origin, 0, -1, false)
local unsaved = {}
for i, line in ipairs(before) do
  unsaved[i] = line:gsub('api "example.com', 'unsavedapi "example.com'):gsub("%*api%.Client", "*unsavedapi.Client")
end
api.nvim_buf_set_lines(origin, 0, -1, false, unsaved)
place(origin, "_ = b.API", "API")
hc.hover()
wait(function()
  return #hc.state.pages == 1
end, "unsaved buffer hover failed")
page = follow("field API *unsavedapi.Client", "Client")
assert(page.package_path == "example.com/hoverchain-tests/model")
hc.close()
assert(vim.bo[origin].modified and api.nvim_buf_get_lines(origin, 0, -1, false)[4] == unsaved[4])
assert(vim.fn.readfile(fixtures .. "/main.go")[4] == before[4], "unsaved source was written to disk")
api.nvim_buf_set_lines(origin, 0, -1, false, before)
vim.bo[origin].modified = false
client:stop(true)
print(
  "integration: passed (nested types, methods, fields, stdlib, aliases, promoted methods, history, gd, cancellation, unsaved source)"
)
vim.cmd("qa!")
