# JS8Call (JS8Call-improved fork) Store-and-Forward Message Flows — Behavioral Spec

Clean-room behavioral specification derived from observing the JS8Call-improved
sources (GPLv3). Contains protocol facts and reply-string templates only; no
source code. `<X>` denotes a substituted value. All directed traffic below is a
normal JS8 directed message of the form `SENDER: TARGET <CMD> [payload]` on the
air; templates here show only what the replying station types/transmits (the
sender's own callsign is prepended automatically by the normal directed-message
framing, and the operator's configured end-of-transmission character, default
`♢`, is appended to the final frame).

Terminology: "me/holder" = the station receiving the command and possibly
auto-replying. "Autoreply" = the AUTO mode toggle (`Mode > Autoreply`, default
ON at startup via settings key `AutoreplyOnAtStartup`, default true).

---

## 0. Common gating that applies to ALL flows below

A received directed command is only acted on if:

1. It is addressed to my exact callsign or my base callsign (compound calls
   are matched by base), OR to `@ALLCALL`, OR to a group I belong to
   (`@GROUP...`). Otherwise it is only logged (heard list / heard graph).
2. `@ALLCALL`-addressed commands are ignored entirely when the "avoid
   @ALLCALL" setting is on (exception: CQ and HB/HEARTBEAT).
3. Sender must pass the auto-reply whitelist (if non-empty, sender or its base
   call must be listed) and must not be on the auto-reply blacklist.
4. `@ALLCALL` commands from a given sender are rate-limited: if we replied to
   an @ALLCALL from that sender within the last 15 minutes, the new one is
   dropped (cache entries are inserted whenever an @ALLCALL reply is queued).
5. No automatic replies at all while the TX watchdog/idle timeout has fired.
6. A constructed reply is silently discarded if the operator has text sitting
   in the outgoing message box, or if there is a partially-received message
   buffer open addressed to us.
7. Queued-reply transmission: the reply text is placed into the outgoing
   message box and is transmitted automatically only when Autoreply is ON
   (high-priority messages, HB and ACK texts also auto-send). @ALLCALL replies
   are never even queued unless Autoreply is ON.
8. If the "Autoreply confirmation" setting is ON (settings key
   `AutoreplyConfirmation`, default true), every automatic reply first pops a
   90-second self-destructing confirmation dialog ("Autoreply Confirmation
   Required" — would you like to send this transmission?) and is only queued
   if the operator (or an API client) accepts before the timeout; on timeout
   it is dropped.

Message id note: inbox message ids are the SQLite `INTEGER PRIMARY KEY
AUTOINCREMENT` row id of the local inbox database (`inbox.db3` in the writable
data dir), so ids are small monotonically increasing integers local to the
holder's station — this is why on-air ids like `416` appear. Ids are allocated
on insert; there is no wire-level id negotiation.

Stored rows have a `type`: `UNREAD`/`READ` = messages TO me (my inbox),
`STORE` = messages I am holding for a third party, `DELIVERED` = a held
message that has been retrieved.

---

## 1. Receiving `<MYCALL> MSG <text>` (a message addressed to me)

Behavior:
- The message text is stored in MY local inbox with type `UNREAD` (params
  include UTC, TO, FROM, PATH, TEXT, SNR, DIAL, OFFSET, SUBMODE, ...).
- An "inbox" notification sound/event fires, and a 300-second self-destructing
  popup appears: "New Message Received — A new message was received at
  <HH:MM:SS> UTC from <FROM>".
- An automatic reply is queued (subject to section 0 gating):

      <FROM> ACK

  Exactly that — the sender's callsign followed by ` ACK`. **No message id**
  is included in this ACK. If the MSG arrived through a relay (text contains
  `*DE* <CALL>` / `VIA <CALL>` hops), the reply target is the full reverse
  relay path (calls joined by `>`), i.e. `<CALL1>><CALL2> ACK`.
- Not processed when addressed to `@ALLCALL`. A MSG addressed to a @group I am
  in IS processed the same way (stored in my inbox, ACK queued) — see §6.

## 2. Receiving `<MYCALL> MSG TO:<DEST> <text>` (relay storage request)

Behavior:
- Ignored if the "relay off" configuration is set (settings key `RelayOFF`,
  default false = relay enabled). Ignored when addressed to `@ALLCALL`.
- The text (everything after the destination callsign token) is stored in the
  holder's inbox database with type `STORE`, TO = base callsign of `<DEST>`
  (or the group name if `<DEST>` is `@GROUP`), FROM = sender, plus relay path.
- The id is simply the autoincrement row id returned by the insert.
- Automatic reply queued (subject to section 0 gating):

      <FROM> ACK

  Again **no "MSG ID <n>" in the storage ACK** — the id is only revealed
  later via QUERY MSGS / HB acks / push notification. If the request came via
  relay, `<FROM>` is replaced by the reverse relay path (`A>B ACK`).

## 3. Receiving `<MYCALL> QUERY MSGS` (or `QUERY MSGS?`)

Gated additionally on Autoreply being ON (checked at construction time for
this command, unlike most others).

- The holder looks up the OLDEST undelivered `STORE` message whose TO matches
  the querying station (exact or base callsign; delivered/empty-text rows are
  skipped). Let `<ID>` be its row id and `<K>` the number of additional
  undelivered messages beyond that one (only appended when `> 0`):

      <FROM> YES MSG ID <ID>            (exactly one message held)
      <FROM> YES MSG ID <ID> +<K>       (more than one held; K = count minus 1)

- If no direct message but the query was sent to a @group address, the oldest
  group-stored message not yet delivered to this callsign is offered with the
  same two templates.
- If nothing is held and the query was NOT to `@ALLCALL`:

      <FROM> NO

  Exactly `NO` — **not** "NO MESSAGES". To `@ALLCALL` with nothing held, no
  reply at all.
- `<FROM>` is the reverse relay path when the query was relayed.

## 4. Retrieving a stored message

Retriever transmits (this is the canned template the UI inserts from the
directed-query menu):

      <HOLDER> QUERY MSG <ID>

(There is also `<HOLDER> QUERY CALL <CALLSIGN>?` for "can you hear X", and
plain `QUERY MSGS` above; `QUERY MSG <n>` is the retrieval command. On the
wire it is the generic `QUERY` command with payload text `MSG <n>`.)

Holder behavior on receiving it:
- Looks up row `<ID>` in its inbox. Silently ignores the query if: the id
  doesn't exist, the stored TO doesn't match the querying station (exact or
  base call) — EXCEPT messages stored TO a `@GROUP`, which anyone may
  retrieve — or the stored text is empty.
- Reply templates (`<TEXT>` = stored message text, `<ORIG>` = stored FROM
  callsign, i.e. who left the message):

      <FROM> MSG <TEXT> FROM <ORIG>
      <FROM> MSG <TEXT> FROM <ORIG> NEXT MSG ID <ID2>          (another message waits)
      <FROM> MSG <TEXT> FROM <ORIG> NEXT MSG ID <ID2> +<K>     (and K more beyond that)

  So the delivery suffix is a literal ` FROM <CALL>` (not `*DE*`; `*DE*`/`VIA`
  is the relay-path marker used by the `>` relay command, e.g. relayed text is
  retransmitted as `<text> *DE* <sender>`). The `NEXT MSG ID` lookahead is the
  next undelivered STORE row id for that callsign (or group) after `<ID>`.
- Only after the reply transmission completes is the message marked delivered:
  direct messages have their row type changed `STORE` → `DELIVERED`; group
  messages instead record a per-(msg,callsign) delivery row, so each group
  member can retrieve the same message once.

## 5. `MSG ID <n>` announcements (the lone "MSG ID 416" frame)

Two on-air producers:

a) **Heartbeat acknowledgements.** When a station we hold mail for sends
   `HB`/`HEARTBEAT` (requires: HB mode enabled + Autoreply ON + "heartbeat
   acknowledgements" enabled; skipped during an open message buffer, during a
   QSO if "HB pause during QSO" is set, and for HB-blacklisted calls), the ack
   is:

      <FROM> HEARTBEAT SNR <±NN>                       (no mail held)
      <FROM> HEARTBEAT SNR <±NN> MSG ID <ID>           (one message held)
      <FROM> HEARTBEAT SNR <±NN> MSG ID <ID> +<K>)     (more held; note the
                                                        stray trailing ")" —
                                                        an upstream quirk)

   (A compile-time-disabled variant would use `<FROM> SNR <±NN> ...` or
   `<FROM> ACK ...`; shipped builds use the `HEARTBEAT SNR` form.) A long
   ack like `KB0XYZ HEARTBEAT SNR +05 MSG ID 416` spans multiple frames, so a
   decoder catching only the tail sees a lone `MSG ID 416` fragment. The
   `YES MSG ID <n>` reply of §3 fragments the same way.

b) **Push notification (fork-specific).** A 15-minute sweep in this fork
   proactively transmits, when a stored message's recipient has been heard
   within the last 15 minutes:

      <DEST> RETRIEVE MSG <ID>

   sent as plain directed freetext (not a real protocol command), throttled to
   once per 8 hours per message id, at most one per sweep, only while
   Autoreply is ON and the TX queue is idle. A receiving fork client that sees
   directed freetext starting `RETRIEVE MSG` pops a local dialog telling the
   operator to send `QUERY MSG <n>`; stock clients just display the text.
   Its tail fragment decodes as `... MSG <ID>`, not `MSG ID <ID>`.

SNR formatting everywhere (`HEARTBEAT SNR`, `SNR` replies): sign always
present for non-negatives (`+`), value zero-padded to two digits (`+05`,
`-12`; range clamped to ±60, e.g. `+00`).

## 6. Gating summary / group behavior / rate limits

- **Autoreply toggle** (`Mode > Autoreply`, startup default from
  `AutoreplyOnAtStartup`, true): gates actual auto-transmission of every
  queued reply, is a hard precondition for QUERY MSGS / QUERY CALL / HB-ack
  construction and the push-notification sweep, and is required for any
  @ALLCALL reply.
- **Autoreply confirmation** (`AutoreplyConfirmation`, default true): every
  autoreply requires operator confirmation within 90 s (dialog + API event).
- **Relay/store enable** (`RelayOFF`, default false): when set, both the `>`
  relay command and `MSG TO:` storage are ignored. Inbound `MSG` to me is NOT
  gated by this.
- **Whitelist/blacklist**: auto-reply whitelist (empty = everyone) and
  blacklist, matched on full and base callsigns. Separate HB blacklist for
  heartbeat acks.
- **HB rate limit** (fork-specific, `HBRateLimit`, default false): when
  enabled, a station heartbeating twice within 55 minutes is automatically
  added to the HB blacklist (and its timer row cleared).
- **@ALLCALL**: reply per sender at most every 15 min; MSG/MSG TO:/QUERY
  MSG/QUERY MSGS(no-mail case) are never honored for @ALLCALL.
- **Groups (@GROUP)**: a `MSG` addressed to a group I belong to is stored in
  MY inbox and I queue an `<FROM> ACK` — so every group member that hears it
  acks (subject to §0 gating). A `MSG TO:@GROUP <text>` asks the receiving
  station to hold a message for the whole group; any station may retrieve it
  by id, delivery is tracked per retriever callsign, and group-held messages
  are only offered/counted for 48 hours after storage (direct-held messages
  don't expire). HB acks and QUERY MSGS sent to the group address also
  advertise pending group message ids. The push-notification sweep skips
  group messages.
- **Unread counts** (`+<K>` suffixes): count of undelivered `STORE` rows for
  that callsign (plus undelivered group rows when queried via a group),
  minus the one being announced (minus two on an actual delivery, since the
  delivered one is only marked after TX).

## 7. Canonical simple-query auto-reply templates

All are ignored when addressed to `@ALLCALL`; all pass through §0 gating.
Replies where my station has nothing configured (empty info/status/grid) send
nothing.

      Query                 Reply template
      <MYCALL> SNR?         <FROM> SNR <±NN>
      <MYCALL> GRID?        <FROM> GRID <my grid>
      <MYCALL> INFO?        <FROM> INFO <my info text, macros expanded>
      <MYCALL> STATUS?      <FROM> STATUS <my status text, macros expanded>
      <MYCALL> HEARING?     <FROM> HEARING <CALL1> <CALL2> <CALL3> <CALL4>
      <MYCALL> AGN?         (verbatim retransmission of my last TX text)
      <MYCALL> QUERY CALL <C>?   <FROM> YES <±NN> (<time since heard>)   — only if heard; silent otherwise

Notes: `SNR?` reports the SNR at which I decoded the query itself, formatted
as in §5 (`+NN`/`-NN`, two digits, zero-padded). `HEARING` lists up to the 4
most recently heard callsigns (excluding the asker, honoring the callsign
aging window). `<FROM>` is replaced by the reverse relay path when the query
arrived via relay hops.
