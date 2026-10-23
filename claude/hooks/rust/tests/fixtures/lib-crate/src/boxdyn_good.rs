/// Parses a byte.
///
/// ```
/// # fn main() -> Result<(), Box<dyn std::error::Error>> {
/// let n = lib_crate::parse("1")?;
/// # Ok(())
/// # }
/// ```
pub fn parse(s: &str) -> Result<u8, std::num::ParseIntError> {
    // Not Box<dyn Error>: callers match on the concrete error.
    s.parse()
}

const NOTE: &str = "Box<dyn Error>";

struct Private {
    inner: Box<dyn std::error::Error>,
}

pub fn callback(f: Box<dyn Fn(std::io::Error)>) {}

pub fn body_only() {
    let _e: Box<dyn std::error::Error> = "x".into();
}

fn private_fn() -> Result<(), Box<dyn std::error::Error>> {
    Ok(())
}

#[cfg(test)]
mod tests {
    pub fn helper() -> Result<(), Box<dyn std::error::Error>> {
        Ok(())
    }
}

/// Doc example wrapper is a comment, not code.
/// # fn main() -> Result<(), Box<dyn std::error::Error>> { Ok(()) }
pub fn documented() {}
