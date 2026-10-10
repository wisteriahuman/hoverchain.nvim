vim.opt.rtp:prepend(vim.fn.getcwd())
local go = require("hoverchain.go")
local header = go.header([[
/* import "wrong" */
package demo
// import "also-wrong"
import (
  alias "example.com/api/v3" // comment
  "net/http"
  _ "embed"
  . `fmt`
)
type T struct{}
]])
assert(header.package_name == "demo")
assert(#header.imports == 4)
assert(header.imports[1].alias == "alias")
assert(header.imports[1].path == "example.com/api/v3")
assert(header.imports[4].spec == ". `fmt`")
local page = { header = { package_name = "model", imports = {} }, type_name = "Client", anchor = "Client" }
local function target(line, word)
  local col = assert(line:find(word, 1, true)) - 1
  return assert(go.target(page, line, col))
end
assert(target("func (c *Client) List() *Request", "List").symbol == "Client.List")
assert(target("func (c *Client[T]) List() T", "List").symbol == "Client.List")
assert(target("func (Client) List() T", "List").symbol == "Client.List")
assert(target("HTTP *http.Client", "HTTP").symbol == "Client.HTTP")
assert(go.target(page, "Request *Request", 9).symbol == "Request")
assert(go.target(page, "func (c *Client) Client() *Client", 27).symbol == "Client")
assert(target("HTTP *http.Client", "http.Client").symbol == "http") -- cursor on package, not type
local loc = target("See [Response](file:///tmp/response.go#35,6).", "Response").location
assert(loc.uri == "file:///tmp/response.go")
assert(loc.range.start.line == 34 and loc.range.start.character == 5)
assert(target("func (c *Client) Do() int", "int").own_package == nil)
local path, anchor = go.metadata("[pkg.Type](https://pkg.go.dev/example.com/lib@v1.2.3/api#Type)")
assert(path == "example.com/lib/api" and anchor == "Type")
page.package_path = "example.com/model"
local text, position = go.probe({ package_name = "main" }, page, { symbol = "Client.List", own_package = true })
local lines = vim.split(text, "\n", { plain = true })
assert(lines[position.line + 1]:sub(position.character + 1, position.character + 1) == "L")
assert(text:find("hoverchain_target.Client.List", 1, true))
require("hoverchain").setup({ mock = true })
vim.cmd.Hoverchain()
local hc = require("hoverchain")
assert(vim.api.nvim_win_is_valid(hc.state.win))
hc.close()
assert(#hc.state.pages == 0)
print("unit: passed")
vim.cmd("qa!")
