use clap::{Parser, Subcommand};

use crate::commands;

#[derive(Parser)]
#[command(name = "devops")]
#[command(about = "ZingoLabs infrastructure management CLI")]
pub struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Generate CRD manifests to stdout
    GenCrds,

    /// Snapshot management
    Snapshot {
        #[command(subcommand)]
        command: commands::snapshot::Command,
    },
}

pub fn run() -> anyhow::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::GenCrds => commands::gen_crds::run(),
        Command::Snapshot { command } => commands::snapshot::run(command),
    }
}
