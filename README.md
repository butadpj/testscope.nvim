# testscope.nvim

A floating test browser for Go, TypeScript, and JavaScript. Open a test file, run
`:Testscope`, and browse its suites, cases, and source without running the tests.

Works with Vitest, Jest globals / `@jest/globals`, and `node:test`. No Nerd Font,
Tree-sitter parser, or other Neovim plugin required. The browser follows your
colorscheme, with an opaque surface and a selection that spans the whole test.

On laptop screens the list gets the full browser width. Long names wrap at word
boundaries with hanging indents; tree guides and source line labels keep entries
easy to follow. The small **MAP** strip tracks your position in the visible tree.
It indicates navigation, not test results.

Press **`f`** for focus mode: a clean backdrop hides the surrounding editor for a
screenshot. You can also open directly in that mode with **`:Testscope!`**.

## Install

Requires **Neovim 0.10+**. Go files need **Go 1.18+** on PATH; they do not need
Node.js or TypeScript. JavaScript/TypeScript files need **Node.js 18+** and
**TypeScript >=5, <7**. The scanner uses the TypeScript installed in the project
containing the test file, falling back to the plugin's own `node_modules`
(installed by the `build` step below).

With lazy.nvim:

```lua
{
  "butadpj/testscope.nvim",
  build = "npm install",
  cmd = { "Testscope", "TestscopeClose" },
  keys = {
    { "<leader>tt", "<cmd>Testscope<cr>", desc = "Browse this file's tests" },
  },
  opts = {},
}
```

To hack on a local checkout instead, add `dev = true` to the spec and set
`dev = { path = "~/Projects", fallback = true }` in `require("lazy").setup()`.
lazy.nvim then loads `~/Projects/testscope.nvim` when it exists and clones from
GitHub when it does not.

Try it with an isolated config from a checkout:

```sh
nvim -u NONE -i NONE \
  --cmd 'set runtimepath+=.' \
  -c 'runtime plugin/testscope.lua' \
  -c Testscope \
  path/to/some.test.ts
```

## Controls

| Key                  | Action                                                              |
| -------------------- | ------------------------------------------------------------------- |
| `j` / `k`            | Navigate                                                            |
| `Enter`              | Close browser and jump to the declaration                           |
| `Tab`, `Space`, `za` | Fold / unfold selected suite or case table                          |
| `h` / `l`            | Collapse / go to parent; expand / go to first child                 |
| `zM` / `zR`          | Collapse / expand all                                               |
| `/`                  | Filter by test name or ancestor suite; plain text, case insensitive |
| `c`                  | Clear filter                                                        |
| `r`                  | Reparse the current buffer, including unsaved edits                 |
| `p`                  | Toggle source preview                                               |
| `P`                  | Focus the source preview to scroll; `Tab` returns                   |
| `f`                  | Toggle focus mode with a clean editor backdrop                      |
| `?`                  | Show keyboard help                                                  |
| `y`                  | Yank the selected test name into the unnamed register               |
| `q` / `Esc`          | Close; Esc returns to tests from compact source                     |

The source pane appears beside the list when the browser is at least 160 columns
wide. On smaller screens, `p` opens a full-width source view; `Tab` or `Esc`
returns to the list. Source lines use their original file numbers, with shared
indentation removed to save space. `j` and `k` move between entries, skipping
wrapped continuation lines and spacing.

Saving the source buffer refreshes the outline. Parameterized case rows jump to
their shared declaration. If the source changes before a jump, the plugin
refreshes before navigating.

## Configuration

Optional; the defaults work in this workspace:

```lua
require("testscope").setup({
  node = "node",          -- Or an absolute path to the Node.js executable
  go = "go",              -- Or an absolute path to the Go executable
  typescript_path = nil,  -- Optional absolute path to typescript/lib/typescript.js
  width = 0.92,           -- Fraction of terminal width
  height = 0.8,           -- Fraction of terminal height
  preview = true,
  preview_min_width = 160, -- Browser columns needed for source beside the list
  border = "rounded",
})
```

For projects without a local TypeScript install, run `npm install` in the plugin
directory or point `typescript_path` at an existing TypeScript compiler.

## What the outline means

### Go tests and intent comments

Open a `_test.go` file and use the same `:Testscope` command. Comments immediately
above a test function appear beneath its name, wrap with the entry, and are
included in `/` filtering:

```go
// Each job returns its linked employer, and updates stay with the affected records.
func TestJobDetail_ReturnsLinkedEmployerAndReflectsUpdates(t *testing.T) {
    // ...
}
```

- Discovers `TestXxx(*testing.T)` functions and nested `t.Run` calls, including
  aliased `testing` imports and renamed callback parameters.
- Expands literal slice/array tables ranged directly or through a local variable,
  with string names such as `tt.name`. Supports keyed and positional struct rows,
  string slices, raw strings, and literal string concatenation.
- Leading comments on inline subtests also appear as descriptions. Selecting a
  description or expanded case jumps to its function or shared `t.Run` call.
- `Parallel` and `Skip` calls appear as source badges; conditional calls may not
  execute. Computed names remain visible as **dynamic name**.
- Named callbacks such as `t.Run("initial requests", checkJobs)` show a **helper
  callback** badge. Their implementation is not expanded. Uncalled function
  literals, benchmarks, fuzz tests, examples, and `TestMain` are omitted.
- The Go summary counts top-level tests and known leaf cases in the outline,
  including repeated table rows. It is not the runner's final test count.
  Helper callbacks, computed tables, mutation of tables, branches, build tags,
  and runtime name normalization can change what actually runs.

The Go helper uses the standard library's [Go parser](https://pkg.go.dev/go/parser)
with comments enabled. `go run` builds only the plugin helper; it does not load
your project's modules or compile/run your tests. The first scan can take longer
while Go warms its build cache. Subsequent scans reuse that cache.

### JavaScript and TypeScript

- Recognizes imported aliases, namespace imports, standard globals, nested suites,
  Node subtests, and chains such as `test.skip`, `it.concurrent`, and `it.each`.
- Literal `test.each` / `test.for` arrays and simple `const` tables expand into
  cases. Titles support common `%s`, `%d`, `%i`, `%f`, `%j`, `%o`, `%#`, `%$`,
  and `$object.field` substitutions.
- Skip, todo, only, concurrency, and conditional modifiers appear as badges.
  Conditional expressions are not executed; their runtime effect is unknown.
- Comments and strings containing test-like text do not produce entries.
- The summary counts declarations and statically discoverable cases. Dynamic
  tables and tagged tables remain one declaration marked **dynamic cases**.
  Parameterized suites show the suite template, without multiplying its children.
- Loops, branches, custom wrappers, CommonJS runner imports, and runtime-generated
  names can differ from the runner's actual registered tests. This is a source
  outline, so it does not show pass/fail status or evaluate fixtures.
- Syntax errors keep the available outline visible with an incomplete-outline
  warning.

The helper parses buffer text with the [TypeScript compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API).
It loads only the compiler; it does not import the test file or load runner config.
The UI uses [Neovim's native floating windows](https://neovim.io/doc/user/api/).

## Development

```sh
npm install
npm test
go test scripts/scan-go.go scripts/scan-go_test.go
nvim --headless -u NONE -i NONE -l tests/ui.lua
```

The UI test covers 32–200 columns, long names, Unicode, selection, navigation,
source line numbers, Go intent comments and table subtests, focus mode, and cleanup.
It uses synthetic Go/TypeScript buffers and the
local TypeScript installation. To use
an existing compiler without installing another copy, set `TESTSCOPE_TYPESCRIPT`
to its `typescript.js` path when running either test command.
