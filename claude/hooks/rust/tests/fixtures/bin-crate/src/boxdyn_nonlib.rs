// Not a library crate (no src/lib.rs): Box<dyn Error> is allowed.
fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    Ok(())
}
