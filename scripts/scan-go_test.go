package main

import (
	"encoding/json"
	"testing"
)

func TestGoOutlinePreservesIntentAndTableSubtests(t *testing.T) {
	source := []byte("package demo\nimport check \"testing\"\n" + `
// Each job returns its employer.
// Updates stay with the affected records.
func TestJobDetail(t *check.T) {
 t.Parallel()
 panic("this source must never run")
 for _, tt := range []struct { name string; ignored int }{
  {name: "configured prefix", ignored: 1},
  {"no prefix", 2},
 } {
  // A nested scenario keeps its own explanation.
  t.Run(tt.name, func(child *check.T) {
   child.Run("updates", func(inner *check.T) { inner.Skip("later") })
   child.Run("helper", checkJobs)
  })
 }
 cases := []string{"café", ` + "`日本語`" + `}
 for _, name := range cases { t.Run(name, func(t *check.T) {}) }
 var unrelated struct { Run func(string, func(*check.T)) }
 unrelated.Run("fake", func(t *check.T) {})
 func(t *check.T) { t.Run("uncalled helper", func(t *check.T) {}) }(t)
}
func Testlower(t *check.T) {}
func TestWrong(t string) {}
func TestMain(t *check.M) {}
func BenchmarkDemo(t *check.B) {}
func (x object) TestMethod(t *check.T) {}
`)
	got := scanGo(source, "demo_test.go")
	if len(got.Diagnostics) != 0 || len(got.Roots) != 1 {
		t.Fatalf("unexpected outline: %+v", got)
	}
	root := got.Roots[0]
	if root.Name != "TestJobDetail" || root.Line != 6 || root.Column != 0 || root.EndLine <= root.Line {
		t.Fatalf("bad location: %+v", root)
	}
	if root.Annotation != "Each job returns its employer.\nUpdates stay with the affected records." || root.Modifiers[0] != "parallel" {
		t.Fatalf("lost intent/modifier: %+v", root)
	}
	if len(root.Children) != 4 {
		t.Fatalf("table expansion: %+v", root.Children)
	}
	for i, name := range []string{"configured prefix", "no prefix", "café", "日本語"} {
		if root.Children[i].Name != name || root.Children[i].Dynamic {
			t.Fatalf("case %d: %+v", i, root.Children[i])
		}
	}
	first, second := root.Children[0], root.Children[1]
	if first.ID == second.ID || first.Line != second.Line || first.Annotation != "A nested scenario keeps its own explanation." {
		t.Fatal("table identity/comments/location lost")
	}
	if len(first.Children) != 2 || first.Children[0].Modifiers[0] != "skip" || first.Children[1].Modifiers[0] != "helper callback" {
		t.Fatalf("nested outline: %+v", first.Children)
	}
	if got.Declarations != 5 || got.Cases != 6 || got.Unresolved != 0 {
		t.Fatalf("bad counts: %+v", got)
	}
	encoded, err := json.Marshal(got)
	if err != nil || len(encoded) == 0 {
		t.Fatal("outline must serialize")
	}
}

func TestGoOutlineKeepsDynamicNamesAndPartialSource(t *testing.T) {
	source := []byte(`package demo
import "testing"
/* Invalid requests return safe errors. */
func TestErrors(t *testing.T) {
 for _, tt := range runtimeCases() {
  t.Run(tt.name, func(t *testing.T) {})
 }
 t.Run("literal " + "title", func(t *testing.T) {})
 {
  t := fakeRunner{}
  t.Run("shadowed", func(t *testing.T) {})
 }
 // t.Run("comment", nil)
 _ = "t.Run(quoted, nil)"
}
func unfinished(
`)
	got := scanGo(source, "partial_test.go")
	if len(got.Diagnostics) == 0 || len(got.Roots) != 1 {
		t.Fatalf("partial parse: %+v", got)
	}
	root := got.Roots[0]
	if root.Annotation != "Invalid requests return safe errors." || len(root.Children) != 2 {
		t.Fatalf("wrong entries: %+v", root)
	}
	if root.Children[0].Name != "tt.name" || !root.Children[0].Dynamic || root.Children[1].Name != "literal title" {
		t.Fatalf("dynamic names: %+v", root.Children)
	}
	if got.Unresolved != 1 || got.Cases != 1 {
		t.Fatalf("dynamic count: %+v", got)
	}
	if len(scanGo([]byte("not Go"), "broken_test.go").Diagnostics) == 0 {
		t.Fatal("bad source must report errors")
	}
}
