use crate::crds;

pub fn run() -> anyhow::Result<()> {
    let output = crds::generate_all()?;
    print!("{}", output);
    Ok(())
}
