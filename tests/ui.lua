-- Run from the plugin root: nvim --headless -u NONE -i NONE -l tests/ui.lua
local api = vim.api
local plugin = vim.fn.getcwd()
vim.opt.runtimepath:append(plugin)
vim.cmd("runtime plugin/testscope.lua")
vim.o.columns = 200
vim.o.lines = 48
vim.o.background = "light"
-- Simulate a transparent theme. The browser still needs an opaque, readable surface.
api.nvim_set_hl(0, "Normal", { fg = 0x1e293b })
api.nvim_set_hl(0, "NormalFloat", { link = "Normal" })
require("testscope").setup({ typescript_path = vim.env.TESTSCOPE_TYPESCRIPT })

local function lines(buf) return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") end
local function wait_for(predicate, message)
  if vim.wait(30000, predicate, 20) then return end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= "" then io.stderr:write(lines(api.nvim_win_get_buf(win)) .. "\n") end
  end
  error(message)
end
local function key(lhs)
  for _, map in ipairs(api.nvim_buf_get_keymap(api.nvim_get_current_buf(), "n")) do
    if map.lhs == lhs then assert(map.callback, "missing callback: " .. lhs) map.callback() return end
  end
  error("mapping not found: " .. lhs)
end
local function floats()
  local result = {}
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= "" then result[#result + 1] = win end
  end
  return result
end
local function row(buf, text)
  for index, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(text, 1, true) then return index end
  end
  error("row not found: " .. text)
end
local function select_row(win, buf, text)
  api.nvim_win_set_cursor(win, { row(buf, text), 0 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
end
local function fits(win, buf)
  local width = api.nvim_win_get_width(win)
  for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
    assert(vim.fn.strdisplaywidth(line) <= width, "row exceeds pane width: " .. line)
    assert(vim.fn.strdisplaywidth(line) == vim.fn.strdisplaywidth(vim.fn.strcharpart(line, 0)), "invalid UTF-8")
  end
end
local function resize(columns)
  vim.o.columns = columns
  api.nvim_exec_autocmds("VimResized", {})
end

local ok, error_message = pcall(function()
  vim.cmd("edit " .. vim.fn.fnameescape(plugin .. "/tests/fixture.test.ts"))
  local source_buf, source_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  vim.bo.filetype = "typescript"
  local first_name = "first scenario keeps a working branch URL readable and preserves café and 日本語 names on laptop screens"
  api.nvim_buf_set_lines(source_buf, 0, -1, false, {
    'import { describe, it } from "vitest";',
    'describe("Demo suite", () => {',
    '  it("' .. first_name .. '", () => { throw new Error("must never execute"); });',
    '  it.each(["fork", "closed"])("handles %s", () => {});',
    '  it.skip("later", () => {});',
    '});',
  })
  vim.cmd("Testscope")
  local tree_buf, tree_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  wait_for(function() return api.nvim_buf_is_valid(tree_buf) and lines(tree_buf):find("handles fork", 1, true) ~= nil end, "outline did not load")
  assert(#floats() == 2, "wide screens should show outline and source")
  assert(lines(tree_buf):find("3 tests · 4 static cases · 1 suite", 1, true))
  assert(api.nvim_get_hl(0, { name = "TestscopeNormal", link = false }).bg, "browser background must be opaque")
  local initial_background = api.nvim_get_hl(0, { name = "TestscopeNormal", link = false }).bg
  api.nvim_set_hl(0, "Normal", { fg = 0x1e293b, bg = 0xf0f4f8 })
  api.nvim_exec_autocmds("ColorScheme", {})
  assert(api.nvim_get_hl(0, { name = "TestscopeNormal", link = false }).bg ~= initial_background, "palette did not follow colorscheme change")
  assert(vim.wo[tree_win].winblend == 0)
  assert(vim.wo[tree_win].wrap == false, "titles should use intentional hanging indents")
  fits(tree_win, tree_buf)

  select_row(tree_win, tree_buf, "Demo suite")
  key("<Tab>")
  assert(not lines(tree_buf):find("handles fork", 1, true), "fold failed")
  key("zR")
  assert(lines(tree_buf):find("handles closed", 1, true), "expand failed")
  local previous_input = vim.ui.input
  vim.ui.input = function(_, callback) callback("closed") end
  key("/")
  vim.ui.input = previous_input
  assert(lines(tree_buf):find("handles closed", 1, true))
  assert(not lines(tree_buf):find("handles fork", 1, true), "filter failed")
  key("c")
  key("p")
  assert(#floats() == 1, "preview toggle failed")
  key("p")
  assert(#floats() == 2)

  for _, columns in ipairs({ 140, 100, 72, 48, 32 }) do
    resize(columns)
    assert(#floats() == 1, "compact screens should give the test list full width")
    assert(api.nvim_win_get_width(tree_win) >= math.floor(columns * 0.9), "compact outline lost width")
    fits(tree_win, tree_buf)
  end
  resize(72)
  select_row(tree_win, tree_buf, "first scenario")
  local selection_ns = api.nvim_get_namespaces().testscope_selection
  local marks = api.nvim_buf_get_extmarks(tree_buf, selection_ns, 0, -1, {})
  assert(#marks >= 2, "selection should cover the whole wrapped title")
  local wrapped_row = api.nvim_win_get_cursor(tree_win)[1]
  key("j")
  assert(api.nvim_get_current_line():find("handles %s", 1, true), "j must skip continuations and spacing")
  key("k")
  assert(api.nvim_win_get_cursor(tree_win)[1] == wrapped_row, "k did not return to the title")

  key("p")
  assert(#floats() == 2, "compact preview should open on demand")
  assert(api.nvim_get_current_win() ~= tree_win, "compact preview should receive focus")
  local preview_win, preview_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  assert(api.nvim_win_get_width(preview_win) == api.nvim_win_get_width(tree_win))
  assert(vim.wo[preview_win].linebreak and vim.wo[preview_win].breakindent)
  assert(vim.wo[preview_win].statuscolumn:find("v:lnum + 2", 1, true), "source numbers must match the original file")
  assert(api.nvim_buf_get_lines(preview_buf, 0, 1, false)[1]:sub(1, 3) == "it(", "source should remove shared indentation")
  key("<Tab>")
  assert(#floats() == 1 and api.nvim_get_current_win() == tree_win, "Tab must return to the list")
  key("P")
  key("<Esc>")
  assert(#floats() == 1 and api.nvim_get_current_win() == tree_win, "Esc must dismiss compact source only")

  resize(200)
  assert(#floats() == 2, "wide layout did not return")
  assert(api.nvim_get_current_line():find("first scenario", 1, true), "resize lost selection")
  key("?")
  assert(#floats() == 3 and lines(api.nvim_get_current_buf()):find("BROWSE", 1, true), "help did not open")
  key("<Esc>")
  assert(#floats() == 2 and api.nvim_get_current_win() == tree_win)
  key("f")
  assert(#floats() == 3, "focus mode needs an editor backdrop")
  local backdrop
  for _, win in ipairs(floats()) do
    if api.nvim_win_get_config(win).zindex == 40 then backdrop = win end
  end
  assert(backdrop and api.nvim_win_get_width(backdrop) == vim.o.columns, "focus backdrop does not cover the editor")
  key("f")
  assert(#floats() == 2)

  api.nvim_buf_set_lines(source_buf, 2, 3, false, { '  it("unsaved change", () => {});' })
  key("r")
  wait_for(function() return lines(tree_buf):find("unsaved change", 1, true) ~= nil end, "unsaved refresh failed")
  select_row(tree_win, tree_buf, "unsaved change")
  key("P")
  key("<CR>")
  assert(#floats() == 0, "jump did not close floats")
  assert(api.nvim_get_current_win() == source_win, "jump did not restore source window")
  assert(api.nvim_get_current_buf() == source_buf)
  assert(api.nvim_win_get_cursor(source_win)[1] == 3, "jump went to wrong line")
  vim.cmd("Testscope!")
  assert(#floats() == 3, "bang should open directly in focus mode")
  vim.cmd("TestscopeClose")
  assert(#floats() == 0, "close during scan leaked floats")
  vim.cmd("Testscope")
  tree_buf = api.nvim_get_current_buf()
  wait_for(function() return lines(tree_buf):find("unsaved change", 1, true) ~= nil end, "reopen failed")
  api.nvim_win_close(api.nvim_get_current_win(), true)
  wait_for(function() return #floats() == 0 end, "external window close leaked preview")
  assert(api.nvim_get_current_buf() == source_buf)

  -- Go uses its own standard-library helper, including unsaved comment text.
  vim.cmd("hide edit " .. vim.fn.fnameescape(plugin .. "/tests/fixture_test.go"))
  local go_buf = api.nvim_get_current_buf()
  vim.bo.filetype = "go"
  api.nvim_buf_set_lines(go_buf, 0, -1, false, {
    'package demo',
    'import "testing"',
    '// Each job returns its linked employer, and updates stay with the affected records even on small screens.',
    'func TestJobDetail(t *testing.T) {',
    ' t.Parallel()',
    ' for _, tt := range []struct { name string }{{name: "configured prefix"}, {name: "no prefix"}} {',
    '  t.Run(tt.name, func(t *testing.T) { panic("must never run") })',
    ' }',
    '}',
    '// Missing text stays present as empty strings.',
    'func TestMissingText(t *testing.T) {}',
  })
  -- Go browsing must work without a Node executable or TypeScript compiler.
  require("testscope").setup({ node = "/missing-node", typescript_path = "/missing-typescript" })
  resize(72)
  vim.cmd("Testscope")
  tree_buf, tree_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
  wait_for(function() return lines(tree_buf):find("configured prefix", 1, true) ~= nil end, "Go outline did not load")
  assert(lines(tree_buf):find("2 tests · 3 outlined cases", 1, true))
  fits(tree_win, tree_buf)
  select_row(tree_win, tree_buf, "TestJobDetail")
  key("j")
  assert(api.nvim_get_current_line():find("configured prefix", 1, true), "Go navigation did not skip annotation rows")
  key("k")
  api.nvim_win_set_cursor(tree_win, { row(tree_buf, "Each job"), 0 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = tree_buf })
  local input = vim.ui.input
  vim.ui.input = function(_, callback) callback("affected records") end
  key("/")
  vim.ui.input = input
  assert(not lines(tree_buf):find("TestMissingText", 1, true), "annotation filter did not narrow tests")
  assert(lines(tree_buf):find("configured prefix", 1, true), "annotation filter lost descendant cases")
  key("c")
  for _, columns in ipairs({ 32, 48, 100, 200 }) do resize(columns) fits(tree_win, tree_buf) end
  resize(72)
  select_row(tree_win, tree_buf, "TestJobDetail")
  key("p")
  assert(vim.bo[api.nvim_get_current_buf()].filetype == "go", "Go preview lost filetype")
  key("<Tab>")
  api.nvim_buf_set_lines(go_buf, 2, 3, false, { '// Updated intent from an unsaved buffer.' })
  key("r")
  wait_for(function() return lines(tree_buf):find("Updated intent", 1, true) ~= nil end, "Go annotation refresh failed")
  select_row(tree_win, tree_buf, "Updated intent")
  key("<CR>")
  assert(api.nvim_get_current_buf() == go_buf and api.nvim_win_get_cursor(0)[1] == 4, "annotation must jump to its test function")
  assert(#floats() == 0, "Go jump leaked floats")
  require("testscope").setup({ node = "node", typescript_path = vim.env.TESTSCOPE_TYPESCRIPT })

  -- Smoke-test the user's source when running in the Egoist Labs workspace.
  local workspace_sample = vim.fn.fnamemodify(plugin, ":h") .. "/platform-api/ci/preview/cli.test.ts"
  if vim.fn.filereadable(workspace_sample) == 1 then
    vim.cmd("hide edit " .. vim.fn.fnameescape(workspace_sample))
    local actual_buf = api.nvim_get_current_buf()
    resize(140)
    vim.cmd("Testscope!")
    local actual_tree, actual_win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    wait_for(function() return lines(actual_tree):find("PR preview", 1, true) ~= nil end, "workspace source did not load")
    fits(actual_win, actual_tree)
    assert(#floats() == 2, "laptop focus view should contain backdrop and full-width list")
    assert(api.nvim_win_get_height(actual_win) <= api.nvim_buf_line_count(actual_tree) + 2, "compact card contains excessive blank space")
    require("testscope").close()
    assert(api.nvim_get_current_buf() == actual_buf)
    assert(not vim.bo[actual_buf].modified, "smoke test modified the user's source")
  end
end)

require("testscope").close()
if not ok then io.stderr:write(tostring(error_message) .. "\n") vim.cmd("cquit 1") end
print("Testscope UI integration passed: responsive layout, Unicode wrapping, navigation, source, focus")
vim.cmd("qa!")
