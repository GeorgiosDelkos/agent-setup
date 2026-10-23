use anyhow::Context;

fn f() -> eyre::Result<()> {
    Ok(())
}

fn g() {
    color_eyre::install().ok();
}
