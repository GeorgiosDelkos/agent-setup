//! A correct solution of the interner task. The harness tests use it as the stub session's
//! work, which pins `tasks/interner/oracle.rs`: every oracle test must pass against it.

use std::collections::HashMap;
use std::fmt;

/// The name of one interned string, valid for the [`Interner`] that returned it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Symbol(u32);

/// Maps each distinct string to one [`Symbol`].
///
/// Every new string is copied twice, once per table. A lookup of a known string allocates
/// nothing.
#[derive(Default)]
pub struct Interner {
    symbols: HashMap<Box<str>, Symbol>,
    /// Indexed by the symbol's number.
    strings: Vec<Box<str>>,
}

impl Interner {
    /// Returns an empty interner.
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the symbol of `string`, the same one for the same contents.
    ///
    /// # Panics
    ///
    /// Panics at the 2^32nd distinct string: a symbol is a `u32`.
    pub fn intern(&mut self, string: &str) -> Symbol {
        if let Some(&symbol) = self.symbols.get(string) {
            return symbol;
        }
        let number = u32::try_from(self.strings.len());
        let symbol = Symbol(number.expect("fewer than 2^32 distinct strings are interned"));
        self.strings.push(string.into());
        self.symbols.insert(string.into(), symbol);
        symbol
    }

    /// Returns the string `symbol` names.
    ///
    /// # Panics
    ///
    /// May panic when `symbol` came from another interner.
    pub fn resolve(&self, symbol: Symbol) -> &str {
        &self.strings[symbol.0 as usize]
    }
}

impl fmt::Debug for Interner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Interner")
            .field("len", &self.strings.len())
            .finish_non_exhaustive()
    }
}
