# ADR 0004: Agent replies sit in the room, not in a thread

Status: accepted for the demo fork (2026-11-17); proposed upstream. Desktop
half: hagency-desktop ADR 0023.

## Context

The agent-service stores every routed request under a context root: the
request's own event id for a top-level group request, the thread root for a
request written in a thread, the room id for a top-level owner DM. The
plaintext answer (`workers::reply_content`) and request notices were posted
with an `m.thread` relation to that root, so a top-level question opened a
thread and other members of the room did not see the answer in the main
timeline (Chris, 2026-11-17: "in WeChat, as long as you are in the room, all
conversations can be seen").

## Decision

* A room chooses with the state event `im.hagency.agent_replies`
  (`state_key` ""): `{"mode":"room"}` or `{"mode":"thread"}`. No event, or an
  unknown value, means `room`. The event type is pinned by a test here and in
  the desktop (`hagency_core::agent_replies`).
* `agent_replies::is_flat`: the answer is a main-timeline reply when the room
  is in `room` mode, the request is a top-level project-room request (root ==
  the request's event id) and the scope is not personal (owner DM): personal
  intents keep their stored shape, legacy event-rooted DM intents included. A request written in a
  thread is answered in that thread in both modes; owner DMs are unchanged.
* A flat answer is `{"m.relates_to":{"m.in_reply_to":{"event_id":<request>}}}`
  with the Markdown rendering of the answer, and a plain `body` that starts
  with `> <@requester> first line of the request` (80 characters at most):
  the reply fallback for clients that do not render the relation. The quote
  is added after the HTML is rendered, so `formatted_body` has none.
* The mode is read from the same room-state snapshot as the delivery facts
  the send is authorized on (`DeliveryFacts::reply_mode`); there is no second
  read between the claim and the send.
* Request notices follow the same rule. The progress status was already a
  top-level notice replying to the request; it is unchanged.
* `ReplyIntent` gains `request_event_id` and `request_body` (sub-selects of
  `owner_events`, never serialized to clients). No schema change.
* Routing is unchanged: a follow-up that replies to an answer is an ordinary
  top-level request (only `m.thread` selects a thread); it is admitted only
  when it addresses the Agent, under the existing rules.

## Consequences

* The quote copies the request's first line into the answer; if the request
  is later redacted, that line stays in the answer (GPT review). Accepted for
  plain-text clients; clients that render the relation do not need it.

* Rooms that never set the event switch to main-timeline answers as soon as
  this build runs; a room that wants the old shape sets `{"mode":"thread"}`
  (the desktop's room information pane has the switch).
* Pause notices and the managed shared-work replies still thread under the
  request; moving them is follow-up work.
* Retrying a send reuses its transaction id, so a mode change between two
  attempts of the same answer cannot post it twice.
