# Social Backend Contract

Contract between the Godot client (`scripts/social/`) and the social backend
(Cloud Functions / Cloud Run in front of Firestore). The client is already
built against this contract — implement these endpoints and flip
`SocialConfig.USE_MOCK_API` to `false`.

```
Godot client → Firebase Auth (REST) → backend API → Firestore
                                          └→ (later) push notifications
```

## 1. Firebase Auth behaviour (client-side, already implemented)

- **Anonymous sign-up**: `POST https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=API_KEY`
  with body `{"returnSecureToken": true}`. The client stores `localId` (uid),
  `idToken`, `refreshToken`, and a computed `expiresAt` in `user://social_auth.json`.
- **Refresh**: `POST https://securetoken.googleapis.com/v1/token?key=API_KEY`
  (form-encoded: `grant_type=refresh_token&refresh_token=…`). Run automatically
  when the token is within `TOKEN_REFRESH_MARGIN_SEC` (300 s) of expiry.
- Every backend request carries `Authorization: Bearer <idToken>` and
  `Content-Type: application/json`.
- **Backend requirement**: verify the ID token on every request (Admin SDK
  `verifyIdToken`); the verified `uid` is the only trusted identity. Never
  accept a uid from a request body.
- *Future*: Game Center linking via `accounts:signInWithGameCenter` will be
  layered on top of the same anonymous account (do not rotate uids).

## 2. Endpoints

All responses are JSON. Error responses: appropriate 4xx/5xx with
`{"error": "<human-readable message>"}`.

| Method | Route | Body | Returns |
|---|---|---|---|
| GET | `/me` | — | user profile (creates profile + friend code on first call) |
| PATCH | `/me` | `{"displayName": "..."}` | updated profile |
| POST | `/me/levels` | challenge-style payload (below) | `{"ok": true, ...}` — posts a beaten custom level to the caller's profile |
| GET | `/friends` | — | `[{uid, displayName, friendCode}]` (accepted friends) |
| GET | `/friends/requests` | — | `[friendRequest]` involving the caller (include a `direction` of `incoming`/`outgoing` or let the client derive it from uids) |
| POST | `/friends/requests` | `{"friendCode": "..."}` | created friendRequest |
| POST | `/friends/requests/{requestId}/respond` | `{"accept": true\|false}` | updated friendRequest (creates the friendship server-side on accept) |
| GET | `/challenges` | — | `[challenge]` where caller is `fromUserId` or `toUserId` |
| POST | `/challenges` | `{"toUserId": "...", "payload": {...}}` | created challenge |
| POST | `/challenges/{challengeId}/complete` | `{"result": {"attempts": N}}` | mark complete (recipient only). Records attempts; pushes the sender. No accept/decline step. |
| POST | `/me/devices` | `{fcmToken, deviceId, platform, appVersion}` | `{ok:true}` — upsert this device's push token (one doc per device) |
| POST | `/me/devices/{deviceId}/disable` | — | `{ok:true}` — set `notificationsEnabled=false` (logout/account switch) |
| POST | `/me/progress/{levelId}` | `{attempts, cleared, clearedAt}` | `{ok:true}` — upsert per-level progress. `levelId` is `LEVEL_<n>`. **Monotonic merge**: stored `attempts = max(stored, incoming)`, `cleared` only flips false→true, first `clearedAt` wins. Lets the offline-first client push fire-and-forget / replay safely. |
| GET | `/me/progress` | — | array of the caller's per-level progress docs |

### Profile shape

```json
{
  "uid": "...", "displayName": "...", "friendCode": "FS-2486",
  "createdAt": "...", "updatedAt": "...",
  "stats": {"levelsCleared": 0, "challengesCompleted": 0},
  "postedLevels": [ {payload…} ]
}
```

### Challenge payload shape (client sends; backend validates)

```json
{
  "levelId": "LV00XXXX",   // editor level code
  "seed": 0,                // reserved for procedural levels
  "scoreToBeat": 0,         // reserved
  "triesToBeat": 3,         // sender's attempt count on their own level
  "layout": "#####\n#A12T#\n#####"  // ASCII board (validated server-side: one A, one T, keys 1+2)
}
```

### Completion result shape (from the recipient)

```json
{"attempts": 3}
```

Challenges aren't won or lost — only **complete or incomplete**. On completion the
backend clamps `attempts` (never trusts it raw), stores
`result = {attempts, completedBy}`, bumps the recipient's `stats.challengesCompleted`,
and pushes the sender. Both sides then see the same completed challenge.

## 3. Firestore data model

```text
users/{uid}
  uid, displayName, friendCode, createdAt, updatedAt, stats

users/{uid}/devices/{deviceId}            // push targets — many per user
  fcmToken, platform: "ios"|"android", deviceId, appVersion
  lastUpdated, notificationsEnabled: true

users/{uid}/levels/LEVEL_<n>              // per-level progress (one per level)
  levelId: "LEVEL_<n>", attempts: int (cumulative across sessions),
  cleared: bool, clearedAt: int|null (unix sec), updatedAt
  // Offline-first: the client owns the source of truth locally (user://progress.cfg)
  // and pushes here fire-and-forget; the backend merges monotonically so an offline
  // backlog can replay in any order on reconnect without regressing.

friendRequests/{requestId}
  fromUserId, toUserId, fromDisplayName, toDisplayName
  status: "pending" | "accepted" | "rejected"
  createdAt, respondedAt

friendships/{friendshipId}
  users: [uidA, uidB]
  createdAt

challenges/{challengeId}
  fromUserId, toUserId, fromDisplayName, toDisplayName
  status: "incomplete" | "completed"      // no won/lost, no accept/decline
  payload: { levelId, seed, scoreToBeat, triesToBeat, layout }
  result:  { attempts, completedBy } | null
  createdAt, updatedAt
```

## 4. Security assumptions & validation rules

- Firestore is **never** accessed directly by clients (lock rules to deny all
  client SDK access); the backend uses the Admin SDK.
- A user can only read/write their **own** profile; the only fields exposed to
  others are the public friend fields (`uid`, `displayName`, `friendCode`).
- Friend codes resolve to uids **server-side only** (`POST /friends/requests`
  takes a code, not a uid). Codes must be unique; regenerate on collision.
- Users **cannot create friendships directly** — a friendship document is only
  written by the backend when the *recipient* accepts a pending request.
- Only the recipient (`toUserId`) of a friend request may respond to it.
- Challenges may only be created **between accepted friends** (check a
  friendship doc exists for the pair). One challenge per recipient; the editor's
  multi-select sends one create call per selected friend.
- Challenge completion: only the recipient may complete, only while `incomplete`
  (re-complete → 409). There's no winner — the backend records `attempts`
  (clamped, never trusted raw) and pushes the sender. Replay validation
  (move-by-move) is future work.
- `POST /me/levels` must run the same layout validation as challenges
  (exactly one `A`, ≥1 `T`, one `1`, one `2`, bounded size) to keep posted
  levels playable and non-abusive.
- Rate-limit request/challenge creation per uid (e.g. 30/day) to limit spam.

## 5. Push notifications (FCM)

Sending push is **backend-only** — never ship FCM server keys or APNs secrets in
the client (the client only ever *uploads its own device token* via
`POST /me/devices`). Client/device setup: see `docs/ios_push_setup.md`.

Send flow (already implemented inline in the API handlers, since they are the
trusted writers of these docs; a Firestore `onCreate` trigger is an equivalent
alternative):

1. User A acts (sends a friend request / accepts one / sends a challenge).
2. The handler writes the `friendRequests` / `friendships` / `challenges` doc.
3. `notifyUser(targetUid, notification, data)` reads
   `users/{targetUid}/devices` where `notificationsEnabled == true`, collects
   `fcmToken`s, and calls Admin SDK `messaging().sendEachForMulticast(...)`.
4. Tokens FCM reports as `registration-token-not-registered` /
   `invalid-registration-token` are deleted (cleanup).

Data payloads the client routes on (`type` drives the screen it opens):
`{type:"challenge", challengeId}`, `{type:"friend_request", requestId}`,
`{type:"friend_accepted", userId}`.
