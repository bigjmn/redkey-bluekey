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
| POST | `/challenges/{challengeId}/respond` | `{"accept": true\|false}` | updated challenge (`accepted`/`declined`) |
| POST | `/challenges/{challengeId}/complete` | `{"result": {...}}` | updated challenge (`completed`) |

### Profile shape

```json
{
  "uid": "...", "displayName": "...", "friendCode": "FS-2486",
  "createdAt": "...", "updatedAt": "...",
  "stats": {"levelsCleared": 0, "challengesWon": 0},
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

### Result shape (advisory from client)

```json
{"tries": 2}
```

The backend computes `result.winnerUserId` by comparing the receiver's tries
against `payload.triesToBeat` — **never trust a client-provided winner**.

## 3. Firestore data model

```text
users/{uid}
  uid, displayName, friendCode, createdAt, updatedAt, stats

friendRequests/{requestId}
  fromUserId, toUserId, fromDisplayName, toDisplayName
  status: "pending" | "accepted" | "rejected"
  createdAt, respondedAt

friendships/{friendshipId}
  users: [uidA, uidB]
  createdAt

challenges/{challengeId}
  fromUserId, toUserId, fromDisplayName, toDisplayName
  status: "pending" | "accepted" | "completed" | "expired" | "declined"
  payload: { levelId, seed, scoreToBeat, triesToBeat, layout }
  result:  { winnerUserId, fromResult, toResult }
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
- Only the recipient (`toUserId`) of a request/challenge may respond to it.
- Challenges may only be created **between accepted friends** (check a
  friendship doc exists for the pair).
- Challenge completion: only the recipient may complete; only from status
  `accepted`; the backend validates the layout/result and decides the winner.
  Replay validation (move-by-move) is future work — until then treat `tries`
  as semi-trusted and clamp to sane ranges.
- `POST /me/levels` must run the same layout validation as challenges
  (exactly one `A`, ≥1 `T`, one `1`, one `2`, bounded size) to keep posted
  levels playable and non-abusive.
- Rate-limit request/challenge creation per uid (e.g. 30/day) to limit spam.
