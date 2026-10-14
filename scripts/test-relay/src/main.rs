use nostr_relay_builder::prelude::{BoxedFuture, Event, PolicyResult, WritePolicy};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

#[derive(Debug)]
struct AdmissionCounter(Arc<AtomicU64>);
impl WritePolicy for AdmissionCounter {
    fn admit_event<'a>(
        &'a self,
        _event: &'a Event,
        _addr: &'a std::net::SocketAddr,
    ) -> BoxedFuture<'a, PolicyResult> {
        Box::pin(async move {
            self.0.fetch_add(1, Ordering::Relaxed);
            PolicyResult::Accept
        })
    }
}
use nostr_relay_builder::{LocalRelay, RelayBuilder};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let port = match args.as_slice() {
        [] => 18181,
        [flag, value] if flag == "--port" => value.parse::<u16>()?,
        _ => return Err("usage: white-noise-sync-test-relay [--port <port>]".into()),
    };
    let admitted = Arc::new(AtomicU64::new(0));
    let relay = LocalRelay::new(
        RelayBuilder::default()
            .addr(IpAddr::V4(Ipv4Addr::LOCALHOST))
            .port(port)
            .max_connections(32)
            .write_policy(AdmissionCounter(admitted.clone())),
    );
    relay.run().await?;
    println!("{}", relay.url().await);
    tokio::signal::ctrl_c().await?;
    relay.shutdown();
    println!("admitted_events={}", admitted.load(Ordering::Relaxed));
    Ok(())
}
