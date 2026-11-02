// Testscope parses buffer text only; it never loads or executes the test package.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode"
)

type entry struct {
	ID         string   `json:"id"`
	Kind       string   `json:"kind"`
	Name       string   `json:"name"`
	Annotation string   `json:"annotation,omitempty"`
	Line       int      `json:"line"`
	Column     int      `json:"column"`
	EndLine    int      `json:"end_line"`
	Modifiers  []string `json:"modifiers"`
	Dynamic    bool     `json:"dynamic"`
	Children   []*entry `json:"children"`
}

type outline struct {
	Roots        []*entry `json:"roots"`
	Declarations int      `json:"declarations"`
	Cases        int      `json:"cases"`
	Unresolved   int      `json:"unresolved"`
	Diagnostics  []string `json:"diagnostics"`
}

type scanner struct {
	fset        *token.FileSet
	file        *ast.File
	result      outline
	seen        map[token.Pos]bool
	testingName string
}

func (s *scanner) parameter(t *ast.FuncType) *ast.Ident {
	if t.Params == nil || len(t.Params.List) != 1 || (t.Results != nil && len(t.Results.List) != 0) {
		return nil
	}
	f := t.Params.List[0]
	if len(f.Names) != 1 {
		return nil
	}
	pointer, ok := f.Type.(*ast.StarExpr)
	if !ok {
		return nil
	}
	selector, ok := pointer.X.(*ast.SelectorExpr)
	if !ok || selector.Sel.Name != "T" {
		return nil
	}
	pkg, ok := selector.X.(*ast.Ident)
	if !ok || pkg.Name != s.testingName || pkg.Obj != nil {
		return nil
	}
	return f.Names[0]
}

func (s *scanner) newEntry(node ast.Node, name, annotation, suffix string) *entry {
	start, end := s.fset.Position(node.Pos()), s.fset.Position(node.End())
	if !s.seen[node.Pos()] {
		s.result.Declarations++
		s.seen[node.Pos()] = true
	}
	return &entry{ID: fmt.Sprintf("%d:%d%s", start.Line, start.Column-1, suffix), Kind: "test", Name: name,
		Annotation: annotation, Line: start.Line, Column: start.Column - 1, EndLine: end.Line,
		Modifiers: []string{}, Children: []*entry{}}
}

func (s *scanner) comment(node ast.Node) string {
	line := s.fset.Position(node.Pos()).Line
	for _, group := range s.file.Comments {
		if s.fset.Position(group.End()).Line == line-1 {
			return strings.TrimSpace(group.Text())
		}
	}
	return ""
}

func literal(expr ast.Expr) (string, bool) {
	if value, ok := expr.(*ast.BasicLit); ok && value.Kind == token.STRING {
		text, err := strconv.Unquote(value.Value)
		return text, err == nil
	}
	if sum, ok := expr.(*ast.BinaryExpr); ok && sum.Op == token.ADD {
		a, aok := literal(sum.X)
		b, bok := literal(sum.Y)
		return a + b, aok && bok
	}
	return "", false
}

// shortcut: only literal slice/array tables are expanded; add data-flow analysis if computed tables are needed.
func table(expr ast.Expr) *ast.CompositeLit {
	if name, ok := expr.(*ast.Ident); ok && name.Obj != nil {
		switch decl := name.Obj.Decl.(type) {
		case *ast.AssignStmt:
			for i, lhs := range decl.Lhs {
				if id, ok := lhs.(*ast.Ident); ok && id.Obj == name.Obj && i < len(decl.Rhs) {
					expr = decl.Rhs[i]
					break
				}
			}
		case *ast.ValueSpec:
			for i, id := range decl.Names {
				if id.Obj == name.Obj && i < len(decl.Values) {
					expr = decl.Values[i]
					break
				}
			}
		}
	}
	value, ok := expr.(*ast.CompositeLit)
	if !ok {
		return nil
	}
	if _, ok := value.Type.(*ast.ArrayType); !ok {
		return nil
	}
	return value
}

type bindings map[*ast.Object]map[string]ast.Expr

func (s *scanner) walk(node ast.Node, receiver *ast.Ident, parent *entry, values bindings, suffix string) {
	ast.Inspect(node, func(node ast.Node) bool {
		switch n := node.(type) {
		case *ast.FuncLit:
			return false // Helpers are not registrations until called by the runner.
		case *ast.RangeStmt:
			variable, ok := n.Value.(*ast.Ident)
			rows := table(n.X)
			if !ok || rows == nil {
				return true
			}
			fields := []string{}
			if structure, ok := rows.Type.(*ast.ArrayType).Elt.(*ast.StructType); ok {
				for _, field := range structure.Fields.List {
					for _, name := range field.Names {
						fields = append(fields, name.Name)
					}
				}
			}
			for index, row := range rows.Elts {
				bound := bindings{}
				for key, value := range values {
					bound[key] = value
				}
				bound[variable.Obj] = map[string]ast.Expr{}
				if record, ok := row.(*ast.CompositeLit); ok {
					for i, field := range record.Elts {
						if keyed, ok := field.(*ast.KeyValueExpr); ok {
							if key, ok := keyed.Key.(*ast.Ident); ok {
								bound[variable.Obj][key.Name] = keyed.Value
							}
						} else if i < len(fields) {
							bound[variable.Obj][fields[i]] = field
						}
					}
				} else {
					bound[variable.Obj][""] = row
				}
				s.walk(n.Body, receiver, parent, bound, fmt.Sprintf("%s/%d", suffix, index))
			}
			return false
		case *ast.CallExpr:
			selector, ok := n.Fun.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			owner, ok := selector.X.(*ast.Ident)
			if !ok || owner.Obj == nil || owner.Obj != receiver.Obj {
				return true
			}
			switch selector.Sel.Name {
			case "Parallel":
				parent.Modifiers = append(parent.Modifiers, "parallel")
			case "Skip", "Skipf", "SkipNow":
				parent.Modifiers = append(parent.Modifiers, "skip")
			case "Run":
				if len(n.Args) != 2 {
					return true
				}
				title := n.Args[0]
				if field, ok := title.(*ast.SelectorExpr); ok {
					if name, ok := field.X.(*ast.Ident); ok && values[name.Obj][field.Sel.Name] != nil {
						title = values[name.Obj][field.Sel.Name]
					}
				} else if name, ok := title.(*ast.Ident); ok && values[name.Obj][""] != nil {
					title = values[name.Obj][""]
				}
				name, static := literal(title)
				if !static {
					var text bytes.Buffer
					_ = format.Node(&text, s.fset, title)
					name = text.String()
				}
				child := s.newEntry(n, name, s.comment(n), suffix)
				child.Dynamic = !static
				parent.Children = append(parent.Children, child)
				if callback, ok := n.Args[1].(*ast.FuncLit); ok {
					if parameter := s.parameter(callback.Type); parameter != nil {
						s.walk(callback.Body, parameter, child, values, suffix)
					}
				} else {
					child.Modifiers = append(child.Modifiers, "helper callback")
				}
				return false
			}
		}
		return true
	})
}

func scanGo(source []byte, filename string) outline {
	s := scanner{fset: token.NewFileSet(), seen: map[token.Pos]bool{}, result: outline{Roots: []*entry{}, Diagnostics: []string{}}}
	var err error
	s.file, err = parser.ParseFile(s.fset, filename, source, parser.ParseComments|parser.AllErrors)
	if err != nil {
		s.result.Diagnostics = append(s.result.Diagnostics, err.Error())
	}
	if s.file == nil {
		return s.result
	}
	for _, spec := range s.file.Imports {
		if spec.Path.Value == `"testing"` {
			s.testingName = "testing"
			if spec.Name != nil {
				s.testingName = spec.Name.Name
			}
		}
	}
	for _, decl := range s.file.Decls {
		function, ok := decl.(*ast.FuncDecl)
		if !ok || function.Recv != nil || function.Body == nil || !strings.HasPrefix(function.Name.Name, "Test") {
			continue
		}
		rest := []rune(strings.TrimPrefix(function.Name.Name, "Test"))
		if len(rest) > 0 && unicode.IsLower(rest[0]) {
			continue
		}
		parameter := s.parameter(function.Type)
		if parameter == nil {
			continue
		}
		annotation := ""
		if function.Doc != nil {
			annotation = strings.TrimSpace(function.Doc.Text())
		}
		root := s.newEntry(function, function.Name.Name, annotation, "")
		s.result.Roots = append(s.result.Roots, root)
		s.walk(function.Body, parameter, root, bindings{}, "")
	}
	var count func(*entry)
	count = func(e *entry) {
		if e.Dynamic {
			s.result.Unresolved++
		}
		if len(e.Children) == 0 && !e.Dynamic {
			s.result.Cases++
		}
		for _, child := range e.Children {
			count(child)
		}
	}
	for _, root := range s.result.Roots {
		count(root)
	}
	return s.result
}

func main() {
	filename := "buffer_test.go"
	if len(os.Args) > 1 {
		filename = os.Args[len(os.Args)-1]
	}
	source, err := io.ReadAll(os.Stdin)
	if err == nil {
		err = json.NewEncoder(os.Stdout).Encode(scanGo(source, filename))
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
