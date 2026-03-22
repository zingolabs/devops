use clap::Subcommand;

#[derive(Subcommand)]
pub enum Command {
    /// List snapshots
    List {
        /// Filter by network
        #[arg(long)]
        network: Option<String>,

        /// Minimum height
        #[arg(long)]
        min_height: Option<u64>,
    },

    /// Create a new snapshot set
    Create {
        /// Network (testnet or mainnet)
        #[arg(long)]
        network: String,

        /// Tag the snapshot
        #[arg(long)]
        tag: Option<Vec<String>>,
    },

    /// Tag an existing snapshot
    Tag {
        /// Snapshot name
        name: String,

        /// Tags to add
        #[arg(long)]
        add: Option<Vec<String>>,

        /// Tags to remove
        #[arg(long)]
        remove: Option<Vec<String>>,
    },

    /// Delete a snapshot set
    Delete {
        /// Snapshot name
        name: String,

        /// Skip confirmation
        #[arg(long)]
        force: bool,
    },
}

pub fn run(command: Command) -> anyhow::Result<()> {
    match command {
        Command::List { network, min_height } => list(network, min_height),
        Command::Create { network, tag } => create(network, tag),
        Command::Tag { name, add, remove } => tag(name, add, remove),
        Command::Delete { name, force } => delete(name, force),
    }
}

fn list(_network: Option<String>, _min_height: Option<u64>) -> anyhow::Result<()> {
    todo!("snapshot list")
}

fn create(_network: String, _tag: Option<Vec<String>>) -> anyhow::Result<()> {
    todo!("snapshot create")
}

fn tag(_name: String, _add: Option<Vec<String>>, _remove: Option<Vec<String>>) -> anyhow::Result<()> {
    todo!("snapshot tag")
}

fn delete(_name: String, _force: bool) -> anyhow::Result<()> {
    todo!("snapshot delete")
}
