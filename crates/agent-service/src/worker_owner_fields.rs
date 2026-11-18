//! Keeps every live Agent's `io.hagency.owner` profile field set through the
//! Appservice: Agents created before the field existed, shared Agents (whose
//! owner is their manager) and any write that failed at creation.
use crate::{domain::DomainStore, matrix_client::MatrixClient};
use std::collections::HashSet;
use std::time::{Duration, Instant};

const BATCH: i64 = 5;
/// The most one tick spends here, so the cleanup loop's other queues are
/// never held behind slow profile requests (each may take 8 s).
const TICK_BUDGET: Duration = Duration::from_secs(3);
/// Confirmed pairs are checked again this often: a value confirmed while an
/// older homeserver still let the puppet write it must not stay trusted.
const RECHECK: Duration = Duration::from_secs(3600);

/// Cursor pass over live Agents. A (puppet, owner) pair confirmed within
/// [`RECHECK`] is skipped, so the steady state is one query per tick.
pub(crate) struct OwnerFieldSweep {
    cursor: String,
    confirmed: HashSet<(String, String)>,
    confirmed_since: Instant,
}

impl Default for OwnerFieldSweep {
    fn default() -> Self {
        Self { cursor: String::new(), confirmed: HashSet::new(), confirmed_since: Instant::now() }
    }
}

impl OwnerFieldSweep {
    pub(crate) async fn run(&mut self, domain: &DomainStore, matrix: &MatrixClient) {
        if self.confirmed_since.elapsed() >= RECHECK {
            self.confirmed.clear();
            self.confirmed_since = Instant::now();
        }
        // Out of budget: the row in flight is retried on the next full pass.
        let _ = tokio::time::timeout(TICK_BUDGET, self.pass(domain, matrix)).await;
    }
    async fn pass(&mut self, domain: &DomainStore, matrix: &MatrixClient) {
        let rows = match domain.owner_field_candidates(&self.cursor, BATCH).await {
            Ok(rows) => rows,
            Err(error) => {
                crate::worker_pass::report_pass::<()>("owner_fields", Err(error));
                return;
            }
        };
        if rows.is_empty() {
            self.cursor.clear();
        }
        for row in rows {
            self.cursor.clone_from(&row.id);
            let pair = (row.puppet_mxid, row.owner_mxid);
            if self.confirmed.contains(&pair) {
                continue;
            }
            match matrix.ensure_owner_field(&pair.0, &pair.1).await {
                Ok(()) => {
                    self.confirmed.insert(pair);
                }
                // Retried on the next full pass; readers fall back to the roster.
                Err(error) => tracing::warn!(stage = "owner_field", %error, "Agent owner field not set; retrying next pass"),
            }
        }
    }
}
