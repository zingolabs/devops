use kube::CustomResource;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(CustomResource, Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[kube(
    group = "zcash.zingolabs.org",
    version = "v1alpha1",
    kind = "SnapshotSet",
    namespaced,
    status = "SnapshotSetStatus",
    printcolumn = r#"{"name":"Network","type":"string","jsonPath":".spec.network"}"#,
    printcolumn = r#"{"name":"Height","type":"integer","jsonPath":".spec.height"}"#,
    printcolumn = r#"{"name":"Ready","type":"boolean","jsonPath":".status.ready"}"#
)]
pub struct SnapshotSetSpec {
    /// Network (mainnet or testnet)
    pub network: Network,

    /// Block height at snapshot time
    pub height: u64,

    /// Zebra component snapshot
    pub zebra: ComponentSnapshot,

    /// Zaino component snapshot
    pub zaino: ComponentSnapshot,

    /// User-defined tags (e.g., "golden", "milestone")
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum Network {
    Mainnet,
    Testnet,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ComponentSnapshot {
    /// Software version at snapshot time
    pub version: String,

    /// Reference to the underlying VolumeSnapshot
    pub volume_snapshot: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotSetStatus {
    /// Whether all underlying VolumeSnapshots are ready
    #[serde(default)]
    pub ready: bool,

    /// Timestamp when snapshot was created
    pub created_at: Option<String>,

    /// URLs where this snapshot has been exported (R2, etc.)
    #[serde(default)]
    pub exported_to: Vec<String>,
}
