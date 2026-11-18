In this crate, write a string interner for a compiler front end: `intern(&str)` returns a small
copyable symbol, the same symbol for the same string, and `resolve(symbol)` gives the string back.
Interning millions of short strings must not make one heap allocation per lookup. Include tests.

The crate root exports `Interner` and `Symbol`. `Interner::new()` makes an empty interner,
`intern(&mut self, &str)` returns a `Symbol`, and `resolve(&self, Symbol)` returns the `&str`.
`Symbol` is `Copy` and `Eq`.
