/**
 * Social backend for redkey-bluekey — implements docs/social_backend_contract.md.
 *
 * One HTTPS function (`api`) hosting an Express app. Identity comes ONLY from
 * the verified Firebase ID token; request bodies never name the caller.
 * Firestore is locked to deny all client access (firestore.rules) — the Admin
 * SDK here is the single writer.
 *
 * Collections: users/{uid}, friendRequests/{id}, friendships/{a_b}, challenges/{id}.
 */
const { onRequest } = require("firebase-functions/v2/https");
const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { getMessaging } = require("firebase-admin/messaging");
const express = require("express");

initializeApp();
const db = getFirestore();
const app = express();
app.use(express.json({ limit: "32kb" }));

// ---------------------------------------------------------------------------
// Auth: verify the Firebase ID token on every request.
// ---------------------------------------------------------------------------
app.use(async (req, res, next) => {
  const m = (req.headers.authorization || "").match(/^Bearer (.+)$/);
  if (!m) return res.status(401).json({ error: "Missing bearer token" });
  try {
    req.uid = (await getAuth().verifyIdToken(m[1])).uid;
    return next();
  } catch (e) {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
});

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------
const MAX_DIM = 32;
const GLYPHS = /^[.#DRXTAB12WPQG \n]*$/; // tile_types.gd vocabulary + space/newline

/** Mirrors the client's LevelLoader.validate, plus size/charset caps. */
function validateLayout(layout) {
  if (typeof layout !== "string" || layout.length === 0) return "layout required";
  if (layout.length > 4096) return "layout too large";
  const clean = layout.replace(/\r/g, "");
  if (!GLYPHS.test(clean)) return "layout contains unknown glyphs";
  const rows = clean.split("\n");
  if (rows.length > MAX_DIM || rows.some((r) => r.length > MAX_DIM)) {
    return "layout exceeds max board size";
  }
  const count = (ch) => clean.split(ch).length - 1;
  if (count("A") !== 1) return "layout must contain exactly one 'A'";
  if (count("T") < 1) return "layout must contain a teleporter 'T'";
  if (count("1") < 1) return "layout must contain a red key '1'";
  if (count("2") < 1) return "layout must contain a blue key '2'";
  return "";
}

function cleanDisplayName(name) {
  if (typeof name !== "string") return null;
  const trimmed = name.trim();
  if (trimmed.length < 1 || trimmed.length > 24) return null;
  return trimmed;
}

function clampTries(v) {
  const n = Number.isFinite(Number(v)) ? Math.floor(Number(v)) : 1;
  return Math.min(Math.max(n, 1), 9999);
}

/** Validate + normalise a challenge payload; returns {error} or {payload}. */
function cleanPayload(payload) {
  if (typeof payload !== "object" || payload === null) return { error: "payload required" };
  const layoutErr = validateLayout(payload.layout);
  if (layoutErr) return { error: layoutErr };
  return {
    payload: {
      levelId: String(payload.levelId || "custom").slice(0, 32),
      seed: Math.floor(Number(payload.seed) || 0),
      scoreToBeat: Math.floor(Number(payload.scoreToBeat) || 0),
      triesToBeat: clampTries(payload.triesToBeat),
      layout: String(payload.layout).replace(/\r/g, ""),
    },
  };
}

const publicFields = (u) => ({
  uid: u.uid,
  displayName: u.displayName,
  friendCode: u.friendCode,
});

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------
/** Friend codes look like "KQ-4821" — resolvable server-side only. */
function randomFriendCode() {
  const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"; // no I/O (ambiguous)
  const l = () => letters[Math.floor(Math.random() * letters.length)];
  const digits = String(Math.floor(1000 + Math.random() * 9000));
  return `${l()}${l()}-${digits}`;
}

async function uniqueFriendCode() {
  for (let i = 0; i < 8; i++) {
    const code = randomFriendCode();
    const clash = await db.collection("users").where("friendCode", "==", code).limit(1).get();
    if (clash.empty) return code;
  }
  throw new Error("could not allocate a friend code");
}

/** Get-or-create: first GET /me provisions the profile + friend code. */
async function getOrCreateProfile(uid) {
  const ref = db.collection("users").doc(uid);
  const snap = await ref.get();
  if (snap.exists) return snap.data();
  const profile = {
    uid,
    displayName: `Player ${uid.slice(0, 5)}`,
    friendCode: await uniqueFriendCode(),
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
    stats: { levelsCleared: 0, challengesWon: 0 },
    postedLevels: [],
  };
  await ref.create(profile); // create() so a concurrent first-call can't clobber
  return (await ref.get()).data();
}

app.get("/me", async (req, res) => {
  res.json(await getOrCreateProfile(req.uid));
});

app.patch("/me", async (req, res) => {
  const name = cleanDisplayName(req.body.displayName);
  if (name === null) return res.status(400).json({ error: "displayName must be 1-24 characters" });
  await getOrCreateProfile(req.uid);
  const ref = db.collection("users").doc(req.uid);
  await ref.update({ displayName: name, updatedAt: FieldValue.serverTimestamp() });
  res.json((await ref.get()).data());
});

app.post("/me/levels", async (req, res) => {
  const { error, payload } = cleanPayload(req.body);
  if (error) return res.status(400).json({ error });
  await getOrCreateProfile(req.uid);
  const ref = db.collection("users").doc(req.uid);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const posted = snap.get("postedLevels") || [];
    posted.push({ ...payload, postedAt: new Date().toISOString() });
    while (posted.length > 20) posted.shift(); // keep the 20 most recent
    tx.update(ref, { postedLevels: posted, updatedAt: FieldValue.serverTimestamp() });
  });
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Push devices  (users/{uid}/devices/{deviceId})  — supports many per user.
// Clients send their FCM token here; never store server keys client-side.
// ---------------------------------------------------------------------------
app.post("/me/devices", async (req, res) => {
  const { fcmToken, deviceId, platform, appVersion } = req.body || {};
  if (typeof fcmToken !== "string" || !fcmToken) {
    return res.status(400).json({ error: "fcmToken required" });
  }
  if (typeof deviceId !== "string" || !deviceId) {
    return res.status(400).json({ error: "deviceId required" });
  }
  await getOrCreateProfile(req.uid);
  await db.collection("users").doc(req.uid).collection("devices").doc(deviceId).set(
    {
      fcmToken,
      deviceId,
      platform: platform === "android" ? "android" : "ios",
      appVersion: String(appVersion || ""),
      notificationsEnabled: true,
      lastUpdated: FieldValue.serverTimestamp(),
    },
    { merge: true }
  );
  res.json({ ok: true });
});

app.post("/me/devices/:deviceId/disable", async (req, res) => {
  const ref = db.collection("users").doc(req.uid).collection("devices").doc(req.params.deviceId);
  if (!(await ref.get()).exists) return res.status(404).json({ error: "device not found" });
  await ref.update({ notificationsEnabled: false, lastUpdated: FieldValue.serverTimestamp() });
  res.json({ ok: true });
});

// List the caller's own devices (for device management / testing).
app.get("/me/devices", async (req, res) => {
  const snap = await db.collection("users").doc(req.uid).collection("devices").get();
  res.json(snap.docs.map((d) => ({ id: d.id, ...d.data() })));
});

/**
 * Send a push to all of a user's notification-enabled devices and prune any
 * tokens FCM reports as invalid. Fire-and-forget: never block / fail the
 * originating request because a notification couldn't be sent.
 */
async function notifyUser(uid, notification, data = {}) {
  try {
    const snap = await db
      .collection("users").doc(uid).collection("devices")
      .where("notificationsEnabled", "==", true).get();
    const tokens = snap.docs.map((d) => d.get("fcmToken")).filter(Boolean);
    console.log(`notifyUser ${uid}: ${tokens.length} token(s)`);
    if (tokens.length === 0) return;
    // FCM data values must be strings.
    const stringData = {};
    for (const [k, v] of Object.entries(data)) stringData[k] = String(v);
    const resp = await getMessaging().sendEachForMulticast({tokens, notification, data: stringData});
    // Prune ONLY tokens FCM reports as genuinely dead. Everything else
    // (third-party-auth-error from APNs config, transient network errors, etc.)
    // is logged but never pruned — those are not the device token's fault.
    const STALE = new Set([
      "messaging/registration-token-not-registered",
      "messaging/invalid-registration-token",
    ]);
    const removals = [];
    resp.responses.forEach((r, i) => {
      if (r.error) {
        console.warn(`notifyUser ${uid}: send error [${r.error.code}] ${r.error.message}`);
        if (STALE.has(r.error.code)) removals.push(snap.docs[i].ref.delete());
      }
    });
    console.log(`notifyUser ${uid}: ${resp.successCount} sent, ${removals.length} pruned`);
    await Promise.all(removals);
  } catch (e) {
    console.error("notifyUser failed", uid, e);
  }
}

// ---------------------------------------------------------------------------
// Friends
// ---------------------------------------------------------------------------
const friendshipId = (a, b) => [a, b].sort().join("_");

async function areFriends(a, b) {
  return (await db.collection("friendships").doc(friendshipId(a, b)).get()).exists;
}

app.get("/friends", async (req, res) => {
  const snaps = await db.collection("friendships")
    .where("users", "array-contains", req.uid).get();
  const otherIds = snaps.docs.map((d) => d.get("users").find((u) => u !== req.uid));
  const friends = [];
  for (const uid of otherIds) {
    const u = await db.collection("users").doc(uid).get();
    if (u.exists) friends.push(publicFields(u.data()));
  }
  res.json(friends);
});

app.get("/friends/requests", async (req, res) => {
  // Two single-field queries (no composite index needed); status filtered here.
  const [incoming, outgoing] = await Promise.all([
    db.collection("friendRequests").where("toUserId", "==", req.uid).get(),
    db.collection("friendRequests").where("fromUserId", "==", req.uid).get(),
  ]);
  const rows = [];
  for (const d of incoming.docs) rows.push({ id: d.id, direction: "incoming", ...d.data() });
  for (const d of outgoing.docs) rows.push({ id: d.id, direction: "outgoing", ...d.data() });
  res.json(rows.filter((r) => r.status === "pending"));
});

app.post("/friends/requests", async (req, res) => {
  const code = String(req.body.friendCode || "").trim().toUpperCase();
  if (!code) return res.status(400).json({ error: "friendCode required" });
  const me = await getOrCreateProfile(req.uid);

  const match = await db.collection("users").where("friendCode", "==", code).limit(1).get();
  if (match.empty) return res.status(404).json({ error: "No player with that friend code" });
  const target = match.docs[0].data();
  if (target.uid === req.uid) return res.status(400).json({ error: "That's your own code" });
  if (await areFriends(req.uid, target.uid)) {
    return res.status(409).json({ error: "Already friends" });
  }
  const dupe = await db.collection("friendRequests")
    .where("fromUserId", "==", req.uid).get();
  if (dupe.docs.some((d) => d.get("toUserId") === target.uid && d.get("status") === "pending")) {
    return res.status(409).json({ error: "Request already pending" });
  }

  const ref = await db.collection("friendRequests").add({
    fromUserId: req.uid,
    toUserId: target.uid,
    fromDisplayName: me.displayName,
    toDisplayName: target.displayName,
    status: "pending",
    createdAt: FieldValue.serverTimestamp(),
    respondedAt: null,
  });
  notifyUser(target.uid,
    { title: "New friend request", body: `${me.displayName} wants to be friends` },
    { type: "friend_request", requestId: ref.id });
  res.json({ id: ref.id, direction: "outgoing", ...(await ref.get()).data() });
});

app.post("/friends/requests/:id/respond", async (req, res) => {
  const accept = req.body.accept === true;
  const ref = db.collection("friendRequests").doc(req.params.id);
  try {
    const updated = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw { status: 404, error: "Request not found" };
      const r = snap.data();
      if (r.toUserId !== req.uid) throw { status: 403, error: "Only the recipient may respond" };
      if (r.status !== "pending") throw { status: 409, error: "Request already resolved" };
      tx.update(ref, {
        status: accept ? "accepted" : "rejected",
        respondedAt: FieldValue.serverTimestamp(),
      });
      if (accept) {
        // Friendships are ONLY ever written here — never by clients.
        tx.set(db.collection("friendships").doc(friendshipId(r.fromUserId, r.toUserId)), {
          users: [r.fromUserId, r.toUserId].sort(),
          createdAt: FieldValue.serverTimestamp(),
        });
      }
      return { id: snap.id, ...r, status: accept ? "accepted" : "rejected" };
    });
    if (accept) {
      notifyUser(updated.fromUserId,
        { title: "Friend request accepted", body: `${updated.toDisplayName} is now your friend` },
        { type: "friend_accepted", userId: updated.toUserId });
    }
    res.json(updated);
  } catch (e) {
    res.status(e.status || 500).json({ error: e.error || "Internal error" });
  }
});

// ---------------------------------------------------------------------------
// Challenges
// ---------------------------------------------------------------------------
app.get("/challenges", async (req, res) => {
  const [out, inc] = await Promise.all([
    db.collection("challenges").where("fromUserId", "==", req.uid).get(),
    db.collection("challenges").where("toUserId", "==", req.uid).get(),
  ]);
  const rows = {};
  for (const d of [...out.docs, ...inc.docs]) rows[d.id] = { id: d.id, ...d.data() };
  res.json(Object.values(rows));
});

app.post("/challenges", async (req, res) => {
  const toUserId = String(req.body.toUserId || "");
  const { error, payload } = cleanPayload(req.body.payload);
  if (error) return res.status(400).json({ error });
  if (!toUserId) return res.status(400).json({ error: "toUserId required" });
  if (!(await areFriends(req.uid, toUserId))) {
    return res.status(403).json({ error: "Challenges can only be sent to accepted friends" });
  }
  const me = await getOrCreateProfile(req.uid);
  const target = await db.collection("users").doc(toUserId).get();
  if (!target.exists) return res.status(404).json({ error: "Recipient not found" });

  const ref = await db.collection("challenges").add({
    fromUserId: req.uid,
    toUserId,
    fromDisplayName: me.displayName,
    toDisplayName: target.get("displayName"),
    status: "pending",
    payload,
    result: null,
    createdAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  });
  notifyUser(toUserId,
    { title: "New challenge!", body: `${me.displayName} challenged you` },
    { type: "challenge", challengeId: ref.id });
  res.json({ id: ref.id, ...(await ref.get()).data() });
});

app.post("/challenges/:id/respond", async (req, res) => {
  const accept = req.body.accept === true;
  const ref = db.collection("challenges").doc(req.params.id);
  try {
    const updated = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw { status: 404, error: "Challenge not found" };
      const c = snap.data();
      if (c.toUserId !== req.uid) throw { status: 403, error: "Only the recipient may respond" };
      if (c.status !== "pending") throw { status: 409, error: "Challenge already resolved" };
      const status = accept ? "accepted" : "declined";
      tx.update(ref, { status, updatedAt: FieldValue.serverTimestamp() });
      return { id: snap.id, ...c, status };
    });
    res.json(updated);
  } catch (e) {
    res.status(e.status || 500).json({ error: e.error || "Internal error" });
  }
});

app.post("/challenges/:id/complete", async (req, res) => {
  // The client's result is ADVISORY ({tries}); the winner is decided here by
  // comparing against the sender's recorded triesToBeat. Move-by-move replay
  // validation is future work — until then tries is clamped, never trusted raw.
  const tries = clampTries((req.body.result || {}).tries);
  const ref = db.collection("challenges").doc(req.params.id);
  try {
    const updated = await db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      if (!snap.exists) throw { status: 404, error: "Challenge not found" };
      const c = snap.data();
      if (c.toUserId !== req.uid) throw { status: 403, error: "Only the recipient may complete" };
      if (c.status !== "accepted") throw { status: 409, error: "Challenge must be accepted first" };
      const senderTries = clampTries(c.payload.triesToBeat);
      const winnerUserId = tries <= senderTries ? c.toUserId : c.fromUserId;
      const result = {
        winnerUserId,
        fromResult: { tries: senderTries },
        toResult: { tries },
      };
      tx.update(ref, { status: "completed", result, updatedAt: FieldValue.serverTimestamp() });
      tx.update(db.collection("users").doc(winnerUserId), {
        "stats.challengesWon": FieldValue.increment(1),
      });
      return { id: snap.id, ...c, status: "completed", result };
    });
    res.json(updated);
  } catch (e) {
    res.status(e.status || 500).json({ error: e.error || "Internal error" });
  }
});

app.use((req, res) => res.status(404).json({ error: "No such route" }));

// Deterministic URL: https://us-central1-redkey-bluekey.cloudfunctions.net/api
exports.api = onRequest({ region: "us-central1", maxInstances: 4 }, app);
