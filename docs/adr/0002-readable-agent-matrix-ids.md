# ADR 0002: Readable Matrix IDs for new Agents

Status: accepted for the demo fork (2026-11-17, Chris); proposed upstream.

## Context

Every Agent puppet was `@_hagency_agt_<ulid>:<server>`
(e.g. `@_hagency_agt_01m7k5g5n36gcamvq8f8m07e6n:localhost:8450`). The ID is
stable but tells a person nothing. Mentions, member lists, git co-author
trailers and logs show it wherever a client has no display name.

## Decision

1. **Format.** A new personal Agent (`DomainStore::create_agent`) gets
   `@<namespace><owner>_<name>[-N]:<server>`. With the production namespace
   `_hagency_`: `@_hagency_csheargm_anna-claude:localhost:8450`.
   - `owner` is the owner's Matrix localpart. `name` is the Agent's
     *initial* display name.
   - Both are sanitised the same way: ASCII lowercased, every run of other
     characters becomes one `-`, edges trimmed, capped (owner at 24 bytes,
     name at 32). If nothing survives, owner falls back to `user` and name to
     `agent`, so a fully non-ASCII name like `安娜` gives `…_agent`.
   - The Agent's entity ID stays `agt_<ulid>`. Only the puppet Matrix ID
     changes form.
2. **Boundary.** The sanitised alphabet is `[a-z0-9-]`, so the single `_`
   after the namespace is the only owner/name boundary. Owner `a_b` + name `c`
   gives `a-b_c`. Owner `a` + name `b_c` gives `a_b-c`. No ID can be read two
   ways. Owners that sanitise alike (`a_b` and `a-b`) can still produce the
   same base, which the collision rule handles.
3. **Collisions.** Inside the creating transaction, the server takes
   `pg_advisory_xact_lock(<mint class>, hashtext(base))`. It then reads every
   puppet ID starting with that base and picks the base itself, or the first
   free `-2`, `-3`, … up to `-9999`. If all are taken it refuses with
   `agent_name_exhausted`. `agents.puppet_mxid UNIQUE` remains the final
   guard. Concurrent creates of one name across separate connections get
   distinct IDs (tested). The check runs against the `agents` table: rows are
   never deleted, so a retired Agent's ID is never reissued. Old-form IDs are
   in the same table, so an owner literally named `agt` cannot collide either.
4. **Reservation.** The Appservice's exclusive user namespace widens from
   `^@_hagency_[a-z0-9_]+:<server>$` to `^@_hagency_[a-z0-9_-]+:<server>$`.
   Both forms stay exclusive, so Palpo's `/register` refuses either one to a
   person (`M_EXCLUSIVE`, tested through Palpo's own matcher). Hagency
   sign-in already refuses `_hagency_` localparts (`identity.rs`,
   `browser_auth.rs`). The puppet guard in `matrix_client.rs` accepts `-`.
   - **Upgrade.** A deployment whose persisted registration
     (`agent-appservice.json` and Palpo's row) carries the legacy regex
     upgrades at startup. The file is rewritten atomically with the same
     tokens, and the Palpo row is re-registered. A disabled registration still
     refuses to start.
   - **Upgrade guard.** Before widening, the server lists every local
     account containing `_hagency_`. Startup refuses if any account matches
     the new regex but not the old one, because a person registered it before
     it was reserved and the Appservice must not adopt it.
   - A foreign namespace is never rewritten.
5. **Immutability.** The ID is minted once from the initial name. Rename
   changes the display name only, and the existing trigger rejects any
   `puppet_mxid` update. Idempotent create replays return the stored ID.
6. **Existing Agents keep their IDs.** There is no migration. Shared-project
   (managed) Agents still mint `<namespace><agt_id>` in
   `management_agent_executor.rs`, because their executor protocol carries
   the proposed Agent ID. Converting them is a separate change.
7. **Detection.** Clients treat a localpart as an Agent puppet when it is
   `_hagency_` + `[a-z0-9_-]+` and is not `_hagency_service`. Server-side, the
   desktop's `hagency_core::puppet::is_puppet_localpart` and the admin user
   list apply this rule. No client may derive an Agent ID from a puppet ID or
   the reverse; it reads the pairing from the server's Agent listing. As
   before, the name is never authority: callers still check the server and
   the owner's roster.

## Consequences

- **Privacy.** The owner's localpart is now visible in every Agent's Matrix
  ID to anyone who can see the Agent: room members, federation peers, and
  git trailers (`<localpart>@agents.hagency.invalid`). The owner relation was
  already visible through the Agent's profile and room membership. The ID
  also keeps the Agent's *first* name after a rename. Owners who renamed an
  Agent to hide its purpose should know that.
- **Rollback.** Once a deployment has upgraded its registration, an older
  binary refuses to start ("credentials belong to another deployment or
  namespace"). To roll back, restore the legacy regex in
  `agent-appservice.json` and re-register Palpo's row, and only do it while
  no readable-ID Agent exists.
- **No ID enumeration.** IDs are guessable from owner and name. Nothing
  relied on ULID unguessability for authority; every write still checks
  ownership.
