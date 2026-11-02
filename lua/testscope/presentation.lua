local M = {}
local api, fn = vim.api, vim.fn

function M.clean(text)
  return tostring(text):gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("%z", "\\0"):gsub("[%c]", "?")
end

-- Work in display cells, keeping wide characters and combining marks intact.
local function take(text, width)
  local count = 0
  for index = 1, fn.strchars(text) do
    if fn.strdisplaywidth(fn.strcharpart(text, 0, index)) > width then break end
    count = index
  end
  count = math.max(1, count)
  return fn.strcharpart(text, 0, count), fn.strcharpart(text, count)
end

function M.wrap(text, width)
  width = math.max(2, width)
  local lines, line = {}, ""
  for word in M.clean(text):gmatch("%S+") do
    if line ~= "" and fn.strdisplaywidth(line .. " " .. word) > width then
      lines[#lines + 1], line = line, ""
    end
    while fn.strdisplaywidth(word) > width do
      local part
      part, word = take(word, width)
      lines[#lines + 1] = part
    end
    if word ~= "" then line = line == "" and word or (line .. " " .. word) end
  end
  lines[#lines + 1] = line
  return lines
end

local function blend(first, second, amount)
  local value = 0
  for _, shift in ipairs({ 16, 8, 0 }) do
    local a = math.floor(first / 2 ^ shift) % 256
    local b = math.floor(second / 2 ^ shift) % 256
    value = value + math.floor(a * amount + b * (1 - amount) + 0.5) * 2 ^ shift
  end
  return value
end

function M.colors(force)
  local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
  local directory = api.nvim_get_hl(0, { name = "Directory", link = false })
  local light = vim.o.background == "light"
  local bg = normal.bg or (light and 0xf8fafc or 0x151a23)
  local fg = normal.fg or (light and 0x1e293b or 0xe2e8f0)
  local accent = directory.fg or (light and 0x2563eb or 0x93c5fd)
  local groups = {
    Normal = { bg = bg, fg = fg },
    Border = { bg = bg, fg = blend(fg, bg, 0.32) },
    Title = { bg = bg, fg = accent, bold = true },
    Suite = { fg = accent, bold = true },
    Test = { fg = fg },
    Case = { fg = fg },
    Muted = { fg = blend(fg, bg, 0.65) },
    Guide = { fg = blend(fg, bg, 0.28) },
    Skip = { fg = light and 0x956214 or 0xe7b568 },
    Only = { fg = accent },
    Selected = { bg = blend(accent, bg, light and 0.12 or 0.18) },
    Marker = { fg = accent, bold = true },
  }
  for name, value in pairs(groups) do
    value.default = not force
    api.nvim_set_hl(0, "Testscope" .. name, value)
  end
end

function M.footer(width)
  if width < 48 then return " Enter · / · p · ? " end
  if width < 72 then return " Enter open  / filter  p source  ? help " end
  return " Enter open  / filter  p source  f focus  ? help "
end

local function prefixes(depth, rails, last, icon)
  local base = "  "
  for _, connected in ipairs(rails) do base = base .. (connected and "│  " or "   ") end
  if depth == 0 then return base .. icon .. " ", base .. "  " end
  return base .. (last and "└─ " or "├─ ") .. icon .. " ", base .. (last and "   " or "│  ") .. "  "
end

function M.compose(s)
  local data = s.data or { roots = {}, declarations = 0, cases = 0, unresolved = 0, diagnostics = {} }
  local width = s.tree_width
  local suites = 0
  local function count(entries)
    for _, entry in ipairs(entries) do
      if entry.kind == "suite" then suites = suites + 1 end
      count(entry.children)
    end
  end
  count(data.roots)
  local summary = data.declarations .. (data.declarations == 1 and " test" or " tests")
  if data.cases ~= data.declarations then summary = summary .. " · " .. data.cases .. " static cases" end
  summary = summary .. " · " .. suites .. (suites == 1 and " suite" or " suites")
  if s.language == "go" then
    summary = #data.roots .. (#data.roots == 1 and " test" or " tests") .. " · " .. data.cases .. " outlined cases"
  end
  if data.unresolved > 0 then summary = summary .. " · " .. data.unresolved .. " dynamic" end
  local lines = { "  " .. fn.fnamemodify(s.path, ":t"), "  " .. summary, "  " .. string.rep("─", math.max(1, width - 4)), "" }
  -- Even the smallest supported terminal keeps metadata inside the pane.
  lines[1] = M.wrap(lines[1], width - 4)[1]
  lines[1] = "  " .. lines[1]
  lines[2] = "  " .. M.wrap(summary, width - 4)[1]
  if s.query ~= "" then lines[4] = "  / " .. M.wrap(s.query, width - 8)[1] .. "  ×" end
  local rows, entries, highlights = {}, {}, {
    { 0, "TestscopeTitle", 0, -1 }, { 1, "TestscopeMuted", 0, -1 }, { 2, "TestscopeGuide", 0, -1 }, { 3, "TestscopeMuted", 0, -1 },
  }
  local query = s.query:lower()
  local function matches(entry, ancestors)
    local path = ancestors .. " " .. entry.name .. " " .. (entry.annotation or "")
    if query == "" or path:lower():find(query, 1, true) then return true end
    for _, child in ipairs(entry.children) do if matches(child, path) then return true end end
    return false
  end
  local function append(nodes, depth, ancestors, rails, inherited)
    local visible = {}
    for _, entry in ipairs(nodes) do if matches(entry, ancestors) then visible[#visible + 1] = entry end end
    for index, entry in ipairs(visible) do
      local last = index == #visible
      local group = #entry.children > 0
      local collapsed = s.collapsed[entry.id] and query == ""
      local icon = group and (collapsed and "▸" or "▾") or (entry.kind == "case" and "·" or "○")
      local location = "L" .. entry.line
      local guide_limit = math.max(0, math.min(5, math.floor((width - #location - 12) / 3)))
      local displayed_rails = {}
      for guide = math.max(1, #rails - guide_limit + 1), #rails do displayed_rails[#displayed_rails + 1] = rails[guide] end
      local prefix, continuation = prefixes(depth, displayed_rails, last, icon)
      local flags, status = {}, inherited
      for _, modifier in ipairs(entry.modifiers) do
        if modifier ~= "each" and modifier ~= "for" then flags[#flags + 1] = modifier end
        if modifier == "skip" or modifier == "todo" then status = "Skip" elseif modifier == "only" and status ~= "Skip" then status = "Only" end
      end
      if entry.parameterized then flags[#flags + 1] = entry.expanded and (#entry.children .. " cases") or "dynamic cases" end
      if entry.dynamic then flags[#flags + 1] = "dynamic name" end
      local available = math.max(2, width - fn.strdisplaywidth(prefix) - #location - 4)
      local title = M.wrap(entry.name, available)
      local first = #lines + 1
      local hl = entry.kind == "suite" and "TestscopeSuite" or "TestscopeTest"
      for part, text in ipairs(title) do
        local lead = part == 1 and prefix or continuation
        local label = lead .. text
        if part == 1 then
          label = label .. string.rep(" ", math.max(2, width - fn.strdisplaywidth(label) - #location - 2)) .. location
        end
        lines[#lines + 1], rows[#lines + 1] = label, entry
        highlights[#highlights + 1] = { #lines - 1, hl, #lead, #lead + #text }
        highlights[#highlights + 1] = { #lines - 1, "TestscopeGuide", 0, #lead }
        if part == 1 then highlights[#highlights + 1] = { #lines - 1, "TestscopeMuted", #label - #location, -1 } end
      end
      if entry.annotation and entry.annotation ~= "" then
        for _, text in ipairs(M.wrap(entry.annotation, available - 2)) do
          lines[#lines + 1], rows[#lines + 1] = continuation .. "│ " .. text, entry
          highlights[#highlights + 1] = { #lines - 1, "TestscopeMuted", #continuation, -1 }
          highlights[#highlights + 1] = { #lines - 1, "TestscopeGuide", 0, #continuation }
        end
      end
      if #flags > 0 then
        for _, text in ipairs(M.wrap(table.concat(flags, " · "), available)) do
          lines[#lines + 1], rows[#lines + 1] = continuation .. text, entry
          highlights[#highlights + 1] = { #lines - 1, "Testscope" .. (status or "Muted"), #continuation, -1 }
          highlights[#highlights + 1] = { #lines - 1, "TestscopeGuide", 0, #continuation }
        end
      end
      entries[#entries + 1] = { entry = entry, first = first, last = #lines, column = #prefix }
      if group and not collapsed then
        local child_rails = vim.deepcopy(rails)
        if depth > 0 and #child_rails < 5 then child_rails[#child_rails + 1] = not last end
        append(entry.children, depth + 1, ancestors .. " " .. entry.name .. " " .. (entry.annotation or ""), child_rails, status)
      end
      if entry.kind ~= "case" and not last then
        lines[#lines + 1] = continuation:gsub("%s+$", "")
        highlights[#highlights + 1] = { #lines - 1, "TestscopeGuide", 0, -1 }
      end
    end
  end
  append(data.roots, 0, "", {}, nil)
  if #entries == 0 then
    local message = s.loading and "Parsing tests…" or s.error or (query ~= "" and "No matching tests." or "No test declarations found.")
    for _, text in ipairs(M.wrap(message, width - 4)) do lines[#lines + 1] = "  " .. text end
  end
  if #data.diagnostics > 0 then
    lines[#lines + 1] = ""
    for _, text in ipairs(M.wrap("Syntax errors: outline may be incomplete.", width - 4)) do
      lines[#lines + 1] = "  " .. text
      highlights[#highlights + 1] = { #lines - 1, "TestscopeSkip", 0, -1 }
    end
  end
  return lines, rows, entries, highlights
end

function M.dedent(lines)
  local indentation
  for _, line in ipairs(lines) do
    if line:find("%S") then
      local count = #(line:match("^ *") or "")
      indentation = math.min(indentation or count, count)
    end
  end
  if indentation and indentation > 0 then
    for index, line in ipairs(lines) do lines[index] = line:sub(indentation + 1) end
  end
  return lines
end

return M
