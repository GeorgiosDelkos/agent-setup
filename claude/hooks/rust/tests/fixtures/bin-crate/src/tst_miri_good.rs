#[cfg(test)]
mod tests {
    #[test]
    #[cfg_attr(miri, ignore)] // calls into libc, which Miri cannot emulate
    fn a() {}

    #[test]
    #[cfg_attr(miri, ignore = "spawns a process")]
    fn b() {}
}
