---
name: rfr-ffi
description: Use when writing FFI code between Rust and C/C++, declaring or exporting extern functions, matching types across the boundary (repr(C), CStr/CString, nullable and opaque pointers), deciding who allocates and frees, or wiring callbacks. Use when working with bindgen/cbindgen/cxx, linking native libraries, or handling panics at the FFI boundary.
---

# Rust for Rustaceans, Ch 11: Foreign Function Interfaces

Book page numbers come from the publisher's detailed TOC and index; the book text beyond the free Ch 1 sample was not available, so sections name the book's topic and page, never quote it.

All examples use edition 2024 syntax: `unsafe extern "C" { .. }` blocks and
`#[unsafe(no_mangle)]` (https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-extern.html,
https://doc.rust-lang.org/edition-guide/rust-2024/unsafe-attributes.html).

## Calling C from Rust

Source: RfR Ch 11 "Crossing Boundaries with extern" (TOC p. 194); RfR Ch 11 "Symbols" (TOC p. 194); RfR Ch 11 index "static linking", "dynamic linking" (pp. 195-198); Edition Guide "Unsafe extern blocks"

An `extern` block is a promise that the signatures match the foreign definitions. A wrong
signature is undefined behaviour, which is why edition 2024 requires `unsafe extern`.
Items default to `unsafe` to call; mark an item `safe` only when every possible argument
is sound (for example `sqrt(f64)`).

```rust
use std::ffi::c_char;

unsafe extern "C" {
    /// libm: defined for every `f64`, so callers need no `unsafe`.
    pub safe fn sqrt(x: f64) -> f64;

    /// libc: `s` must point to a NUL-terminated string.
    pub unsafe fn strlen(s: *const c_char) -> usize;
}

fn main() {
    assert_eq!(sqrt(4.0), 2.0);

    let s = c"hello"; // C string literal: a `&'static CStr`, stable since 1.77
    // SAFETY: `s` is a NUL-terminated `'static` string, the only requirement of `strlen`.
    let len = unsafe { strlen(s.as_ptr()) };
    assert_eq!(len, 5);
}
```

### Linking

```rust
use std::ffi::c_char;

// Link against the system zlib (`libz.so` / `libz.dylib` / `z.lib`).
#[link(name = "z")]
unsafe extern "C" {
    /// Returns a pointer to a static NUL-terminated version string.
    safe fn zlibVersion() -> *const c_char;
}
```

For libraries that are not on the system search path, emit link directives from
`build.rs` (the `cargo::` prefix needs Cargo 1.77+):

```rust,ignore
// ignore: build script fragment; needs a real library to link.
fn main() {
    println!("cargo::rustc-link-search=native=/opt/mylib/lib");
    println!("cargo::rustc-link-lib=static=mylib"); // or dylib=mylib
}
```

Static linking copies the library into your artifact; dynamic linking needs the library
at run time. Pick one per library and say which in the crate docs.

## Exposing Rust to C

Source: RfR Ch 11 index "#[no_mangle] attribute" (pp. 196, 205); Edition Guide "Unsafe attributes"

```rust
use std::ffi::c_int;

/// Callable from C as `int mylib_add(int, int);`.
#[unsafe(no_mangle)]
pub extern "C" fn mylib_add(a: c_int, b: c_int) -> c_int {
    a.wrapping_add(b)
}
```

- `no_mangle` exports the symbol under its Rust name. It is an unsafe attribute because
  two symbols with the same name across the whole link are undefined behaviour. Prefix
  exported names with the library name.
- `#[unsafe(export_name = "...")]` exports under a different name.
- Generate the C header with cbindgen (below) rather than writing it by hand.

## Calling Conventions

Source: RfR Ch 11 "Calling Conventions" (TOC p. 198); RfR Ch 11 index "RFC 2945" (p. 198); Rust Reference "Panics" (https://doc.rust-lang.org/reference/panic.html); Rust 1.81 release notes

| ABI string | Use |
|---|---|
| `"C"` | The platform C convention. The default for FFI. |
| `"system"` | The OS API convention: `stdcall` on 32-bit x86 Windows, `"C"` elsewhere. Use for Win32 APIs. |
| `"C-unwind"`, `"system-unwind"` | As above, but unwinding may cross the boundary (RFC 2945, stable since 1.71). |

Always write the ABI string; `extern fn` without one means `"C"` but hides the intent.

Unwinding rules:
- Since Rust 1.81, a Rust panic that reaches the boundary of an `extern "C"` function
  **aborts the process**. It is no longer undefined behaviour.
- A foreign exception (C++ `throw`, `longjmp`-style unwinding) that unwinds into Rust
  through a function declared `"C"` is undefined behaviour. Declare such functions
  `"C-unwind"`.
- Calling a Rust `extern "C-unwind"` function that panics from C code built without
  unwind support (for example `-fno-exceptions`) is undefined behaviour.

## Panics at the Boundary

Source: RfR Ch 11 index "panics" (p. 204); Rust 1.81 release notes (https://blog.rust-lang.org/2024/09/05/Rust-1.81.0/)

Abort is sound but rarely what a library caller wants. To report a panic as an error
code instead, catch it:

```rust
use std::ffi::c_int;
use std::panic::{self, AssertUnwindSafe};

fn parse_config(input: &[u8]) -> Option<u32> {
    input.first().map(|&b| u32::from(b))
}

/// Returns 0 on success, -1 on a parse error, -2 if Rust code panicked.
#[unsafe(no_mangle)]
pub extern "C" fn mylib_check(byte: u8) -> c_int {
    // `AssertUnwindSafe`: nothing observable survives the call if it panics.
    let result = panic::catch_unwind(AssertUnwindSafe(|| parse_config(&[byte])));
    match result {
        Ok(Some(_)) => 0,
        Ok(None) => -1,
        Err(_panic) => -2,
    }
}
```

Use `extern "C-unwind"` instead only when the caller is C++ (or other code) that is built
to let a Rust panic pass through its frames.

## Type Matching

Source: RfR Ch 11 "Type Matching" (TOC p. 200); RfR Ch 11 index "tagged unions" (p. 202), "niche optimization" (p. 202); RfR errata print01-ch11-niche-ffi.md; std docs `std::option` "Representation"

| C type | Rust type | Notes |
|---|---|---|
| `int`, `unsigned int` | `c_int`, `c_uint` | Usually 32-bit, platform-defined |
| `long` | `c_long` | 32-bit on Windows and on 32-bit Unix; 64-bit on 64-bit Unix |
| `char` | `c_char` | `i8` or `u8` depending on the platform |
| `size_t` | `usize` | Matches on mainstream targets |
| `void *` | `*mut c_void` | |
| `bool` / `_Bool` | `bool` | |
| `float`, `double` | `f32`, `f64` | |
| `T *` that may be null | `Option<NonNull<T>>`, `Option<&T>`, `Option<&mut T>` | Same ABI as a nullable pointer |
| function pointer that may be null | `Option<extern "C" fn(..)>` | Same ABI as a nullable function pointer |

Use the `c_*` aliases from `std::ffi` (also `core::ffi`), not `i32`/`i64`, so the
declaration is right on every platform.

**Nullable pointers.** std guarantees that `Option<T>` has the same size, alignment and
call ABI as `T` for `&T`, `&mut T`, `NonNull<T>`, `Box<T>` and function pointers, with
`None` as null. `Option<*mut T>` gets no such niche, because a raw pointer can already be
null (errata print01-ch11-niche-ffi.md corrects the book on this).

```rust
use std::ffi::c_int;
use std::ptr::NonNull;

unsafe extern "C" {
    /// May return null. `Option<NonNull<_>>` makes callers handle that.
    fn lookup(key: c_int) -> Option<NonNull<c_int>>;
    /// `cb` may be null.
    fn set_handler(cb: Option<extern "C" fn(c_int)>);
}
```

**Structs and enums.** `#[repr(C)]` gives C field order, alignment and padding. A
fieldless `#[repr(C)]` enum must only ever hold a declared discriminant: receiving an
unknown value from C into the enum type is undefined behaviour, so take a `c_int` and
convert with `TryFrom`. Data-carrying enums with `#[repr(C)]` or `#[repr(C, u8)]` have a
defined tagged-union layout (RFC 2195); the hand-written equivalent:

```rust
use std::ffi::c_char;

#[repr(C)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub enum ValueTag {
    Integer = 0,
    Float = 1,
    Text = 2,
}

#[repr(C)]
pub struct TaggedValue {
    pub tag: ValueTag,
    pub payload: ValuePayload,
}

/// Which field is valid is given by `TaggedValue::tag`.
#[repr(C)]
pub union ValuePayload {
    pub integer: i64,
    pub float: f64,
    pub text: *const c_char,
}
```

## Strings

Source: general Rust practice (not from the book); std docs `CStr`, `CString`

| Direction | Type | Notes |
|---|---|---|
| Rust to C | `CString::new(s)?.as_ptr()`, or a `c"..."` literal | Fails on interior NUL; keep the `CString` alive while C uses the pointer |
| C to Rust, borrowed | `CStr::from_ptr(p)`, then `to_str()` or `to_string_lossy()` | No copy; lifetime is unchecked |
| Rust to C, ownership transferred | `CString::into_raw` | C must hand it back to `CString::from_raw`, never `free` it |

```rust
use std::ffi::{CStr, CString, NulError, c_char};

unsafe extern "C" {
    fn strlen(s: *const c_char) -> usize;
}

fn c_len(s: &str) -> Result<usize, NulError> {
    let owned = CString::new(s)?;
    // SAFETY: `owned` is NUL-terminated and outlives the call; `strlen` does not keep `s`.
    Ok(unsafe { strlen(owned.as_ptr()) })
}

/// # Safety
///
/// 1. `p` is non-null and points to a NUL-terminated string.
/// 2. The string is neither modified nor freed for the lifetime `'a`.
unsafe fn borrow_c_str<'a>(p: *const c_char) -> &'a CStr {
    // SAFETY: preconditions 1 and 2 are exactly the requirements of `CStr::from_ptr`.
    unsafe { CStr::from_ptr(p) }
}
```

Avoid: `CString::new(s).unwrap().as_ptr()` in one expression. The temporary `CString` is
dropped at the end of the statement and the pointer dangles.

## Allocations

Source: RfR Ch 11 "Allocations" (TOC p. 202); RfR Ch 11 index "caller-managed memory" (pp. 203-204), "implementation-managed memory" (p. 203)

Memory must be freed by the allocator that allocated it.
- Memory from C `malloc` goes back to C `free` (or the library's own `*_free`), never to
  `Box::from_raw` or `drop`.
- Memory from Rust (`Box::into_raw`, `CString::into_raw`, `Vec`) goes back to Rust, so a
  Rust library exports a matching `*_free` function.
- Two designs: **implementation-managed** (the library allocates and exports
  `new`/`free`, as below) and **caller-managed** (the caller passes a buffer and its
  length, and the library writes into it). Caller-managed avoids cross-allocator
  mistakes and suits fixed-size outputs.

### Opaque handles exported to C

```rust
use std::ffi::c_int;

/// Opaque to C: the header only declares `typedef struct Context Context;`.
pub struct Context {
    bytes_seen: usize,
}

impl Context {
    fn process(&mut self, data: &[u8]) -> Result<(), EmptyInput> {
        if data.is_empty() {
            return Err(EmptyInput);
        }
        self.bytes_seen += data.len();
        Ok(())
    }
}

#[derive(Debug)]
struct EmptyInput;

/// Returns a new context. Free it with `context_free`.
#[unsafe(no_mangle)]
pub extern "C" fn context_new() -> *mut Context {
    Box::into_raw(Box::new(Context { bytes_seen: 0 }))
}

/// # Safety
///
/// 1. `ctx` is null, or was returned by `context_new` and not yet passed to `context_free`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn context_free(ctx: *mut Context) {
    if ctx.is_null() {
        return;
    }
    // SAFETY: by precondition 1 a non-null `ctx` came from `Box::into_raw` in
    // `context_new` and has not been freed, so we own it and rebuild the `Box` once.
    drop(unsafe { Box::from_raw(ctx) });
}

/// Returns 0 on success, -1 on a null argument or empty input.
///
/// # Safety
///
/// 1. `ctx` is null, or a live pointer from `context_new` that no other thread uses
///    during this call.
/// 2. If `len > 0`, `data` is null or points to `len` initialized bytes that stay
///    unchanged during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn context_process(ctx: *mut Context, data: *const u8, len: usize) -> c_int {
    // SAFETY: by precondition 1 a non-null `ctx` is valid, aligned and not aliased,
    // so a unique reference for the duration of this call is sound.
    let Some(ctx) = (unsafe { ctx.as_mut() }) else {
        return -1;
    };
    let data: &[u8] = if len == 0 {
        &[]
    } else if data.is_null() {
        return -1;
    } else {
        // SAFETY: by precondition 2 `data` points to `len` initialized bytes in one
        // allocation; `u8` has alignment 1, and the bytes are not mutated meanwhile.
        unsafe { std::slice::from_raw_parts(data, len) }
    };
    match ctx.process(data) {
        Ok(()) => 0,
        Err(EmptyInput) => -1,
    }
}
```

## Pointer Confusion and Opaque Foreign Types

Source: RfR Ch 11 index "opaque pointers", "void pointers" (p. 206); RfR errata print01-ch11-c_void.md; Rustonomicon "Representing opaque structs" (https://doc.rust-lang.org/nomicon/ffi.html)

Do not declare every foreign handle as `*mut c_void`: then a `*mut Db` and a
`*mut Cursor` are interchangeable and the compiler cannot catch a swap. Give each foreign
type its own opaque Rust type. The book uses `#[repr(transparent)]` wrappers over
`c_void` (the errata corrects its claim that these are zero-sized: `c_void` has size 1).
The Rustonomicon form below also makes the type `!Send`, `!Sync` and `!Unpin`, which is
the safe default for memory owned by C:

```rust
use std::marker::{PhantomData, PhantomPinned};

#[repr(C)]
pub struct Db {
    _data: [u8; 0],
    _marker: PhantomData<(*mut u8, PhantomPinned)>,
}

#[repr(C)]
pub struct Cursor {
    _data: [u8; 0],
    _marker: PhantomData<(*mut u8, PhantomPinned)>,
}

unsafe extern "C" {
    fn db_open() -> *mut Db;
    fn db_cursor(db: *mut Db) -> *mut Cursor;
    fn cursor_close(cursor: *mut Cursor); // passing a `*mut Db` here is a type error
}
```

## Send and Sync of FFI Wrappers

Source: RfR Ch 11 "Safety" (TOC p. 204); RfR Ch 11 index "Send trait", "Sync trait" (pp. 205-206)

A wrapper holding a raw pointer is automatically `!Send` and `!Sync`. That is correct
until you check what the C library allows. Add the impls only for what its docs promise:

| C library says | Rust wrapper |
|---|---|
| A handle may be used from any thread, one at a time | `unsafe impl Send`; mutating methods take `&mut self` |
| Concurrent calls on one handle are safe | also `unsafe impl Sync` |
| Uses thread-local state, or must be freed on the creating thread | neither |

```rust
use std::ffi::c_void;
use std::ptr::NonNull;

pub struct Engine {
    raw: NonNull<c_void>,
}

// SAFETY: libengine documents that a handle may move between threads as long as calls
// are not concurrent. `Engine` is not `Sync`, so at most one thread calls into a given
// handle at a time.
unsafe impl Send for Engine {}
```

## Callbacks

Source: RfR Ch 11 "Callbacks" (TOC p. 204)

A C callback API takes a function pointer plus a `void *` user-data pointer. Pass a Rust
closure as a monomorphized trampoline plus a pointer to the closure:

```rust
use std::ffi::{c_int, c_void};

unsafe extern "C" {
    /// Calls `cb(data, event)` for each pending event, synchronously, then returns.
    /// Does not keep `cb` or `data` after returning.
    fn poll_events(cb: unsafe extern "C" fn(*mut c_void, c_int), data: *mut c_void);
}

/// # Safety
///
/// 1. `data` points to a live `F` that nothing else accesses during this call.
unsafe extern "C" fn trampoline<F: FnMut(c_int)>(data: *mut c_void, event: c_int) {
    // SAFETY: by precondition 1 `data` is an exclusive pointer to a live `F`.
    let callback = unsafe { &mut *data.cast::<F>() };
    // A panic here aborts the process (extern "C" boundary); see "Panics at the Boundary".
    callback(event);
}

pub fn for_each_event<F: FnMut(c_int)>(mut callback: F) {
    let data = (&raw mut callback).cast::<c_void>();
    // SAFETY: `poll_events` calls `trampoline::<F>` only before it returns, while
    // `callback` is alive in this frame and not otherwise borrowed, which discharges
    // the trampoline's precondition 1. It keeps neither pointer afterwards.
    unsafe { poll_events(trampoline::<F>, data) };
}
```

If C keeps the callback after the registering call returns, the closure must outlive the
registration: box it (`Box::into_raw(Box::new(callback))`), and free it in an
unregister function or in the C library's "user data destroy" callback.

## bindgen, cbindgen, cxx

Source: RfR Ch 11 "bindgen and Build Scripts" (TOC p. 207); RfR Ch 11 index "cbindgen library" (p. 208), "C++" (p. 209); bindgen CHANGELOG 0.71.0

**bindgen** (C headers to Rust) runs from `build.rs`. Since 0.71 it emits `unsafe extern`
blocks when the configured Rust target is 1.82 or later, as edition 2024 requires.

```rust,ignore
// ignore: build script; needs the `bindgen` build-dependency and libclang.
use std::path::PathBuf;

fn main() {
    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("wrapper.h parses with libclang");
    let out = PathBuf::from(std::env::var("OUT_DIR").expect("cargo sets OUT_DIR"));
    bindings
        .write_to_file(out.join("bindings.rs"))
        .expect("OUT_DIR is writable");
}
```

Then `include!(concat!(env!("OUT_DIR"), "/bindings.rs"));` in a private `ffi` (or
`-sys` crate) module.

**cbindgen** (Rust to C header): `cbindgen --crate mylib --output mylib.h`, configured by
`cbindgen.toml`:

```toml
language = "C"
include_guard = "MYLIB_H"
```

**cxx** generates both sides for C++ from one bridge definition, and checks the
signatures against each other, which removes the hand-matched `extern` block.

## Safe Wrapper Pattern

Source: RfR Ch 11 "Safety" (TOC p. 204); general Rust practice (not from the book)

Keep raw declarations in a private module (or a `-sys` crate) and expose a safe type that
upholds every precondition:

```rust
use std::ffi::{CString, NulError, c_char, c_int};

mod ffi {
    use std::ffi::{c_char, c_int};

    unsafe extern "C" {
        /// Returns a descriptor >= 0, or -1. `path` must be NUL-terminated.
        pub fn raw_open(path: *const c_char) -> c_int;
        /// `fd` must be open; it is invalid afterwards.
        pub fn raw_close(fd: c_int) -> c_int;
        /// Reads up to `len` bytes into `buf`; returns the count or -1.
        pub fn raw_read(fd: c_int, buf: *mut u8, len: usize) -> isize;
    }
}

#[derive(Debug, thiserror::Error)]
pub enum FileError {
    #[error("path contains a NUL byte")]
    Nul(#[from] NulError),
    #[error("failed to open {path}")]
    Open { path: String },
    #[error("read failed")]
    Read,
}

/// An open descriptor; closed on drop.
#[derive(Debug)]
pub struct FileHandle(c_int);

impl FileHandle {
    pub fn open(path: &str) -> Result<Self, FileError> {
        let c_path = CString::new(path)?;
        let ptr: *const c_char = c_path.as_ptr();
        // SAFETY: `ptr` is NUL-terminated and `c_path` outlives the call.
        let fd = unsafe { ffi::raw_open(ptr) };
        if fd < 0 {
            return Err(FileError::Open { path: path.to_owned() });
        }
        Ok(Self(fd))
    }

    pub fn read(&mut self, buf: &mut [u8]) -> Result<usize, FileError> {
        // SAFETY: `self.0` is open (only `Drop` closes it), and `buf` is a valid,
        // exclusively borrowed region of exactly `buf.len()` bytes.
        let n = unsafe { ffi::raw_read(self.0, buf.as_mut_ptr(), buf.len()) };
        usize::try_from(n).map_err(|_| FileError::Read)
    }
}

impl Drop for FileHandle {
    fn drop(&mut self) {
        // SAFETY: `self.0` is open and this is the only place that closes it.
        // A close error cannot be reported from `drop`, so it is ignored.
        let _ = unsafe { ffi::raw_close(self.0) };
    }
}
```

## Common Mistakes

Source: general Rust practice (not from the book)

1. **Passing a Rust `&str`/`String` pointer as a C string**: Rust strings are not
   NUL-terminated. Use `CString`, `CStr` or `c"..."`.
2. **Dropping a `CString` while C still holds its pointer**: the pointer dangles.
3. **Letting a panic reach an `extern "C"` boundary**: since 1.81 it aborts. Catch it if
   the caller should get an error code.
4. **Missing `#[repr(C)]`** on types that cross the boundary: Rust layout is unspecified.
5. **Fixed-width types for C integers**: use `c_int`/`c_long`, not `i32`/`i64`.
6. **Dereferencing without a null check**: map to `Option` with `as_ref`/`as_mut`, or
   take `Option<NonNull<T>>`.
7. **Freeing with the wrong allocator**: never `Box::from_raw` a pointer from `malloc`.
8. **`*mut c_void` for every handle**: use distinct opaque types.
9. **Fieldless enums received from C**: take an integer and convert; an unknown
   discriminant in the enum type is undefined behaviour.
