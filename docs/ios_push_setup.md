# iOS Push Notifications (Firebase Cloud Messaging) — setup checklist

The Godot client, the backend device endpoints, and the `notifyUser()` send
helper are all implemented. What remains is Apple/Firebase configuration that
cannot live in code — most importantly the **APNs Auth Key** (see §3, which is
the step that actually gates delivery; see Troubleshooting).

> Receiving push on iOS requires a **native** FCM/APNs plugin — there is no
> pure-GDScript path. On desktop/editor the plugin singletons are absent and
> `PushNotificationService` safely no-ops (logs one warning).

## 1. Godot iOS FCM plugin (Godotx Firebase)

We use **Godotx Firebase** (github.com/godot-x/firebase, AssetLib 4475). Enable
its **Core** and **Messaging** modules. `scripts/social/push_notification_service.gd`
is wired to its concrete API — no name-guessing needed:

- Singletons: `GodotxFirebaseCore`, `GodotxFirebaseMessaging` (iOS-only).
- Flow: `Core.initialize()` → `core_initialized` → `Messaging.initialize()` +
  `request_permission()` → `messaging_permission_granted` → `get_token()` →
  `messaging_token_received(token)` → register device with the backend.

Export-preset checks:
- The `godotx_firebase` editor plugin is enabled, and **Messaging** is enabled in
  the iOS export preset (otherwise the singletons won't exist on device).
- `GoogleService-Info.plist` is at the repo root (`res://GoogleService-Info.plist`,
  gitignored) where the plugin's export option expects it.

## 2. Apple Developer / Xcode

- Enable the **Push Notifications** capability for the App ID.
- Enable **Background Modes → Remote notifications**.
- Ensure the **provisioning profile** includes Push Notifications.
- Confirm the bundle id matches the Firebase iOS app (`com.JNicks.redkeybluekey`).
- Entitlement `aps-environment`: `development` for Xcode/dev builds, `production`
  for TestFlight + App Store (TestFlight is NOT sandbox). One `.p8` covers both.

## 3. Firebase console — **APNs Auth Key (the critical step)**

- Add an **iOS app** to project `redkey-bluekey`; download `GoogleService-Info.plist`.
- In the **Apple Developer** account → Certificates, IDs & Profiles → **Keys**,
  create a key with **Apple Push Notifications service (APNs)** enabled. Download
  the `.p8` (you can only download it once) and note its **Key ID** + your
  **Team ID**.
- Firebase Console → **Project Settings → Cloud Messaging → Apple app
  configuration → APNs Authentication Key → Upload**, providing the `.p8`,
  Key ID, and Team ID.

**Without this, FCM accepts the send but cannot deliver to APNs** and every send
fails with `THIRD_PARTY_AUTH_ERROR` (see Troubleshooting). A single `.p8` works
for both sandbox (development) and production.

## 4. Backend (already wired)

`backend/functions/index.js` calls `notifyUser()` on friend request / accept /
challenge create. It uses the Admin SDK `getMessaging().sendEachForMulticast()`,
which needs **no extra secret** in code (the deployed function authenticates via
its runtime service account). Redeploy with:

```sh
cd backend && npx firebase-tools deploy --only functions --project redkey-bluekey
```

## 5. Testing

1. Build to a **real iPhone** (push does NOT work in the iOS Simulator).
2. Launch, grant the notification permission prompt, sign in. A doc should appear
   at `users/{uid}/devices/{deviceId}` with your `fcmToken`.
3. From a second account, send this user a friend request or challenge.
4. Confirm the banner arrives (background the app to see it).
5. Check delivery in the logs: `npx firebase-tools functions:log --only api`
   — look for `notifyUser <uid>: N token(s)` then `N sent, 0 pruned`.

## 6. Troubleshooting — what each `notifyUser` log means

- `0 token(s)` — the device never registered. Causes: app not rebuilt after a
  client change, notification permission denied, or Messaging not enabled in the
  iOS export preset.
- `N sent, 0 pruned` — success; FCM accepted and forwarded to APNs.
- `send error [messaging/registration-token-not-registered]` then `pruned` — the
  token is dead (app uninstalled / token rotated). Normal; the device re-registers
  on next launch.
- `send error [messaging/third-party-auth-error]` ("Request is missing required
  authentication credential …", FCM `errorCode: THIRD_PARTY_AUTH_ERROR`) —
  **APNs is not configured.** Despite the misleading "OAuth" wording, this is the
  APNs leg failing: FCM authenticated us fine and accepted the send, but has no
  valid APNs Auth Key to deliver with. **Fix: upload the `.p8` (§3).**

  Isolate it with a `validate_only` send (does NOT contact APNs): if
  `validate_only:true` returns `200` for the real token but a real send returns
  `THIRD_PARTY_AUTH_ERROR`, the only missing piece is the APNs key. (Confirmed via
  the FCM v1 REST API `…/messages:send` — the backend/auth/token/permission chain
  and `fcm.googleapis.com` enablement were all verified correct.)

## 7. Do NOT

- Put FCM server keys or APNs `.p8` secrets in the client / repo.
- Try to send notifications from the game client — sending is backend-only.
