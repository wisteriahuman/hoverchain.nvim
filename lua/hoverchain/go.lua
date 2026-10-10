local M = {}
local ident = "[%w_\128-\255]"
local builtins = {}
for name in
  ("any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr append cap clear close complex copy delete imag len make max min new panic print println real recover"):gmatch(
    "%S+"
  )
do
  builtins[name] = true
end

-- Only lex the package/import header. Comments and strings may contain Go keywords.
function M.header(source)
  local pos = 1
  local function token()
    while pos <= #source do
      local rest = source:sub(pos)
      local space = rest:match("^%s+")
      if space then
        pos = pos + #space
      elseif rest:sub(1, 2) == "//" then
        pos = (source:find("\n", pos, true) or #source) + 1
      elseif rest:sub(1, 2) == "/*" then
        pos = (source:find("*/", pos + 2, true) or (#source - 1)) + 2
      else
        local word = rest:match("^" .. ident .. "+")
        if word then
          pos = pos + #word
          return word
        end
        local first = rest:sub(1, 1)
        if first == '"' or first == "`" then
          local start = pos
          pos = pos + 1
          while pos <= #source do
            local char = source:sub(pos, pos)
            pos = pos + 1
            if char == first then
              break
            elseif char == "\\" and first == '"' then
              pos = pos + 1
            end
          end
          return source:sub(start, pos - 1)
        end
        pos = pos + 1
        return first
      end
    end
  end
  local package_name, imports = nil, {}
  local t = token()
  if t ~= "package" then
    return { imports = imports }
  end
  package_name = token()
  t = token()
  while t == ";" or t == "import" do
    if t == ";" then
      t = token()
    else
      t = token()
      local block = t == "("
      if block then
        t = token()
      end
      while t and t ~= ")" do
        if t == ";" then
          t = token()
        else
          local alias
          if t:sub(1, 1) ~= '"' and t:sub(1, 1) ~= "`" then
            alias, t = t, token()
          end
          if not t or (t:sub(1, 1) ~= '"' and t:sub(1, 1) ~= "`") then
            break
          end
          imports[#imports + 1] = { alias = alias, path = t:sub(2, -2), spec = (alias and alias .. " " or "") .. t }
          t = token()
          if not block then
            break
          end
        end
      end
      if block and t == ")" then
        t = token()
      end
    end
  end
  return { package_name = package_name, imports = imports }
end

function M.contents(result)
  return table.concat(vim.lsp.util.convert_input_to_markdown_lines(result.contents), "\n")
end

function M.metadata(markdown)
  local path, anchor
  for url in markdown:gmatch("https?://pkg%.go%.dev/([^%s%)]+)") do
    local p, a = url:match("^(.-)#(.+)$")
    if p then
      path, anchor = p:gsub("@[^/]+", ""), a
    end
  end
  return path, anchor
end

local function file_link(url)
  local uri, row, col = url:match("^(file://.-)#(%d+),(%d+)$")
  if uri then
    return { uri = uri, range = { start = { line = tonumber(row) - 1, character = tonumber(col) - 1 } } }
  end
end

function M.target(page, line, col)
  -- gopls >= 0.21 puts exact source locations into documentation links.
  local start = 1
  while true do
    local first, last, _, url = line:find("%[([^%]]+)%]%(([^%)]+)%)", start)
    if not first then
      break
    end
    if col + 1 >= first and col + 1 <= last then
      local loc = file_link(url)
      if loc then
        return { location = loc }
      end
    end
    start = last + 1
  end
  local first, last = col + 1, col + 1
  if not line:sub(first, first):match(ident) then
    return nil, "型名・メソッド名にカーソルを置いてください"
  end
  while first > 1 and line:sub(first - 1, first - 1):match(ident) do
    first = first - 1
  end
  while last < #line and line:sub(last + 1, last + 1):match(ident) do
    last = last + 1
  end
  local word = line:sub(first, last)
  local qualifier = line:sub(1, first - 1):match("(" .. ident .. "+)%.%s*$")
  if qualifier then
    if qualifier == page.header.package_name then
      return { symbol = word, own_package = true }
    end
    return { symbol = qualifier .. "." .. word }
  end
  if builtins[word] then
    return { symbol = word }
  end
  local receiver, method_start, method = line:match("^%s*func%s+%((.-)%)%s*()(" .. ident .. "+)")
  if method == word and first == method_start then
    receiver = receiver:gsub("%b[]", ""):match("(" .. ident .. "+)%s*$")
    if receiver then
      return { symbol = receiver .. "." .. word, own_package = true }
    end
  end
  local owner = page.type_name or (page.anchor or ""):match("^([^%.]+)%.")
  local field_start, field = line:match("^%s*field%s+()(" .. ident .. "+)")
  if not field then
    field_start, field = line:match("^%s*()(" .. ident .. "+)%s+[^=]")
  end
  if owner and field == word and first == field_start and word ~= "type" and word ~= "func" then
    return { symbol = owner .. "." .. word, own_package = true }
  end
  return { symbol = word, own_package = true }
end

function M.probe(session, page, target)
  local specs, seen = {}, {}
  for _, import in ipairs(page.header.imports) do
    -- Blank imports do not introduce names; C requires a real cgo preamble.
    if import.alias ~= "_" and import.path ~= "C" then
      specs[#specs + 1] = import.spec
      seen[import.alias or ""] = true
    end
  end
  local symbol = target.symbol
  if target.own_package and page.package_path and page.package_path ~= "builtin" and not page.local_package then
    local alias = "hoverchain_target"
    while seen[alias] do
      alias = alias .. "_"
    end
    specs[#specs + 1] = alias .. " " .. vim.json.encode(page.package_path)
    symbol = alias .. "." .. symbol
  end
  local lines = { "package " .. session.package_name }
  if #specs > 0 then
    vim.list_extend(lines, { "import (", table.concat(specs, "\n"), ")" })
  end
  lines[#lines + 1] = "// [" .. symbol .. "]"
  local text = table.concat(lines, "\n") .. "\n"
  local last_word = symbol:match("()" .. ident .. "+$")
  local byte_index = 4 + last_word - 1
  local encoding = session.client and session.client.offset_encoding or "utf-16"
  local character = vim.str_utfindex("// [" .. symbol .. "]", encoding, byte_index, false)
  return text, { line = select(2, text:gsub("\n", "")) - 1, character = character }
end

return M
