use axum::{Router, routing::get};
use clap::Parser;
use std::net::SocketAddr;
use thiserror::Error;

#[derive(Debug, Parser)]
struct Config {
    #[arg(long, env = "LISTEN_ADDR", default_value = "0.0.0.0:3000")]
    listen_addr: SocketAddr,
}

#[derive(Debug, Error)]
enum MainError {
    #[error("failed to parse CLI: {0}")]
    Cli(#[from] clap::Error),
    #[error("server error: {0}")]
    Server(#[from] std::io::Error),
}

#[tokio::main]
async fn main() -> Result<(), MainError> {
    let config = Config::parse();

    let app = Router::new().route("/health", get(health));
    let listener = tokio::net::TcpListener::bind(config.listen_addr).await?;

    axum::serve(listener, app).await?;

    Ok(())
}

async fn health() -> &'static str {
    "ok"
}
