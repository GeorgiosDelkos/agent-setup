//! A correct solution of the actor-counter task. The harness tests use it as the stub
//! session's work, which pins `tasks/actor-counter/oracle.rs`: every oracle test must pass
//! against it. It needs Tokio's `rt` feature for [`tokio::spawn`] and `sync` for the channels.

use std::collections::HashMap;
use std::error::Error;
use std::fmt;

use tokio::sync::{mpsc, oneshot};

/// Requests the service holds before senders wait. Arbitrary: any bound keeps memory flat
/// when callers are faster than the service, which is what the mailbox is bounded for.
const MAILBOX: usize = 64;

/// A handle to the counter service. Cloning it is cheap, and the service stops when the last
/// handle is dropped.
#[derive(Debug, Clone)]
pub struct Counter {
    requests: mpsc::Sender<Request>,
}

#[derive(Debug)]
enum Request {
    Increment(String),
    Get(String, oneshot::Sender<u64>),
    Snapshot(oneshot::Sender<HashMap<String, u64>>),
}

/// The service task is gone, so the request was not served.
#[derive(Debug)]
pub struct Stopped;

impl fmt::Display for Stopped {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("counter service stopped")
    }
}

impl Error for Stopped {}

/// Starts the service on the current Tokio runtime and returns a handle to it.
///
/// # Panics
///
/// Panics when called outside a Tokio runtime.
pub fn spawn() -> Counter {
    let (requests, mailbox) = mpsc::channel(MAILBOX);
    // Detached: the task ends by itself once every handle is dropped and the mailbox closes.
    drop(tokio::spawn(serve(mailbox)));
    Counter { requests }
}

impl Counter {
    /// Adds one to `key`. Returns once the request is queued, waiting while the mailbox is
    /// full; requests are served in order, so a later read through any handle sees it.
    ///
    /// # Errors
    ///
    /// Returns [`Stopped`] when the service is gone.
    pub async fn increment(&self, key: &str) -> Result<(), Stopped> {
        let request = Request::Increment(key.to_owned());
        self.requests.send(request).await.map_err(|_| Stopped)
    }

    /// Returns the count of `key`, 0 when it was never incremented.
    ///
    /// # Errors
    ///
    /// Returns [`Stopped`] when the service is gone.
    pub async fn get(&self, key: &str) -> Result<u64, Stopped> {
        let (reply, count) = oneshot::channel();
        let request = Request::Get(key.to_owned(), reply);
        self.requests.send(request).await.map_err(|_| Stopped)?;
        count.await.map_err(|_| Stopped)
    }

    /// Returns a copy of every count.
    ///
    /// # Errors
    ///
    /// Returns [`Stopped`] when the service is gone.
    pub async fn snapshot(&self) -> Result<HashMap<String, u64>, Stopped> {
        let (reply, counts) = oneshot::channel();
        self.requests
            .send(Request::Snapshot(reply))
            .await
            .map_err(|_| Stopped)?;
        counts.await.map_err(|_| Stopped)
    }
}

/// Owns the counts and serves requests until every handle is dropped.
async fn serve(mut mailbox: mpsc::Receiver<Request>) {
    let mut counts = HashMap::<String, u64>::new();
    while let Some(request) = mailbox.recv().await {
        match request {
            Request::Increment(key) => *counts.entry(key).or_default() += 1,
            // A caller that stopped waiting for its answer is not an error of the service.
            Request::Get(key, reply) => drop(reply.send(counts.get(&key).copied().unwrap_or(0))),
            Request::Snapshot(reply) => drop(reply.send(counts.clone())),
        }
    }
}
