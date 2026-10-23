#[cfg(test)]
mod tests {
    #[test]
    #[cfg_attr(miri, ignore)]
    fn a() {}

    #[test]
    #[cfg_attr(miri, ignore)] //
    fn b() {}
}
