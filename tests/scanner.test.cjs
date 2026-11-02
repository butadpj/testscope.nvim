"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { resolve } = require("node:path");
const { scan, loadTypeScript } = require("../scripts/scan.cjs");
const filename = resolve(__dirname, "fixture.test.ts");
const ts = loadTypeScript(filename, process.env.TESTSCOPE_TYPESCRIPT);
const parse = (source) => scan(ts, source, filename);
const flatten = (entries) =>
  entries.flatMap((entry) => [entry, ...flatten(entry.children)]);

test("finds nested suites, aliases, namespaces, source locations and modifiers", () => {
  const source = `import { describe as group, it as spec } from "vitest";
import * as v from "vitest";
group("outer", () => {
  group("inner", () => {
    spec.skip("first", () => {});
    v.test.concurrent.only("second", () => {});
  });
});`;
  const result = parse(source);
  const entries = flatten(result.roots);
  assert.deepEqual(
    entries.map((entry) => entry.name),
    ["outer", "inner", "first", "second"],
  );
  assert.equal(entries[2].line, 5);
  assert.equal(entries[2].column, 4);
  assert.deepEqual(entries[2].modifiers, ["skip"]);
  assert.deepEqual(entries[3].modifiers, ["concurrent", "only"]);
  assert.equal(result.declarations, 2);
  assert.equal(result.cases, 2);
});

test("expands multiline each tables and safely resolves const literals", () => {
  const result = parse(`const rows = [["fork", 1], ["closed", -2]] as const;
describe("suite", () => {
  it.each(rows)(
    "%s PR %i (#%#)",
    async () => {},
  );
  test.for([{ title: "nested", data: { value: 3 } }])("$title $data.value", () => {});
});`);
  const children = result.roots[0].children;
  assert.deepEqual(
    children[0].children.map((entry) => entry.name),
    ["fork PR 1 (#0)", "closed PR -2 (#1)"],
  );
  assert.equal(children[1].children[0].name, "nested 3");
  assert.equal(result.declarations, 2);
  assert.equal(result.cases, 3);
  assert.equal(result.unresolved, 0);
});

test("does not execute expressions; marks dynamic and tagged tables", () => {
  const result = parse(
    'it.each(dangerous())("name %s", () => {}); it.each`a | b\n${1} | ${2}`("$a", () => {}); it.each([])("empty", () => {});',
  );
  assert.equal(result.declarations, 3);
  assert.equal(result.cases, 0);
  assert.equal(result.unresolved, 2);
  assert.equal(result.roots[2].expanded, true);
  assert.equal(result.roots[2].children.length, 0);
});

test("ignores comments, strings, hooks, other imports and shadowed bindings", () => {
  const result = parse(`import { test as foreign } from "other-library";
// it("not a test", () => {});
const text = 'test("also not a test")';
beforeEach(() => {});
foreign("nope", () => {});
function helper(test: Function) { test("shadow", () => {}); }
{ const it = console.log; it("shadow", () => {}); }
it("real", () => {});`);
  assert.deepEqual(
    result.roots.map((entry) => entry.name),
    ["real"],
  );
});

test("recognizes Node default imports, subtests and options", () => {
  const result = parse(`import check, { describe as group } from "node:test";
group("suite", () => {
  check("parent", { only: true }, async (ctx) => {
    await ctx.test("child", { skip: "reason" }, () => {});
  });
});`);
  const parent = result.roots[0].children[0];
  assert.equal(parent.children[0].name, "child");
  assert.deepEqual(parent.modifiers, ["only"]);
  assert.deepEqual(parent.children[0].modifiers, ["skip"]);
  assert.equal(result.declarations, 2);
});

test("keeps dynamic titles, todo tests, conditional factories and syntax warnings", () => {
  const result = parse(
    'test.todo("later"); it.skipIf(flag)("conditional", () => {}); test(`hello ${name}`, () => {}); test("incomplete", () => {',
  );
  assert.equal(result.declarations, 4);
  assert.equal(result.roots[2].dynamic, true);
  assert.deepEqual(result.roots[1].modifiers, ["skipIf"]);
  assert.ok(result.diagnostics.length > 0);
});

test("parameterized suite templates retain their children", () => {
  const result = parse(
    'describe.each([1, 2])("suite %i", () => { test("child", () => {}); });',
  );
  assert.equal(result.roots[0].parameterized, true);
  assert.equal(result.roots[0].children[0].name, "child");
  assert.equal(result.declarations, 1);
  assert.equal(result.unresolved, 1);
});

test("decodes escaped titles and JSON placeholders", () => {
  const result = parse(
    'it.each(["\\r", "\\n", "\\0"])("rejects %j", () => {});',
  );
  assert.deepEqual(
    result.roots[0].children.map((entry) => entry.name),
    ['rejects "\\r"', 'rejects "\\n"', 'rejects "\\u0000"'],
  );
});

test("preserves implicit global modifiers and lexical const-table bindings", () => {
  const result = parse(`const value = "outer";
const rows = [value];
describe("suite", () => {
  const value = "inner";
  it.each(rows)("uses %s", () => {});
  fit("focused", () => {});
  xit("skipped", () => {});
});`);
  const entries = result.roots[0].children;
  assert.equal(entries[0].children[0].name, "uses outer");
  assert.deepEqual(entries[1].modifiers, ["only"]);
  assert.deepEqual(entries[2].modifiers, ["skip"]);
});
