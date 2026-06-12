# redkey-bluekey social backend

Cloud Functions (gen 2) + Firestore implementation of
[docs/social_backend_contract.md](../docs/social_backend_contract.md).
One Express app exported as the `api` function; Firestore rules deny all
client access (the Admin SDK in the function is the only writer).

The `.gdignore` file keeps the Godot importer out of this directory
(`node_modules` would otherwise be scanned by the editor).

## One-time setup

1. **Login** (interactive, opens a browser):
   ```sh
   cd backend
   npx firebase-tools login
   ```
2. **Enable Anonymous auth**: Firebase console → Authentication →
   Sign-in method → enable **Anonymous**. (The client signs in anonymously.)
3. **Billing**: Cloud Functions needs the project on the **Blaze** plan.

## Deploy

```sh
cd backend/functions && npm install && cd ..
npx firebase-tools deploy --only functions,firestore:rules --project redkey-bluekey
```

The function lands at the URL already wired into the client:
`https://us-central1-redkey-bluekey.cloudfunctions.net/api`

## Point the Godot client at it

1. Fetch the web app config for **puzzle-game**:
   ```sh
   npx firebase-tools apps:sdkconfig WEB --project redkey-bluekey
   ```
2. Copy `social_keys.json.example` (project root) to `social_keys.json` and
   paste the `apiKey` value into it. The file is gitignored; the iOS export
   preset includes it via `include_filter`. (Env var `FIREBASE_API_KEY` works
   as a fallback for CI/dev runs.)
3. Set `USE_MOCK_API := false` in
   [scripts/social/SocialConfig.gd](../scripts/social/SocialConfig.gd).

## Smoke-testing the deployed API

```sh
# Mint an anonymous user + token (replace KEY):
curl -s -X POST 'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=KEY' \
  -H 'Content-Type: application/json' -d '{"returnSecureToken":true}'
# Then call the API with the idToken:
curl -s https://us-central1-redkey-bluekey.cloudfunctions.net/api/me \
  -H 'Authorization: Bearer ID_TOKEN'
```

First `GET /me` creates the profile and allocates a friend code.
