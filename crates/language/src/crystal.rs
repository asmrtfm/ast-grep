use ast_grep_core::Language;
use ast_grep_core::matcher::{Pattern, PatternBuilder, PatternError};
use ast_grep_core::tree_sitter::{LanguageExt, StrDoc, TSLanguage};
use std::borrow::Cow;

/// Lowercase expando — valid as an identifier start in Crystal.
const LOWER_EXPANDO: char = 'µ';
/// Uppercase expando (Greek Capital Mu, U+039C) — valid as a constant start.
const UPPER_EXPANDO: char = 'Μ';

/// Crystal has two lexically distinct name classes: identifiers (lowercase
/// start) and constants (uppercase start). The standard expando `µ` is
/// lowercase, so patterns like `class $NAME` fail to parse because `class`
/// expects an uppercase constant name. This impl tries the lowercase expando
/// first; on failure it retries with an uppercase expando.
#[derive(Clone, Copy, Debug)]
pub struct Crystal;

impl Language for Crystal {
  fn kind_to_id(&self, kind: &str) -> u16 {
    self
      .get_ts_language()
      .id_for_node_kind(kind, true)
  }
  fn field_to_id(&self, field: &str) -> Option<u16> {
    self
      .get_ts_language()
      .field_id_for_name(field)
      .map(|f| f.get())
  }
  fn expando_char(&self) -> char {
    LOWER_EXPANDO
  }
  fn pre_process_pattern<'q>(&self, query: &'q str) -> Cow<'q, str> {
    crate::pre_process_pattern(self.expando_char(), query)
  }
  fn build_pattern(&self, builder: &PatternBuilder) -> Result<Pattern, PatternError> {
    let lower_result = builder.build(|src| StrDoc::try_new(src, *self));
    if lower_result.is_ok() {
      return lower_result;
    }
    // Re-process with uppercase expando and build via CrystalUpper so that
    // extract_meta_var uses the matching expando char at match time.
    let upper_src = builder.src().replace(LOWER_EXPANDO, &UPPER_EXPANDO.to_string());
    Pattern::try_new(&upper_src, CrystalUpper)
  }
}

impl LanguageExt for Crystal {
  fn get_ts_language(&self) -> TSLanguage {
    crate::parsers::language_crystal().into()
  }
}

/// Helper lang that uses the uppercase expando for constant-position metavars.
#[derive(Clone, Copy, Debug)]
struct CrystalUpper;

impl Language for CrystalUpper {
  fn kind_to_id(&self, kind: &str) -> u16 {
    self
      .get_ts_language()
      .id_for_node_kind(kind, true)
  }
  fn field_to_id(&self, field: &str) -> Option<u16> {
    self
      .get_ts_language()
      .field_id_for_name(field)
      .map(|f| f.get())
  }
  fn expando_char(&self) -> char {
    UPPER_EXPANDO
  }
  fn pre_process_pattern<'q>(&self, query: &'q str) -> Cow<'q, str> {
    crate::pre_process_pattern(self.expando_char(), query)
  }
  fn build_pattern(&self, builder: &PatternBuilder) -> Result<Pattern, PatternError> {
    builder.build(|src| StrDoc::try_new(src, *self))
  }
}

impl LanguageExt for CrystalUpper {
  fn get_ts_language(&self) -> TSLanguage {
    crate::parsers::language_crystal().into()
  }
}

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

  #[test]
  fn test_crystal_class_metavar() {
    test_match("class $NAME\nend", "class Foo\nend");
    test_match("class $NAME\nend", "class Bar\nend");
    test_non_match("class $NAME\nend", "module Foo\nend");
  }

  #[test]
  fn test_crystal_module_metavar() {
    test_match("module $NAME\nend", "module Foo\nend");
    test_non_match("module $NAME\nend", "class Foo\nend");
  }

  // -- Scoped constants --

  #[test]
  fn test_crystal_scoped_constant() {
    test_match("Config::EXIT_OK", "Config::EXIT_OK");
    test_non_match("Config::EXIT_OK", "Config::EXIT_FAIL");
  }

  #[test]
  fn test_crystal_scoped_constant_metavar() {
    test_match("Config::$NAME", "Config::EXIT_OK");
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
