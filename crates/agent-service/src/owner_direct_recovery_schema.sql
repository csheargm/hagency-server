-- ADR 0003: the owner-direct Room stays fixed, except for one audited
-- replacement inside the owner-only recovery transaction, which names the exact
-- Room it supersedes. Clearing it, or any other rewrite, still fails.
CREATE OR REPLACE FUNCTION hagency_agent_v1.retain_direct_room() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.owner_direct_room_id IS NOT NULL AND NEW.owner_direct_room_id IS DISTINCT FROM OLD.owner_direct_room_id
  AND (NEW.owner_direct_room_id IS NULL
   OR current_setting('hagency_agent_v1.owner_direct_replaces', true) IS DISTINCT FROM OLD.owner_direct_room_id)
 THEN RAISE EXCEPTION 'permanent_owner_direct_room'; END IF;
 RETURN NEW;
END;
$$;
-- Until this time the reconciler keeps an owner-direct binding whose owner is
-- not joined yet (re-invited, or invited to the replacement Room).
ALTER TABLE hagency_agent_v1.bindings ADD COLUMN IF NOT EXISTS owner_rejoin_until_ms bigint NOT NULL DEFAULT 0;
