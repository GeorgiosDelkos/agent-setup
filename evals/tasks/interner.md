In this crate, write a string interner for a compiler front end: `intern(&str)` returns a small
copyable symbol, the same symbol for the same string, and `resolve(symbol)` gives the string back.
Interning millions of short strings must not make one heap allocation per lookup. Include tests.
