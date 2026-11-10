#!/usr/bin/env node
"use strict";

// Parse source only. Never import the test file, its dependencies, or its config.
const { createRequire } = require("node:module");
const { resolve } = require("node:path");
const { inspect } = require("node:util");

const runners = new Set(["vitest", "@jest/globals", "node:test"]);
const exportsByName = {
  describe: "suite",
  suite: "suite",
  it: "test",
  test: "test",
  fit: "test",
  xit: "test",
  fdescribe: "suite",
  xdescribe: "suite",
  xtest: "test",
};
const modifiers = new Set([
  "only",
  "skip",
  "todo",
  "concurrent",
  "sequential",
  "failing",
  "each",
  "for",
  "skipIf",
  "runIf",
]);
const factories = new Set(["each", "for", "skipIf", "runIf"]);

function runnerBinding(name, runner) {
  const kind = exportsByName[name];
  if (!kind) return null;
  const modifiers = name.startsWith("x")
    ? ["skip"]
    : name.startsWith("f")
      ? ["only"]
      : [];
  return { kind, runner, modifiers };
}

function supported(ts) {
  const major = Number(String(ts?.version).split(".")[0]);
  return major >= 5 && major < 7;
}

function loadTypeScript(filename, explicit) {
  if (explicit) return require(resolve(explicit));
  let project = null;
  try {
    project = createRequire(resolve(filename))("typescript");
  } catch (error) {
    if (error.code !== "MODULE_NOT_FOUND") throw error;
  }
  // Projects often pin an older compiler; prefer the plugin's copy over an unsupported one.
  if (project && supported(project)) return project;
  try {
    return require("typescript");
  } catch {
    throw new Error(
      project
        ? `The project's TypeScript ${project.version} is unsupported (need >=5, <7). Run \`npm install\` in the testscope.nvim directory or set testscope's typescript_path.`
        : "TypeScript was not found. Install typescript (>=5, <7) in your project or set testscope's typescript_path.",
    );
  }
}

function scan(ts, source, filename) {
  if (typeof ts.createSourceFile !== "function")
    throw new Error(
      "This plugin requires the TypeScript compiler API (>=5, <7).",
    );
  const file = ts.createSourceFile(
    filename,
    source,
    ts.ScriptTarget.Latest,
    true,
  );
  const roots = [];
  let declarations = 0;

  function unwrap(node) {
    while (
      node &&
      (ts.isParenthesizedExpression(node) ||
        ts.isAsExpression(node) ||
        ts.isTypeAssertionExpression(node) ||
        ts.isNonNullExpression(node) ||
        ts.isSatisfiesExpression(node))
    )
      node = node.expression;
    return node;
  }

  function bindingNames(name) {
    if (ts.isIdentifier(name)) return [name.text];
    return name.elements.flatMap((element) =>
      ts.isBindingElement(element) ? bindingNames(element.name) : [],
    );
  }

  function scope(statements, outer) {
    const bindings = new Map(outer);
    for (const statement of statements) {
      if (ts.isImportDeclaration(statement) && statement.importClause) {
        const runner = statement.moduleSpecifier.text;
        const clause = statement.importClause;
        if (clause.name)
          bindings.set(
            clause.name.text,
            runner === "node:test" && !clause.isTypeOnly
              ? runnerBinding("test", runner)
              : null,
          );
        if (
          clause.namedBindings &&
          ts.isNamespaceImport(clause.namedBindings)
        ) {
          bindings.set(
            clause.namedBindings.name.text,
            runners.has(runner) && !clause.isTypeOnly
              ? { kind: "namespace", runner }
              : null,
          );
        } else if (clause.namedBindings) {
          for (const entry of clause.namedBindings.elements) {
            const exported = (entry.propertyName || entry.name).text;
            bindings.set(
              entry.name.text,
              runners.has(runner) && !clause.isTypeOnly && !entry.isTypeOnly
                ? runnerBinding(exported, runner)
                : null,
            );
          }
        }
      } else if (ts.isVariableStatement(statement)) {
        for (const declaration of statement.declarationList.declarations) {
          for (const name of bindingNames(declaration.name)) {
            bindings.set(
              name,
              ts.isIdentifier(declaration.name) &&
                statement.declarationList.flags & ts.NodeFlags.Const
                ? { initializer: declaration.initializer, scope: bindings }
                : null,
            );
          }
        }
      } else if (
        (ts.isFunctionDeclaration(statement) ||
          ts.isClassDeclaration(statement)) &&
        statement.name
      ) {
        bindings.set(statement.name.text, null);
      }
    }
    return bindings;
  }

  function literal(node, bindings, depth = 0) {
    node = unwrap(node);
    if (!node || depth > 20) return { ok: false };
    if (ts.isStringLiteralLike(node)) return { ok: true, value: node.text };
    if (ts.isNumericLiteral(node))
      return { ok: true, value: Number(node.text) };
    if (node.kind === ts.SyntaxKind.TrueKeyword)
      return { ok: true, value: true };
    if (node.kind === ts.SyntaxKind.FalseKeyword)
      return { ok: true, value: false };
    if (node.kind === ts.SyntaxKind.NullKeyword)
      return { ok: true, value: null };
    if (ts.isIdentifier(node)) {
      const binding = bindings.get(node.text);
      return literal(
        binding?.initializer,
        binding?.scope || bindings,
        depth + 1,
      );
    }
    if (ts.isPrefixUnaryExpression(node)) {
      const result = literal(node.operand, bindings, depth + 1);
      if (
        result.ok &&
        typeof result.value === "number" &&
        (node.operator === ts.SyntaxKind.MinusToken ||
          node.operator === ts.SyntaxKind.PlusToken)
      )
        return {
          ok: true,
          value:
            node.operator === ts.SyntaxKind.MinusToken
              ? -result.value
              : result.value,
        };
    }
    if (ts.isArrayLiteralExpression(node)) {
      const items = node.elements.map((entry) =>
        literal(entry, bindings, depth + 1),
      );
      if (items.every((item) => item.ok))
        return { ok: true, value: items.map((item) => item.value) };
    }
    if (ts.isObjectLiteralExpression(node)) {
      const value = Object.create(null);
      for (const entry of node.properties) {
        if (
          !ts.isPropertyAssignment(entry) ||
          ts.isComputedPropertyName(entry.name)
        )
          return { ok: false };
        const result = literal(entry.initializer, bindings, depth + 1);
        if (!result.ok) return result;
        value[entry.name.text] = result.value;
      }
      return { ok: true, value };
    }
    return { ok: false };
  }

  function callee(node, bindings) {
    node = unwrap(node);
    if (!node) return null;
    if (ts.isIdentifier(node)) {
      const binding = bindings.get(node.text);
      return binding?.kind
        ? { ...binding, modifiers: binding.modifiers || [] }
        : null;
    }
    if (ts.isPropertyAccessExpression(node)) {
      const inner = callee(node.expression, bindings);
      if (!inner) return null;
      const name = node.name.text;
      if (inner.kind === "namespace" || inner.kind === "context") {
        const kind =
          inner.kind === "context"
            ? name === "test"
              ? "test"
              : null
            : exportsByName[name];
        return kind ? runnerBinding(name, inner.runner) : null;
      }
      return modifiers.has(name)
        ? {
            ...inner,
            modifiers: [...inner.modifiers, name],
            pending: factories.has(name),
          }
        : null;
    }
    if (ts.isCallExpression(node)) {
      const inner = callee(node.expression, bindings);
      if (!inner?.pending) return null;
      const modifier = inner.modifiers.at(-1);
      return {
        ...inner,
        pending: false,
        table:
          modifier === "each" || modifier === "for"
            ? node.arguments[0]
            : inner.table,
      };
    }
    if (ts.isTaggedTemplateExpression(node)) {
      const inner = callee(node.tag, bindings);
      return inner?.pending ? { ...inner, pending: false, tagged: true } : null;
    }
    return null;
  }

  function caseName(template, row, index) {
    const values = Array.isArray(row) ? row : [row];
    let position = 0;
    let name = template.replace(/%([%sdifjo#$])/g, (match, type) => {
      if (type === "%") return "%";
      if (type === "#") return String(index);
      if (type === "$") return String(index + 1);
      if (position >= values.length) return match;
      const value = values[position++];
      if (type === "j") return JSON.stringify(value);
      if (type === "o")
        return inspect(value, { depth: 3, breakLength: Infinity });
      if (type === "i") return String(parseInt(value, 10));
      if (type === "d" || type === "f") return String(Number(value));
      return String(value);
    });
    const object = Array.isArray(row) ? row[0] : row;
    name = name.replace(
      /\$([a-zA-Z_][\w]*(?:\.[a-zA-Z_][\w]*)*)/g,
      (match, path) => {
        let value = object;
        for (const key of path.split(".")) {
          if (
            value === null ||
            typeof value !== "object" ||
            !Object.hasOwn(value, key)
          )
            return match;
          value = value[key];
        }
        return typeof value === "string" ? value : JSON.stringify(value);
      },
    );
    return name;
  }

  function walk(node, parent, bindings, callbackContext) {
    if (ts.isSourceFile(node) || ts.isBlock(node))
      bindings = scope(node.statements, bindings);
    if (ts.isFunctionLike(node)) {
      bindings = new Map(bindings);
      for (const parameter of node.parameters)
        for (const name of bindingNames(parameter.name))
          bindings.set(name, null);
      if (
        callbackContext &&
        node.parameters[0] &&
        ts.isIdentifier(node.parameters[0].name)
      )
        bindings.set(node.parameters[0].name.text, {
          kind: "context",
          runner: "node:test",
        });
      if (node.name && ts.isIdentifier(node.name))
        bindings.set(node.name.text, null);
    }
    if (ts.isCatchClause(node) && node.variableDeclaration) {
      bindings = new Map(bindings);
      for (const name of bindingNames(node.variableDeclaration.name))
        bindings.set(name, null);
    }
    if (ts.isCallExpression(node)) {
      const info = callee(node.expression, bindings);
      const title = node.arguments[0];
      const callback = [...node.arguments]
        .reverse()
        .find((arg) => ts.isArrowFunction(arg) || ts.isFunctionExpression(arg));
      if (
        info &&
        !info.pending &&
        (info.kind === "suite" || info.kind === "test") &&
        title &&
        (ts.isStringLiteralLike(title) ||
          ts.isTemplateExpression(title) ||
          callback)
      ) {
        const start = file.getLineAndCharacterOfPosition(node.getStart(file));
        const end = file.getLineAndCharacterOfPosition(node.getEnd());
        const staticTitle = literal(title, bindings);
        const name =
          staticTitle.ok && typeof staticTitle.value === "string"
            ? staticTitle.value
            : title.getText(file);
        const entry = {
          id: `${start.line + 1}:${start.character}`,
          kind: info.kind,
          name,
          line: start.line + 1,
          column: start.character,
          end_line: end.line + 1,
          modifiers: info.modifiers,
          dynamic: !staticTitle.ok,
          children: [],
        };
        const options = node.arguments.find(
          (arg, index) => index > 0 && ts.isObjectLiteralExpression(arg),
        );
        if (options) {
          for (const property of options.properties) {
            if (
              ts.isPropertyAssignment(property) &&
              (property.name.text === "skip" ||
                property.name.text === "todo" ||
                property.name.text === "only")
            ) {
              const result = literal(property.initializer, bindings);
              if (result.ok && result.value)
                entry.modifiers.push(property.name.text);
            }
          }
        }
        (parent ? parent.children : roots).push(entry);
        if (info.kind === "test") declarations++;
        if (info.modifiers.includes("each") || info.modifiers.includes("for")) {
          entry.parameterized = true;
          const table = literal(info.table, bindings);
          if (
            info.kind === "test" &&
            table.ok &&
            Array.isArray(table.value) &&
            typeof staticTitle.value === "string"
          ) {
            entry.expanded = true;
            entry.children = table.value.map((row, index) => ({
              ...entry,
              id: `${entry.id}:${index}`,
              kind: "case",
              name: caseName(name, row, index),
              children: [],
              parameterized: false,
            }));
          }
        }
        // Only the test/suite body can register children. Data factory calls are not tests.
        if (callback)
          walk(
            callback,
            entry,
            bindings,
            info.runner === "node:test" && info.kind === "test",
          );
        return;
      }
    }
    ts.forEachChild(node, (child) => walk(child, parent, bindings, false));
  }

  const globals = new Map(
    Object.keys(exportsByName).map((name) => [
      name,
      runnerBinding(name, "global"),
    ]),
  );
  walk(file, null, globals, false);
  let cases = 0;
  let unresolved = 0;
  function count(entries) {
    for (const entry of entries) {
      if (
        entry.kind === "case" ||
        (entry.kind === "test" && !entry.parameterized)
      )
        cases++;
      if (entry.parameterized && !entry.expanded) unresolved++;
      count(entry.children);
    }
  }
  count(roots);
  return {
    roots,
    declarations,
    cases,
    unresolved,
    diagnostics: file.parseDiagnostics.map((diagnostic) => ({
      line: file.getLineAndCharacterOfPosition(diagnostic.start || 0).line + 1,
      message: ts.flattenDiagnosticMessageText(diagnostic.messageText, " "),
    })),
  };
}

module.exports = { scan, loadTypeScript };

if (require.main === module) {
  let source = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    source += chunk;
  });
  process.stdin.on("end", () => {
    try {
      const filename = process.argv[2];
      if (!filename) throw new Error("Expected the test file's absolute path.");
      process.stdout.write(
        JSON.stringify(
          scan(loadTypeScript(filename, process.argv[3]), source, filename),
        ),
      );
    } catch (error) {
      process.stderr.write(`Testscope: ${error.message}\n`);
      process.exitCode = 1;
    }
  });
}
