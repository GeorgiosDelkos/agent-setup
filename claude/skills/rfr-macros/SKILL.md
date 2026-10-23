---
name: rfr-macros
description: Use when writing or debugging Rust macros, both declarative (macro_rules!) and procedural (derive, attribute, function-like). Use when deciding whether a macro is worth its cost, choosing fragment specifiers, reasoning about hygiene and textual scoping, generating tests across types, or working with syn/quote.
---

# Rust for Rustaceans, Ch 7: Macros

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

## When to Use Declarative Macros

Source: RfR Ch 7 "When to Use Them" (TOC p. 102); RfR Ch 7 "So You Think You Want a Macro" (TOC p. 111)

Reach for a function, generic, or trait first. A macro is justified when those cannot
express the code:
- the same impl or test for many types, where a blanket impl is impossible or wrong;
- syntax a function cannot take: variadic arguments, identifiers to define, format strings;
- code that must expand at the call site (`$crate`-relative paths, `?` in the caller).

Macros cost readability, IDE support, and error-message quality. A few repetitions are
usually clearer written out.

## How Declarative Macros Work

Source: RfR Ch 7 "How They Work" (TOC p. 104); RfR Ch 7 index "abstract syntax tree (AST)", "grammar" (pp. 104-105), "token trees" (p. 105); Rust Reference, macros by example https://doc.rust-lang.org/reference/macros-by-example.html

A macro invocation's input is a token tree. The compiler tries each arm's matcher in
order, binds metavariables, and substitutes them into the transcriber. The output must
parse as whatever the call position expects (expression, statement, items, pattern, or
type).

```rust
macro_rules! my_vec {
    ($($element:expr),* $(,)?) => {{
        let mut v = Vec::new();
        $(v.push($element);)*
        v
    }};
}

let v = my_vec![1, 2, 3,];
assert_eq!(v, [1, 2, 3]);
```

## How to Write Declarative Macros

Source: RfR Ch 7 "How to Write Declarative Macros" (TOC p. 106); RfR Ch 7 index "fragment types" (p. 106), "matchers" (pp. 106-107), "transcribers", "metavariables" (p. 107); Rust Reference, macros by example

### Fragment specifiers

| Specifier | Matches |
|-----------|---------|
| `expr` | An expression. Edition 2024 also matches `_` and `const { .. }`; `expr_2021` keeps the old rule |
| `ty` | A type |
| `ident` | An identifier or keyword (not `_`) |
| `path` | A type-style path: `std::collections::HashMap<K, V>` |
| `pat` | A pattern, including top-level `A \| B` (edition 2021+); `pat_param` excludes it |
| `stmt` | A statement without its trailing `;` |
| `block` | A `{ .. }` block |
| `item` | An item: `fn`, `struct`, `impl`, ... |
| `lifetime` | A lifetime: `'a` |
| `meta` | Attribute contents: `derive(Debug)` |
| `vis` | A visibility qualifier, possibly empty |
| `literal` | A literal, optionally with a leading `-` |
| `tt` | One token tree: a token, or a `()`/`[]`/`{}` group |

Repetitions: `$( .. ),*` zero or more, `$( .. ),+` one or more, `$( .. )?` zero or one.
The separator is optional. Accept a trailing comma with `$(,)?`.

Arms are tried top to bottom and the first match wins, so put specific arms first. Once a
fragment other than `ident`, `lifetime`, or `tt` is parsed it becomes opaque, and later
macros cannot look inside it.

```rust
macro_rules! log_kv {
    ($msg:expr) => {
        eprintln!("{}", $msg)
    };
    ($msg:expr, $($key:ident = $val:expr),+ $(,)?) => {{
        eprint!("{}", $msg);
        $(eprint!(" {}={:?}", stringify!($key), $val);)+
        eprintln!();
    }};
}

log_kv!("starting");
log_kv!("request", path = "/health", status = 200);
```

### Hygiene

Source: RfR Ch 7 index "hygiene" (pp. 107-109); Rust Reference, macros by example, "Hygiene"

`macro_rules!` has mixed-site hygiene. Local variables and labels resolve where the macro
is defined, so a `let` inside the macro cannot clash with, or capture, a caller's local.
Everything else (functions, types, modules, other macros) resolves where the macro is
invoked.

```rust
macro_rules! make_map {
    ($($k:expr => $v:expr),* $(,)?) => {{
        // This `map` cannot collide with a caller's `map`.
        let mut map = std::collections::HashMap::new();
        $(map.insert($k, $v);)*
        map
    }};
}

let map = make_map!("a" => 1, "b" => 2);
assert_eq!(map["a"], 1);
```

Because items resolve at the call site, write paths to your own items as `$crate::path`,
and to std items as `::std::..` or `::core::..`. `$crate` does not bypass visibility; the
item must be public.

### Textual scoping and export

Source: RfR Ch 7 index "textual scoping" (p. 109); Rust Reference, macros by example, "Scoping, Exporting, and Importing"

- A `macro_rules!` macro is in scope from its definition onward, in source order, and
  into child modules declared after it. Using it above its definition is an error.
- For path-based use inside the crate, re-export it: `pub(crate) use my_macro;` after the
  definition.
- `#[macro_export]` makes it public at the crate root (`my_crate::my_macro!`), whatever
  module it is defined in.

```rust
mod util {
    macro_rules! square {
        ($x:expr) => {
            $x * $x
        };
    }
    pub(crate) use square;
}

fn area(side: u32) -> u32 {
    util::square!(side)
}
```

### Generating tests across types

Source: RfR Ch 7 index "test generation techniques" (p. 112); RfR errata print01-ch07-lst1-matcher.md

The book's declarative example generates a test battery per type
(`test_battery! { u8 as u8_tests, ... }`). The same idea:

```rust
macro_rules! int_tests {
    ($($t:ty as $name:ident),* $(,)?) => {
        $(
            #[cfg(test)]
            mod $name {
                #[test]
                fn display_parse_roundtrip() {
                    for v in [<$t>::MIN, <$t>::MAX, <$t>::default()] {
                        let s = v.to_string();
                        assert_eq!(s.parse::<$t>().expect("Display output parses"), v);
                    }
                }
            }
        )*
    };
}

int_tests! { u8 as u8_tests, i64 as i64_tests }
```

### Macro API checklist

Source: Rust API Guidelines C-EVOCATIVE, C-MACRO-ATTR, C-ANYWHERE, C-MACRO-VIS, C-MACRO-TY

- C-EVOCATIVE: input syntax looks like the Rust it produces.
- C-MACRO-ATTR: macros that emit items accept attributes (docs, derives, `cfg`) on each.
- C-ANYWHERE: item macros work at module level and inside functions; test both.
- C-MACRO-VIS: emitted items are private unless the caller writes `pub` (take a `$vis:vis`).
- C-MACRO-TY: a `$t:ty` input works with primitives, relative and absolute paths,
  `super::` paths, and generic types.

## Procedural Macros

Source: RfR Ch 7 "Types of Procedural Macros" (TOC p. 109); RfR Ch 7 index "derive macros" (pp. 110, 111), "attribute" (pp. 110, 112), "function-like macros" (pp. 110, 112)

Proc macros are Rust functions from `TokenStream` to `TokenStream`, compiled for the host
and run by the compiler. They live in a crate with `proc-macro = true`, which can export
only proc macros; put shared runtime types in a separate crate.

| Kind | Invoked as | Input | Output |
|------|-----------|-------|--------|
| Derive | `#[derive(Name)]` | The struct, enum, or union | Items added after it |
| Attribute | `#[name(args)]` | Attribute args and the item | Replaces the item |
| Function-like | `name!(..)` | Any tokens | Any tokens |

Examples below use `syn` 2 with `quote` 1.

```rust
// my_derive/src/lib.rs (crate with `proc-macro = true`)
use proc_macro::TokenStream;
use quote::quote;
use syn::{DeriveInput, parse_macro_input};

/// Implements `TypeName` by returning the type's identifier.
#[proc_macro_derive(TypeName)]
pub fn derive_type_name(input: TokenStream) -> TokenStream {
    let input = parse_macro_input!(input as DeriveInput);
    let name = &input.ident;
    let (impl_generics, ty_generics, where_clause) = input.generics.split_for_impl();
    let expanded = quote! {
        impl #impl_generics ::my_crate::TypeName for #name #ty_generics #where_clause {
            fn type_name() -> &'static str {
                ::core::stringify!(#name)
            }
        }
    };
    expanded.into()
}
```

```rust
// Attribute macro that rejects non-async functions with a spanned error.
use proc_macro::TokenStream;
use quote::quote;
use syn::{ItemFn, parse_macro_input};

#[proc_macro_attribute]
pub fn traced(_args: TokenStream, item: TokenStream) -> TokenStream {
    let func = parse_macro_input!(item as ItemFn);
    if func.sig.asyncness.is_none() {
        return syn::Error::new_spanned(&func.sig.fn_token, "#[traced] needs an async fn")
            .to_compile_error()
            .into();
    }
    let name = func.sig.ident.to_string();
    let ItemFn { attrs, vis, sig, block } = func;
    quote! {
        #(#attrs)*
        #vis #sig {
            ::tracing::trace!("enter {}", #name);
            #block
        }
    }
    .into()
}
```

| Crate | Role |
|-------|------|
| `proc_macro` | Compiler interface; usable only inside a proc-macro crate |
| `proc-macro2` | Same API usable anywhere, so the logic can be unit tested |
| `syn` | Parses tokens into a Rust syntax tree |
| `quote` | Turns quasi-quoted Rust back into tokens |

### Hygiene and spans

Source: RfR Ch 7 "How Do They Work?" (TOC p. 113); RfR Ch 7 index "TokenStream" (pp. 113-114), "spans" (pp. 114-115)

- Tokens made by `quote!` carry `Span::call_site()`: they resolve as if the caller had
  written them, so a generated `let x` can collide with the caller's code and a bare
  `Result` picks up the caller's alias. Use absolute paths (`::core::result::Result`,
  `::my_crate::Trait`), or `Span::mixed_site()` for `macro_rules!`-style locals.
- Give errors the span of the offending input (`syn::Error::new_spanned`,
  `quote_spanned!`) so the compiler points at the user's code.

### The cost of procedural macros

Source: RfR Ch 7 "The Cost of Procedural Macros" (TOC p. 110); RfR Ch 7 index "compile cost" (p. 110)

The book treats compile cost as the main reason for caution (detail not verified against
the text). Mechanically: a proc-macro crate and its dependencies (`syn`, `quote`) must
build before any crate that uses it, which serializes the build; the macro runs on every
compilation of each user; and its output is code that must then be compiled. Prefer
`macro_rules!` or plain generics when they suffice, and enable only the `syn` features
you use. Decorator-style macros such as `tracing::instrument` and `pin_project` (index
p. 113) are the cases where the cost usually pays off.

## Debugging Macros

Source: general Rust practice (not from the book)

```bash
cargo install cargo-expand
cargo expand path::to::module
```

- Fail early with a clear message from a dedicated arm:

```rust
macro_rules! only_struct {
    (struct $name:ident { $($body:tt)* }) => {
        struct $name { $($body)* }
    };
    ($($other:tt)*) => {
        compile_error!("only_struct! expects a struct definition");
    };
}

only_struct!(struct Point { x: i32, y: i32 });
```

- `trace_macros!` and `log_syntax!` exist but are nightly-only.

## Common Mistakes

Source: general Rust practice (not from the book); Rust API Guidelines C-MACRO-VIS, C-ANYWHERE

1. **A macro where a function or generic would do.**
2. **Bare paths in expansions**: write `$crate::item`, `::std::..`, `::core::..`.
3. **Assuming `macro_rules!` hygiene covers items**: only locals and labels are hygienic.
4. **Using a macro above its definition**: textual scoping; re-export with
   `pub(crate) use`.
5. **No trailing-comma support** (`$(,)?`).
6. **Emitted items that are always `pub`**: take `$vis:vis` (C-MACRO-VIS).
7. **Item macros tested only at module level** (C-ANYWHERE).
8. **Unspanned proc-macro errors**: use `syn::Error::new_spanned`.
