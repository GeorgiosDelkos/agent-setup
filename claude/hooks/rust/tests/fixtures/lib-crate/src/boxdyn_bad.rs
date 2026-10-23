use std::error::Error;

pub fn parse(s: &str) -> Result<u8, Box<dyn Error>> {
    Ok(s.parse()?)
}

pub fn load() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    Ok(())
}

pub trait Source {
    fn read(&self) -> Result<u8, Box<dyn core::error::Error>>;
}

pub enum Failure {
    Other(Box<dyn Error + Send>),
}

pub struct Wrapper {
    pub inner: Box<dyn Error>,
}

pub type BoxError = Box<dyn std::error::Error + Send + Sync>;

pub fn multi_line(
    input: &str,
) -> Result<
    u8,
    Box<dyn Error>,
> {
    Ok(input.len() as u8)
}
