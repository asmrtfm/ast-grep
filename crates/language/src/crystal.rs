#[cfg(test)]
mod test {
  use crate::test::{test_match_lang, test_non_match_lang, test_replace_lang};
  use crate::Crystal;
  fn test_match(query: &str, source: &str) {
    test_match_lang(query, source, Crystal);
  }

  fn test_non_match(query: &str, source: &str) {
    test_non_match_lang(query, source, Crystal);
  }

  fn test_replace(src: &str, pattern: &str, replacer: &str) -> String {
    test_replace_lang(src, pattern, replacer, Crystal)
  }

  // -- Class definitions --

  #[test]
  fn test_crystal_class() {
    test_match("class Foo\nend", "class Foo\nend");
    test_match("class Foo\n  $$$BODY\nend", "class Foo\n  def bar\n  end\nend");
  }

  // -- Method definitions --

  #[test]
  fn test_crystal_method_def() {
    test_match("def $NAME\nend", "def hello\nend");
  }

  #[test]
  fn test_crystal_method_with_params() {
    test_match(
      "def $NAME($$$PARAMS)\nend",
      "def greet(name, age)\nend",
    );
  }

  // -- Expressions --

  #[test]
  fn test_crystal_method_call() {
    test_match("puts($A)", "puts(123)");
  }

  #[test]
  fn test_crystal_assignment() {
    test_match("$A = $B", "x = 42");
  }

  #[test]
  fn test_crystal_string() {
    test_match("\"$A\"", "\"hello\"");
  }

  #[test]
  fn test_crystal_non_match() {
    test_non_match("def foo\nend", "def bar\nend");
  }

  #[test]
  fn test_crystal_replace() {
    let ret = test_replace("x = 42", "$A = 42", "$A = 100");
    assert_eq!(ret, "x = 100");
  }
}
