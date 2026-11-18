CREATE OR REPLACE VIEW hagency_agent_v1.request_notice_needed AS
 SELECT e.id AS owner_event_id, e.binding_id, e.requester_mxid, e.thread_root, e.binding_generation,
 CASE
  WHEN e.state='unknown' AND r.id IS NULL AND ps.status_event_id IS NULL AND e.outcome IS NULL AND NOT e.automated THEN 'interrupted'
  WHEN e.state='cancelled' AND e.outcome='unknown' AND e.execution_id IS NULL THEN 'failed'
  WHEN e.state IN ('completed','cancelled') AND e.outcome IN ('failed','rejected') AND ps.status_event_id IS NULL THEN e.outcome
  WHEN e.state='cancelled' AND e.outcome='expired' THEN 'expired'
 END AS kind
 FROM hagency_agent_v1.owner_events e
 LEFT JOIN hagency_agent_v1.reply_outbox r ON r.owner_event_id=e.id
 -- Only outcomes are posted. Interim "queued", "still working" and "reply
 -- delayed" notices flooded busy rooms (owner, 2026-11-18); a slow turn now
 -- shows once, in place, on its live status (progress_status `slow`). A posted
 -- status's final edit carries the failure text, so it is not sent twice.
 -- "Interrupted" is owed only when the server itself lost the run (outcome
 -- NULL: the execution device changed). A device that reports `unknown` has
 -- already edited its own run line to "went offline", and an automation's
 -- request (the issue watcher) reports the loss on its tracker line.
 LEFT JOIN hagency_agent_v1.progress_status ps ON ps.owner_event_id=e.id
 JOIN hagency_agent_v1.request_notice_deployment d ON d.singleton AND e.created_at_ms>=d.since_ms
 JOIN hagency_agent_v1.bindings b ON b.id=e.binding_id AND b.generation=e.binding_generation
 JOIN hagency_agent_v1.agents a ON a.id=b.agent_id
 JOIN hagency_agent_v1.users u ON u.id=a.owner_user_id
 LEFT JOIN hagency_agent_v1.projects p ON p.id=b.project_id
 LEFT JOIN hagency_agent_v1.rooms room ON room.room_id=b.room_id AND room.project_id=b.project_id
 WHERE b.state='active' AND a.state='active' AND u.active AND NOT b.admin_project_paused AND NOT b.admin_room_paused
 AND ((b.scope_kind='project' AND p.active AND room.active) OR (b.scope_kind='owner_direct' AND a.owner_direct_room_id=b.room_id));
