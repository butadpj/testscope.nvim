local M = {}
local api = vim.api
local ui = require("testscope.presentation")
local defaults = {
  node = "node",
  go = "go",
  typescript_path = nil,
  width = 0.92,
  height = 0.8,
  preview = true,
  preview_min_width = 160,
  border = "rounded",
}
local config = vim.deepcopy(defaults)
local state
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
local ns = api.nvim_create_namespace("testscope")
local selection_ns = api.nvim_create_namespace("testscope_selection")
local map_ns = api.nvim_create_namespace("testscope_map")
local render, layout, toggle_preview, jump

local function valid_window(win)
  return win and api.nvim_win_is_valid(win)
end

local function scratch()
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  return buf
end

local function set_lines(buf, lines)
  if not api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function style(win)
  vim.wo[win].winhighlight = "Normal:TestscopeNormal,NormalFloat:TestscopeNormal,FloatBorder:TestscopeBorder,FloatTitle:TestscopeTitle,FloatFooter:TestscopeMuted,LineNr:TestscopeMuted"
  vim.wo[win].winblend = 0
  vim.wo[win].foldenable = false
  vim.wo[win].cursorline = false
  vim.wo[win].signcolumn = "no"
end

local function selected(s)
  if not valid_window(s.tree_win) then return nil end
  return s.rows[api.nvim_win_get_cursor(s.tree_win)[1]]
end

local function span_for(s, id)
  for index, span in ipairs(s.entries) do
    if span.entry.id == id then return span, index end
  end
end

local function preview(s, force)
  if state ~= s or not valid_window(s.preview_win) then return end
  local entry = selected(s)
  if not entry or (not force and s.preview_id == entry.id) then return end
  s.preview_id = entry.id
  local first, last = entry.line, math.min(entry.end_line, #s.source)
  local lines = {}
  for line = first, last do lines[#lines + 1] = s.source[line] end
  set_lines(s.preview_buf, ui.dedent(lines))
  api.nvim_win_set_config(s.preview_win, {
    title = " SOURCE · L" .. first .. "–" .. last .. " ",
    title_pos = "left",
  })
  vim.wo[s.preview_win].number = true
  vim.wo[s.preview_win].relativenumber = false
  vim.wo[s.preview_win].numberwidth = math.max(3, #tostring(last) + 1)
  vim.wo[s.preview_win].statuscolumn = "%=%{v:virtnum == 0 ? v:lnum + " .. (first - 1) .. " : ''} "
  api.nvim_win_set_cursor(s.preview_win, { 1, 0 })
  api.nvim_buf_clear_namespace(s.preview_buf, ns, 0, -1)
  if #lines > 0 then
    api.nvim_buf_set_extmark(s.preview_buf, ns, 0, 0, { line_hl_group = "TestscopeSelected" })
  end
end

local function update_selection(s)
  if state ~= s or not valid_window(s.tree_win) then return end
  local entry = selected(s)
  api.nvim_buf_clear_namespace(s.tree_buf, selection_ns, 0, -1)
  api.nvim_buf_clear_namespace(s.tree_buf, map_ns, 0, -1)
  if not entry then return end
  local span, index = span_for(s, entry.id)
  if not span then return end
  s.selected_id = entry.id
  for row = span.first, span.last do
    api.nvim_buf_set_extmark(s.tree_buf, selection_ns, row - 1, 0, {
      line_hl_group = "TestscopeSelected",
      priority = 200,
      virt_text = { { "▎", "TestscopeMarker" } },
      virt_text_pos = "overlay",
    })
  end
  -- A navigation map, never a pass/fail indicator.
  local slots = math.min(12, #s.entries)
  local position = #s.entries == 1 and 1 or math.floor((index - 1) * (slots - 1) / (#s.entries - 1)) + 1
  local chunks = { { "MAP ", "TestscopeMuted" } }
  for slot = 1, slots do
    chunks[#chunks + 1] = { slot == position and "● " or "· ", slot == position and "TestscopeMarker" or "TestscopeGuide" }
  end
  chunks[#chunks + 1] = { index .. "/" .. #s.entries, "TestscopeMuted" }
  local map_width = 4 + slots * 2 + #tostring(index) + #tostring(#s.entries) + 1
  local name_width = vim.fn.strdisplaywidth(s.lines[1] or "")
  if s.tree_width >= name_width + map_width + 5 then
    api.nvim_buf_set_extmark(s.tree_buf, map_ns, 0, 0, {
      virt_text = chunks,
      virt_text_win_col = s.tree_width - map_width - 2,
    })
  end
  preview(s)
end

local function cursor_to(s, span)
  if span then api.nvim_win_set_cursor(s.tree_win, { span.first, span.column }) end
  update_selection(s)
end

render = function(s, keep_id)
  if state ~= s or not valid_window(s.tree_win) then return end
  local current = selected(s)
  keep_id = keep_id or (current and current.id) or s.selected_id
  local highlights
  s.lines, s.rows, s.entries, highlights = ui.compose(s)
  set_lines(s.tree_buf, s.lines)
  api.nvim_buf_clear_namespace(s.tree_buf, ns, 0, -1)
  for _, highlight in ipairs(highlights) do
    api.nvim_buf_add_highlight(s.tree_buf, ns, highlight[2], highlight[1], highlight[3], highlight[4])
  end
  local target = keep_id and span_for(s, keep_id)
  if not target then
    for _, span in ipairs(s.entries) do
      if span.entry.kind ~= "suite" then target = span break end
    end
  end
  target = target or s.entries[1]
  if target then cursor_to(s, target) else api.nvim_win_set_cursor(s.tree_win, { math.min(5, #s.lines), 0 }) end
end

local function return_to_list(s)
  if state ~= s then return end
  if s.preview_mode == "overlay" then
    s.preview_forced = false
    layout(s)
  end
  if valid_window(s.tree_win) then api.nvim_set_current_win(s.tree_win) end
end

local function open_preview(s, window_config, mode)
  if valid_window(s.preview_win) then
    api.nvim_win_set_config(s.preview_win, window_config)
  else
    s.preview_buf = scratch()
    vim.bo[s.preview_buf].filetype = s.filetype
    s.preview_win = api.nvim_open_win(s.preview_buf, false, window_config)
    style(s.preview_win)
    vim.wo[s.preview_win].wrap = true
    vim.wo[s.preview_win].linebreak = true
    vim.wo[s.preview_win].breakindent = true
    vim.wo[s.preview_win].breakindentopt = "shift:2"
    vim.wo[s.preview_win].scrolloff = 0
    local opts = { buffer = s.preview_buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", M.close, opts)
    vim.keymap.set("n", "<Esc>", function()
      if s.preview_mode == "overlay" then return_to_list(s) else M.close() end
    end, opts)
    vim.keymap.set("n", "<Tab>", function() return_to_list(s) end, opts)
    vim.keymap.set("n", "p", function() toggle_preview(s) end, opts)
    vim.keymap.set("n", "<CR>", function()
      -- Jump uses the outline's selection, even while scrolling the source.
      jump(s)
    end, opts)
  end
  s.preview_mode, s.preview_id = mode, nil
end

layout = function(s)
  if state ~= s or not valid_window(s.tree_win) then return end
  local keep = selected(s)
  local width = math.max(24, math.min(vim.o.columns - 4, math.floor(vim.o.columns * config.width)))
  local height = math.max(4, math.min(vim.o.lines - 6, math.floor(vim.o.lines * config.height)))
  if s.focus then width, height = vim.o.columns - 4, vim.o.lines - 6 end
  local row = math.max(0, math.floor((vim.o.lines - height - 4) / 2))
  local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
  local side = s.want_preview and width >= config.preview_min_width
  s.window_width = width
  s.tree_width = side and math.floor((width - 2) * 0.6) or width
  if not side and s.data then
    local content = ui.compose(s)
    height = math.min(height, math.max(10, #content + 1))
    row = math.max(0, math.floor((vim.o.lines - height - 4) / 2))
  end
  local window_config = {
    relative = "editor", row = row, col = col, width = s.tree_width, height = height,
    style = "minimal", border = config.border, zindex = 50,
    title = s.focus and " TESTSCOPE / FOCUS " or " TESTSCOPE ",
    title_pos = "left", footer = ui.footer(s.tree_width), footer_pos = "left",
  }
  api.nvim_win_set_config(s.tree_win, window_config)
  if s.focus then
    local backdrop = {
      relative = "editor", row = 0, col = 0, width = vim.o.columns,
      height = math.max(1, vim.o.lines - 2), style = "minimal",
      focusable = false, zindex = 40,
    }
    if valid_window(s.backdrop_win) then
      api.nvim_win_set_config(s.backdrop_win, backdrop)
    else
      s.backdrop_buf = scratch()
      s.backdrop_win = api.nvim_open_win(s.backdrop_buf, false, backdrop)
      style(s.backdrop_win)
    end
  elseif valid_window(s.backdrop_win) then
    api.nvim_win_close(s.backdrop_win, true)
    s.backdrop_win = nil
  end
  if side or s.preview_forced then
    local mode = side and "split" or "overlay"
    local preview_config = {
      relative = "editor", row = row, col = side and (col + s.tree_width + 2) or col,
      width = side and (width - s.tree_width - 2) or width, height = height,
      style = "minimal", border = config.border, zindex = 60,
      title = " SOURCE ", title_pos = "left",
      footer = side and " Tab tests  Enter open  q close " or " Tab / Esc tests  Enter open ",
      footer_pos = "left",
    }
    open_preview(s, preview_config, mode)
  elseif valid_window(s.preview_win) then
    api.nvim_win_close(s.preview_win, true)
    s.preview_win, s.preview_mode, s.preview_id = nil, nil, nil
  end
  if valid_window(s.help_win) then
    api.nvim_win_close(s.help_win, true)
    s.help_win = nil
  end
  render(s, keep and keep.id)
  preview(s, true)
end

toggle_preview = function(s)
  if state ~= s then return end
  if valid_window(s.preview_win) then
    if s.preview_mode == "split" then s.want_preview = false else s.preview_forced = false end
    layout(s)
    api.nvim_set_current_win(s.tree_win)
  else
    if s.window_width >= config.preview_min_width then s.want_preview = true else s.preview_forced = true end
    layout(s)
    if s.preview_mode == "overlay" then api.nvim_set_current_win(s.preview_win) end
  end
end

local function refresh(s)
  if state ~= s or not api.nvim_buf_is_valid(s.source_buf) then return end
  if s.job then vim.fn.jobstop(s.job) end
  s.generation = s.generation + 1
  local generation = s.generation
  s.source = api.nvim_buf_get_lines(s.source_buf, 0, -1, false)
  s.tick = api.nvim_buf_get_changedtick(s.source_buf)
  s.loading, s.error, s.data, s.preview_id = true, nil, nil, nil
  render(s)
  local stdout, stderr = {}, {}
  local argv
  if s.language == "go" then
    argv = { config.go, "run", root .. "/scripts/scan-go.go", "--", s.path }
  else
    argv = { config.node, root .. "/scripts/scan.cjs", s.path }
    if config.typescript_path then argv[#argv + 1] = vim.fn.expand(config.typescript_path) end
  end
  s.job = vim.fn.jobstart(argv, {
    cwd = root,
    env = s.language == "go" and { GOWORK = "off", GOFLAGS = "", GOTOOLCHAIN = "local", GO111MODULE = "off" } or nil,
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, lines) stdout = lines end,
    on_stderr = function(_, lines) stderr = lines end,
    on_exit = function(_, code)
      vim.schedule(function()
        if state ~= s or generation ~= s.generation then return end
        s.job, s.loading = nil, false
        if code ~= 0 then
          s.error = table.concat(stderr, " "):gsub("%s+$", "")
          if s.error == "" then s.error = "Parser exited with code " .. code .. "." end
        end
        if not s.error then
          local ok, result = pcall(vim.json.decode, table.concat(stdout, "\n"))
          if ok and type(result) == "table" and result.roots then s.data = result else s.error = "Could not read the parser response." end
        end
        layout(s)
      end)
    end,
  })
  if s.job <= 0 then
    s.job, s.loading, s.error = nil, false, "Could not start " .. (s.language == "go" and "Go" or "Node.js") .. ". Check its executable in setup()."
    render(s)
    return
  end
  vim.fn.chansend(s.job, table.concat(s.source, "\n"))
  vim.fn.chanclose(s.job, "stdin")
end

function M.close()
  local s = state
  if not s then return end
  state = nil
  if s.job then vim.fn.jobstop(s.job) end
  if s.augroup then api.nvim_del_augroup_by_id(s.augroup) end
  for _, win in ipairs({ s.help_win or false, s.preview_win or false, s.tree_win or false, s.backdrop_win or false }) do
    if win and valid_window(win) then api.nvim_win_close(win, true) end
  end
  if valid_window(s.source_win) then api.nvim_set_current_win(s.source_win) end
end

jump = function(s)
  local entry = selected(s)
  if not entry then return end
  if not api.nvim_buf_is_valid(s.source_buf) then M.close() return end
  if api.nvim_buf_get_changedtick(s.source_buf) ~= s.tick then
    vim.notify("Testscope: source changed; refreshing before jumping.", vim.log.levels.INFO)
    refresh(s)
    return
  end
  M.close()
  if not valid_window(s.source_win) then s.source_win = api.nvim_get_current_win() end
  api.nvim_win_set_buf(s.source_win, s.source_buf)
  api.nvim_win_set_cursor(s.source_win, { entry.line, entry.column })
  api.nvim_win_call(s.source_win, function() vim.cmd("normal! zvzz") end)
end

local function navigate(s, delta)
  if #s.entries == 0 then return end
  local current = selected(s)
  local _, index = span_for(s, current and current.id or s.selected_id)
  index = math.max(1, math.min(#s.entries, (index or 1) + delta))
  cursor_to(s, s.entries[index])
end

local function page(s, direction)
  local row = api.nvim_win_get_cursor(s.tree_win)[1]
  local target = row + direction * math.max(1, math.floor(api.nvim_win_get_height(s.tree_win) / 2))
  local candidate = direction > 0 and s.entries[#s.entries] or s.entries[1]
  for _, span in ipairs(s.entries) do
    if direction > 0 and span.first >= target then candidate = span break end
    if direction < 0 and span.first <= target then candidate = span end
  end
  cursor_to(s, candidate)
end

local function help(s)
  if valid_window(s.help_win) then
    api.nvim_win_close(s.help_win, true)
    s.help_win = nil
    api.nvim_set_current_win(s.tree_win)
    return
  end
  local width = math.min(s.tree_width, 58)
  local lines = { "" }
  for _, text in ipairs({
    "BROWSE",
    "j / k        Previous / next test",
    "Enter        Open declaration",
    "Tab / Space  Fold or unfold group",
    "h / l        Parent or first child",
    "zM / zR      Fold or unfold all",
    "/            Filter tests",
    "c            Clear filter",
    "p / P        Toggle / focus source",
    "f            Focus mode for screenshots",
    "r            Refresh unsaved source",
    "y            Copy test name",
    "q            Close browser",
  }) do
    local wrapped = vim.fn.strdisplaywidth(text) <= width - 4 and { text } or ui.wrap(text, width - 4)
    for _, line in ipairs(wrapped) do lines[#lines + 1] = "  " .. line end
  end
  lines[#lines + 1] = ""
  local height = math.min(#lines, vim.o.lines - 6)
  s.help_buf = scratch()
  set_lines(s.help_buf, lines)
  s.help_win = api.nvim_open_win(s.help_buf, true, {
    relative = "editor", row = math.max(0, math.floor((vim.o.lines - height - 4) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
    width = width, height = height, style = "minimal", border = config.border,
    zindex = 70, title = " KEYS ", footer = " Esc / ? back ", footer_pos = "left",
  })
  style(s.help_win)
  for _, key in ipairs({ "<Esc>", "?", "<Tab>" }) do
    vim.keymap.set("n", key, function() help(s) end, { buffer = s.help_buf, silent = true })
  end
  vim.keymap.set("n", "q", M.close, { buffer = s.help_buf, silent = true })
end

function M.open(options)
  options = options or {}
  if state then
    if valid_window(state.tree_win) then
      if options.focus then state.focus = true layout(state) end
      api.nvim_set_current_win(state.tree_win)
      return
    end
    M.close()
  end
  local source_buf = api.nvim_get_current_buf()
  local path = api.nvim_buf_get_name(source_buf)
  local language = path:match("%.go$") and "go" or "javascript"
  if path == "" or (language ~= "go" and not path:match("%.[cm]?[jt]sx?$")) then
    vim.notify("Testscope: open a named Go, TypeScript, or JavaScript buffer first.", vim.log.levels.WARN)
    return
  end
  if vim.fn.executable(config[language == "go" and "go" or "node"]) ~= 1 then
    vim.notify("Testscope: " .. (language == "go" and "Go was not found. Set go" or "Node.js was not found. Set node") .. " in setup().", vim.log.levels.ERROR)
    return
  end
  if vim.o.columns < 32 or vim.o.lines < 12 then
    vim.notify("Testscope: the terminal needs at least 32 columns and 12 rows.", vim.log.levels.WARN)
    return
  end
  ui.colors()
  local s = {
    source_buf = source_buf, source_win = api.nvim_get_current_win(), path = path, language = language,
    filetype = vim.bo[source_buf].filetype, source = {}, collapsed = {}, rows = {},
    entries = {}, query = "", generation = 0, want_preview = config.preview,
    focus = options.focus or false, loading = true,
  }
  state = s
  s.tree_buf = scratch()
  vim.bo[s.tree_buf].filetype = "testscope"
  s.tree_win = api.nvim_open_win(s.tree_buf, true, {
    relative = "editor", row = 1, col = 1, width = 24, height = 4,
    style = "minimal", border = config.border,
  })
  style(s.tree_win)
  vim.wo[s.tree_win].wrap = false
  vim.wo[s.tree_win].scrolloff = 2
  local function map(keys, action)
    for _, key in ipairs(type(keys) == "table" and keys or { keys }) do
      vim.keymap.set("n", key, action, { buffer = s.tree_buf, silent = true, nowait = true })
    end
  end
  map({ "q", "<Esc>" }, M.close)
  map("<CR>", function() jump(s) end)
  map({ "j", "<Down>" }, function() navigate(s, vim.v.count1) end)
  map({ "k", "<Up>" }, function() navigate(s, -vim.v.count1) end)
  map("gg", function() cursor_to(s, s.entries[1]) end)
  map("G", function() cursor_to(s, s.entries[#s.entries]) end)
  map("<C-d>", function() page(s, 1) end)
  map("<C-u>", function() page(s, -1) end)
  map({ "<Tab>", "za", "<Space>" }, function()
    local entry = selected(s)
    if entry and #entry.children > 0 then
      s.collapsed[entry.id] = not s.collapsed[entry.id]
      render(s)
    end
  end)
  map("h", function()
    local entry = selected(s)
    if not entry then return end
    if #entry.children > 0 and not s.collapsed[entry.id] then
      s.collapsed[entry.id] = true
      render(s)
      return
    end
    for _, span in ipairs(s.entries) do
      for _, child in ipairs(span.entry.children) do
        if child.id == entry.id then cursor_to(s, span) return end
      end
    end
  end)
  map("l", function()
    local entry = selected(s)
    if entry and #entry.children > 0 then
      if s.collapsed[entry.id] then s.collapsed[entry.id] = false render(s) else navigate(s, 1) end
    end
  end)
  map("zM", function()
    local function collapse(entries)
      for _, entry in ipairs(entries) do
        if #entry.children > 0 then s.collapsed[entry.id] = true collapse(entry.children) end
      end
    end
    if s.data then collapse(s.data.roots) render(s) end
  end)
  map("zR", function() s.collapsed = {} render(s) end)
  map("/", function()
    vim.ui.input({ prompt = "Filter tests: ", default = s.query }, function(value)
      if state == s and value ~= nil then s.query = value render(s) end
    end)
  end)
  map("c", function() s.query = "" render(s) end)
  map("r", function() refresh(s) end)
  map("p", function() toggle_preview(s) end)
  map("P", function()
    if not valid_window(s.preview_win) then toggle_preview(s) end
    if valid_window(s.preview_win) then api.nvim_set_current_win(s.preview_win) end
  end)
  map("f", function() s.focus = not s.focus layout(s) end)
  map("?", function() help(s) end)
  map("y", function()
    local entry = selected(s)
    if entry then vim.fn.setreg('"', entry.name) vim.notify("Testscope: copied test name.") end
  end)
  s.augroup = api.nvim_create_augroup("TestscopeBrowser", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = s.augroup, buffer = s.tree_buf,
    callback = function() update_selection(s) end,
  })
  api.nvim_create_autocmd("VimResized", { group = s.augroup, callback = function() layout(s) end })
  api.nvim_create_autocmd("ColorScheme", { group = s.augroup, callback = function() ui.colors(true) end })
  api.nvim_create_autocmd("BufWritePost", { group = s.augroup, buffer = source_buf, callback = function() refresh(s) end })
  api.nvim_create_autocmd("BufWipeout", { group = s.augroup, buffer = source_buf, callback = M.close })
  api.nvim_create_autocmd("WinClosed", {
    group = s.augroup, pattern = tostring(s.tree_win),
    callback = function() vim.schedule(function() if state == s then M.close() end end) end,
  })
  layout(s)
  refresh(s)
end

function M.setup(options)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), options or {})
end

return M
