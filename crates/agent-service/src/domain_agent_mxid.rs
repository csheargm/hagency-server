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
/// Matrix's limit on a whole user ID, in bytes.
const MATRIX_ID_MAX: usize = 255;
/// Bytes kept free for the longest collision suffix (`-9999`).
const SUFFIX_RESERVE: usize = 5;
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
#[cfg(test)]
pub(crate) fn base_localpart(namespace: &str, owner_mxid: &str, display_name: &str) -> String {
    fitted_base(namespace, owner_mxid, display_name, usize::MAX).unwrap_or_default()
}

/// The base shortened (name first, then owner) so it is at most `max_len`
/// bytes; `None` when not even one character of each part fits.
pub(crate) fn fitted_base(namespace: &str, owner_mxid: &str, display_name: &str, max_len: usize) -> Option<String> {
    let owner_local = owner_mxid.trim_start_matches('@').split(':').next().unwrap_or_default();
    let mut owner = sanitize_part(owner_local, OWNER_PART_MAX, OWNER_FALLBACK);
    let mut name = sanitize_part(display_name, NAME_PART_MAX, NAME_FALLBACK);
    let room = max_len.checked_sub(namespace.len() + PART_SEPARATOR.len_utf8())?;
    if room < 2 {
        return None;
    }
    // Parts are already sanitised and never start with `-`, so re-sanitising
    // only truncates, and the first byte is a valid one-character fallback.
    if owner.len() + name.len() > room {
        name = sanitize_part(&name, room.saturating_sub(owner.len()).max(1), &name[..1]);
    }
    if owner.len() + name.len() > room {
        owner = sanitize_part(&owner, room - name.len(), &owner[..1]);
    }
    Some(format!("{namespace}{owner}{PART_SEPARATOR}{name}"))
}

/// The base itself, else `base-2`, `base-3`, …, skipping every taken localpart.
pub(crate) fn first_free(base: &str, taken: &BTreeSet<String>) -> Option<String> {
    std::iter::once(base.to_owned())
        .chain((2..=MAX_SUFFIX).map(|n| format!("{base}-{n}")))
        .find(|candidate| !taken.contains(candidate))
}

/// Picks the new Agent's puppet ID inside the caller's transaction. The lock
/// is held until commit, so two creates whose candidates overlap cannot both
/// pick one (today the domain store's single connection also serialises
/// writers; the lock keeps this true across processes).
pub(crate) async fn mint(
    db: &mut AsyncPgConnection,
    namespace: &str,
    server: &str,
    owner_mxid: &str,
    display_name: &str,
) -> Result<String> {
    // `@` + localpart + `-9999` + `:` + server must fit a Matrix ID.
    let max_local = MATRIX_ID_MAX.saturating_sub(2 + server.len() + SUFFIX_RESERVE);
    let base = fitted_base(namespace, owner_mxid, display_name, max_local)
        .ok_or(Error::Invalid("agent_mxid_too_long"))?;
    // Bases that can share a candidate (`x_anna` + `-2` and `x_anna-2`) always
    // share the owner part, so one lock per owner part serialises them.
    let owner_scope = base[namespace.len()..]
        .find(PART_SEPARATOR)
        .map_or(base.as_str(), |i| &base[..namespace.len() + i + 1]);
    sql_query("SELECT pg_advisory_xact_lock($1, hashtext($2))")
        .bind::<diesel::sql_types::Integer, _>(MINT_LOCK_CLASS)
        .bind::<Text, _>(owner_scope)
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
