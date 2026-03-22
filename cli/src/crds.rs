use kube::CustomResourceExt;

mod snapshot_set;

pub use snapshot_set::SnapshotSet;

pub fn generate_all() -> anyhow::Result<String> {
    let mut output = String::new();

    output.push_str(&serde_yaml::to_string(&SnapshotSet::crd())?);

    Ok(output)
}
