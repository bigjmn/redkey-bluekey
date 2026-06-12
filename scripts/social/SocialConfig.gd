class_name SocialConfig
extends RefCounted
## Central config for the Firebase-backed social layer. ALL keys/URLs live here —
## never hardcode them elsewhere. Replace the placeholders before shipping.
##
## Architecture: Godot client -> Firebase Auth (REST) -> backend API (Cloud
## Functions / Cloud Run) -> Firestore. The client NEVER talks to Firestore
## directly; every social mutation goes through the backend so validation rules
## can be enforced server-side. See res://docs/social_backend_contract.md.

## Firebase Web API key for project "redkey-bluekey", web app "puzzle-game".
## NOT stored in the repo: it lives in res://social_keys.json (gitignored — copy
## social_keys.json.example and fill it in), or the FIREBASE_API_KEY env var.
## Get it with:  npx firebase-tools apps:sdkconfig WEB --project redkey-bluekey
## (Note: a Firebase WEB API key is not a true secret — it ships in the app
## binary and security comes from ID-token verification + rules — but keeping
## it out of version control is still good hygiene.)
const KEYS_PATH := "res://social_keys.json"

static var _cached_key: String = ""

static func firebase_api_key() -> String:
	if not _cached_key.is_empty():
		return _cached_key
	if FileAccess.file_exists(KEYS_PATH):
		var f := FileAccess.open(KEYS_PATH, FileAccess.READ)
		if f != null:
			var data: Variant = JSON.parse_string(f.get_as_text())
			if data is Dictionary:
				_cached_key = str(data.get("firebase_api_key", ""))
	if _cached_key.is_empty():
		_cached_key = OS.get_environment("FIREBASE_API_KEY")
	return _cached_key

## The deployed `api` Cloud Function (backend/functions/index.js), no trailing
## slash. This is the deterministic gen-2 cloudfunctions.net URL for the
## us-central1 deployment of project redkey-bluekey.
const API_BASE_URL := "https://us-central1-redkey-bluekey.cloudfunctions.net/api"

## When true, SocialApiClient serves canned fixture data instead of hitting the
## network, and auth is faked locally — handy for UI work offline. The backend
## is deployed and live, so this ships false.
const USE_MOCK_API := false

## Local persisted auth state (uid / idToken / refreshToken / expiresAt).
const AUTH_SAVE_PATH := "user://social_auth.json"

## Refresh the ID token when it has less than this many seconds left to live.
const TOKEN_REFRESH_MARGIN_SEC := 300

## Firebase Auth REST endpoints (per https://firebase.google.com/docs/reference/rest/auth).
const AUTH_SIGNUP_URL := "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=%s"
const AUTH_REFRESH_URL := "https://securetoken.googleapis.com/v1/token?key=%s"

## Environment variable that enables the level-designer dev flow: when set,
## clearing a playtested custom level saves it as a real game level (.tres under
## res://levels/) exactly like the original editor behaviour. When unset,
## clearing a custom level offers the social flow instead (challenge a friend /
## post to profile).
const DEV_LEVELS_ENV := "ACNO_DEV_LEVELS"

static func dev_levels_mode() -> bool:
	return not OS.get_environment(DEV_LEVELS_ENV).is_empty()
