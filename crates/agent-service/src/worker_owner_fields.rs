//! Keeps every live Agent's `io.hagency.owner` profile field set through the
//! Appservice: Agents created before the field existed, shared Agents (whose
//! owner is their manager) and any write that failed at creation.
use crate::{domain::DomainStore, matrix_client::MatrixClient};
use std::collections::HashSet;

const BATCH: i64 = 20;

/// One cursor pass per tick. A (puppet, owner) pair confirmed once is not
/// sent again in this process, so the steady state is one query per tick.
#[derive(Default)]
pub(crate) struct OwnerFieldSweep {
    cursor: String,
    confirmed: HashSet<(String, String)>,
}

impl OwnerFieldSweep {
    pub(crate) async fn run(&mut self, domain: &DomainStore, matrix: &MatrixClient) {
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
