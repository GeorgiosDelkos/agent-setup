//! A binary root inside a library crate: ERR-BOXDYN and DOC-CANCEL do not apply here.

/// Runs the tool.
pub async fn run() -> Result<(), Box<dyn std::error::Error>> {
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    Ok(())
}
