//! Readable, immutable puppet Matrix IDs for new personal Agents (ADR 0002):
//! `@<namespace><owner>_<name>[-N]:<server>`. Both parts are sanitised to
//! `[a-z0-9-]`, so the single `_` between them is the only boundary and no
//! owner/name split can be read two ways. Uniqueness is decided inside the
//! creating transaction under a per-base advisory lock; `puppet_mxid UNIQUE`
//! stays the final guard. Existing Agents keep their `agt_<ulid>` IDs.
use super::*;

/// Longest owner part kept from the owner's Matrix localpart.
pub(crate) const OWNER_PART_MAX: usize = 24;
/// Longest name part kept from the Agent's initial display name.
pub(crate) const NAME_PART_MAX: usize = 32;
/// Used when nothing of the owner localpart survives sanitising.
const OWNER_FALLBACK: &str = "user";
/// Used when nothing of the display name survives (e.g. a non-ASCII name).
const NAME_FALLBACK: &str = "agent";
/// Never produced by `sanitize_part`, so it marks the owner/name boundary.
const PART_SEPARATOR: char = '_';
/// Highest collision suffix tried before creation is refused.
const MAX_SUFFIX: u32 = 9999;
/// Advisory-lock class for mint serialisation (two-key space, so it cannot
/// meet the single-key locks used elsewhere).
const MINT_LOCK_CLASS: i32 = 0x4147_4d58; // "AGMX"

#[derive(diesel::QueryableByName)]
struct TakenMxid {
    #[diesel(sql_type = Text)]
    puppet_mxid: String,
}

/// Lowercase ASCII `[a-z0-9-]`: every other run of characters becomes one
/// `-`, edges are trimmed, and the result is capped at `cap` bytes.
pub(crate) fn sanitize_part(raw: &str, cap: usize, fallback: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for c in raw.chars().map(|c| c.to_ascii_lowercase()) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            if gap && !out.is_empty() {
                out.push('-');
            }
            gap = false;
            out.push(c);
        } else {
            gap = true;
        }
        if out.len() >= cap {
            break;
        }
    }
    out.truncate(cap);
    let trimmed = out.trim_end_matches('-');
    if trimmed.is_empty() { fallback.into() } else { trimmed.into() }
}

/// `<namespace><owner>_<name>`, the localpart before any collision suffix.
pub(crate) fn base_localpart(namespace: &str, owner_mxid: &str, display_name: &str) -> String {
    let owner_local = owner_mxid.trim_start_matches('@').split(':').next().unwrap_or_default();
    let owner = sanitize_part(owner_local, OWNER_PART_MAX, OWNER_FALLBACK);
    let name = sanitize_part(display_name, NAME_PART_MAX, NAME_FALLBACK);
    format!("{namespace}{owner}{PART_SEPARATOR}{name}")
}

/// The base itself, else `base-2`, `base-3`, …, skipping every taken localpart.
pub(crate) fn first_free(base: &str, taken: &BTreeSet<String>) -> Option<String> {
    std::iter::once(base.to_owned())
        .chain((2..=MAX_SUFFIX).map(|n| format!("{base}-{n}")))
        .find(|candidate| !taken.contains(candidate))
}

/// Picks the new Agent's puppet ID inside the caller's transaction. The lock
/// is held until commit, so two creates for the same base cannot both pick it.
pub(crate) async fn mint(
    db: &mut AsyncPgConnection,
    namespace: &str,
    server: &str,
    owner_mxid: &str,
    display_name: &str,
) -> Result<String> {
    let base = base_localpart(namespace, owner_mxid, display_name);
    sql_query("SELECT pg_advisory_xact_lock($1, hashtext($2))")
        .bind::<diesel::sql_types::Integer, _>(MINT_LOCK_CLASS)
        .bind::<Text, _>(&base)
        .execute(db)
        .await?;
    let prefix = format!("@{base}");
    let suffix = format!(":{server}");
    let taken = sql_query("SELECT puppet_mxid FROM hagency_agent_v1.agents WHERE left(puppet_mxid,length($1))=$1")
        .bind::<Text, _>(&prefix)
        .load::<TakenMxid>(db)
        .await?
        .into_iter()
        .filter_map(|row| Some(row.puppet_mxid.strip_prefix('@')?.strip_suffix(&suffix)?.to_owned()))
        .collect();
    let local = first_free(&base, &taken).ok_or(Error::Conflict("agent_name_exhausted"))?;
    Ok(format!("@{local}{suffix}"))
}

#[cfg(test)]
#[path = "domain_agent_mxid_tests.rs"]
mod tests;
