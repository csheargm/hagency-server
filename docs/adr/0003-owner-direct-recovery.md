# ADR 0003: Owner-direct recovery after the owner leaves

Status: accepted for the demo fork (2026-11-17); proposed upstream.

## Context

Each personal Agent has one owner-direct Room, its private chat with its
owner. The owner's client creates it (invite-only, no guests, a marker state
event) and the server adopts it: `agents.owner_direct_room_id` is set once and
a database trigger (`retain_direct_room`) made it permanent
(`owner_direct_room_already_assigned` in `adopt_owner_direct`).

When the owner leaves that Room, nothing brings them back:

- the Room is invite-only, so the owner cannot rejoin by themselves;
- the reconciler sees the owner gone, retires the binding and has the puppet
  leave within one sweep (about 2 s), leaving an empty Room;
- the desktop's `owner-direct/ensure` only checks or creates. With a fixed
  Room it never re-invites, so the Agent's Message button opened a join prompt
  that could not succeed.

## Decision

1. **New owner-only endpoint** `POST /hagency/api/v1/agents/{id}/owner-direct/recover`
   (capability `owner-direct-recovery-v1`). It authenticates like every agent
   route; the Agent is looked up with the caller's user ID, so for anyone but
   the owner it does not exist. It takes no body: the only invitee is the
   authenticated owner, and the only inviter is the Agent's own puppet.
2. **Outcomes**, from one privileged state snapshot of the current Room:
   - `none`: no Room yet; the client creates one as before.
   - `joined`: the owner is joined; nothing happens.
   - `invited`: an invitation is already waiting.
   - `reinvited`: the owner left, was kicked or is absent, the puppet is
     joined, may invite, and the binding is live. The puppet invites the owner
     back into the same Room. If Matrix refuses that invite (403), recovery
     falls through to a replacement. Any other invite error is returned as is:
     the invite may have landed, and a retry re-reads membership.
   - `replaced`: the Room cannot bring the owner back (the puppet left, the
     Room was upgraded/tombstoned, it is no longer private (join rule, guests,
     history visibility), the owner is banned, the puppet lacks invite power
     or was refused, or the binding is already leaving). The puppet creates a
     new private Room with nobody invited: owner and puppet at power 100, the
     same marker `im.hagency.agent.owner_direct` and history/guest/join rules,
     and Megolm encryption if the old Room was encrypted. The server swaps
     the new Room in, then the puppet invites the owner. A refused swap
     therefore never leaves an invitation behind. An invite that fails after
     the swap is retried by the next call, which finds the Room reinvitable.

   A state read failure is returned as an error. It never counts as an
   unusable Room, so an outage cannot replace a working chat.
3. **One current Room, swapped atomically.** `replace_owner_direct` runs in
   one transaction under the domain advisory lock: it checks that the Agent
   still points at the exact Room it observed (compare-and-swap, else
   `owner_direct_room_changed`), moves the old binding to `leaving`, updates
   `owner_direct_room_id` and inserts the new `joining` binding. The trigger
   still refuses every other change. It allows a replacement only when the
   transaction sets `hagency_agent_v1.owner_direct_replaces` to the exact old
   Room, and it never allows clearing the Room.
4. **Concurrency.** Recovery is serialized per Agent within a process. A
   second concurrent call sees the first call's Room with the owner invited
   and returns `invited`. Across processes, the compare-and-swap lets only one
   replacement commit. The puppet leaves a losing replacement Room, but only
   after re-reading that the Agent does not point at it, in case a commit
   landed and its reply was lost.
5. **Rejoin grace.** The binding column `owner_rejoin_until_ms` (now plus
   120 s) is set before the re-invite, in the same transaction that checks the
   binding is live, and on the replacement binding. While it lasts, membership
   fencing excuses only the owner's absence, and only while the puppet is
   joined. Without it, the reconciler could retire the binding between the
   invitation and the owner's join. After it expires, ordinary membership-loss
   rules apply again. The grace also ends as soon as an observation shows
   the owner joined, so a second departure counts at once. The replacement
   binding keeps the old binding's thread auto-reply setting.
6. **Client.** Desktop `ensure` calls `recover` first. It follows the Room the
   server names (the server is authoritative, including after a lost reply)
   and joins it as the owner. Then it runs its usual state validation, `m.direct`
   index and adopt steps. Validation accepts a Room created by either the owner
   or the Agent's puppet, as long as the creator also wrote the marker.
   Servers without the route answer `unsupported_operation`, and the client
   keeps its earlier behaviour.
7. `GET …/owner-direct` now returns the binding of the current Room, not the
   first owner-direct binding, because a superseded binding can remain.

## Consequences

- Leaving the private chat is no longer permanent: the Agent's Message button
  brings the owner back. A replacement Room starts with empty history. An
  owner pause on the old binding does not carry over: activation of the new
  binding clears it, as for any newly adopted owner-direct binding.
- The old Room's alias `#hagency-agent-<id>` (created with the owner's
  original Room) still points at the old Room. Clients use it only when the
  server knows no Room, which never happens after a replacement.
- A replacement that was never joined is retired by the reconciler after
  the grace, and the next `recover` replaces it again. Recovery repairs
  itself; it never gets stuck.
- The schema change is additive and idempotent (`CREATE OR REPLACE FUNCTION`,
  `ADD COLUMN IF NOT EXISTS`) and runs on every start.
