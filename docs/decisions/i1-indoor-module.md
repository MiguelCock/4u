# I1: The indoor module (Splat)

Inside a building GPS is off by more than a corridor is wide, sees no obstacles, and can't tell one row of seats from the next. 4u gets the user to a building. The indoor module takes them from the building's entrance to a seat. It was proposed by a professor at EAFIT in November 2026, and this record is how it fits 4u.

**4u comes first.** Integration (I4 onwards) starts after **0.6.4**, once P0 and P1 are released and measured. P2 (0.6.5) keeps running in parallel; no indoor PR changes a 4u screen or a running service until P2 ships. I2 adds nullable columns and new tables to the database — additive, but it does touch the running schema — and I3 is a separate tool, so both can start earlier, but they merge into `develop` only when 0.7.0 opens, so they never ride along in a 0.6.x patch. Milestone: **0.7.0**; the field pilot is its own milestone, **Indoor pilot**.

## Rules

- **Off by default.** With `indoor_enabled` off, 4u behaves exactly as before, and the existing e2e suite proves it on every PR.
- **Additive only.** New tables and nullable columns, with nothing renamed or dropped (the compatibility rule in the root `CLAUDE.md`).
- **No new dependencies in the 4u services.** PyTorch, hloc, LightGlue and COLMAP live only in `backend-indoor-positioning/` and `tools/space-builder/`.
- **Its own Compose profile.** `docker compose up` still starts the seven 4u services, and `--profile indoor` adds the eighth.
- **The cane comes first.** The app guides and warns; it never replaces the white cane.
- **Images stay private.** Capture images are processed on our own machine; live frames are processed in memory on our own laptop and not stored (I21). Niantic is used only with ethics approval.
- **One PR per issue.** A phase is many small PRs into `develop`, not one phase-sized PR. The epic-sized stories were split for exactly this reason.

## Interfaces and decisions (I0)

These are the decisions every indoor story builds against. Change one here first, then the issues.

### 1. What runs where

| Where | Does | Does not |
|---|---|---|
| Phone | ARCore pose, depth, the 4×4 m local grid, the obstacle reflex, beacon and haptics, the cache of `occupancy`/`floor`/`semantics`/`graph`/`meta` | Run relocalization or the global A* in 0.7.0 |
| Laptop (`backend-indoor-positioning`) | Relocalization, global A*, the WebSocket session, indoor logs | Keep raw frames after the answer |
| Supabase / Qdrant / Storage | `spaces`/`packages`/`targets`, `indoor_keyframes`, signed package URLs, sessions/logs | Serve a public package |

`loc_db` stays with the laptop; it never goes to the phone in the own-pipeline path. The phone download is the derived maps (target: under 10 MB), not the keyframe database. If Niantic is enabled, the phone holds Niantic's map and reports its own pose through the same contract; the laptop then skips relocalization.

Poses go at 10 Hz. Images go only on relocalization/keyframes (2 Hz maximum unless a measurement shows a need); ten images a second costs bandwidth, battery and privacy while ARCore already tracks.

### 2. Network path

The gateway is on the EC2 server; the indoor service runs on a GPU laptop. The path is a tunnel (WireGuard, Tailscale or Cloudflare Tunnel) to the gateway with WSS, with the same bearer auth, version guard and a per-user connection limit as every other service. A direct phone → laptop path exists only as a test mode on a private hotspot, never for the pilot. I22 owns the tunnel, the health check and the runbook.

### 3. Privacy and data flow

| Data | Stays | Retention |
|---|---|---|
| Capture video | On the capture machine | Deleted once the package is built |
| Package keyframes | Private `space-packages` bucket | Until the space is deleted or replaced |
| Live frames | In memory on the laptop | Not written; dropped after the answer |
| Niantic | Niantic's cloud | Only with ethics approval; off by default |

The presentation's "images are processed on the device" is true only for the Niantic-on-phone path. The own pipeline sends frames over TLS to our laptop, so the ethics text and the app's privacy wording follow this table. I21 owns the approval.

### 4. Package transport

The `space-packages` bucket is private. The admin app uploads directly to Storage with a signed URL (the gateway's 15 MB limit is not raised), and the phone downloads with a signed URL and caches by space and version. A package is at most 50 MB including `loc_db`; the phone payload excludes `loc_db`. The version is pinned per session, so an upload during a walk does not change the map under the user.

### 5. Frames and transforms

The package frame is metric, right-handed, +z up, origin at the entry anchor's floor point, +x along the entry anchor's heading. `space_packages.frame` stores origin lat/lng, floor, yaw and scale. `space_targets.position` and `navigation_logs.indoor_*` use that frame. The relocalizer returns the ARCore-world → package-frame transform; the app applies it. A space is one floor in 0.7.0; multi-floor is out of scope.

### 6. Logging model

A walk can be outdoor → indoor → outdoor, so `mode` belongs on each log, not only on the session. `navigation_sessions.mode` is the starting mode for the admin list; `navigation_logs.mode` changes at the handoff and back. Indoor logs carry `space_id`, `indoor_x/y/z`, `indoor_yaw` and `package_version`; `gps_lat`/`gps_long` become nullable. I2 owns the schema, I8 the API, I23 the review.

### 7. Handoff trigger

The 5 m rule alone is inside the outdoor GPS error (`arrivalRadius` is 5–15 m). The offer appears when the entry anchor is reached with the existing two-tick arrival confirmation **and** the 5 m check, or when the user taps "I'm at the door". It is spoken and can be declined. A failure keeps 4u's last instruction and offers help; the app never claims indoor guidance without relocalization.

### 8. WebSocket contract

The stream is versioned JSON over WSS:
- client → server: `hello` (app version, space, target, session, lang, verbosity, device), `frame` (JPEG, intrinsics, ARCore pose, timestamp), `bye`;
- server → client: `pose`, `path`, `obstacle`, `status` (including "ubicación incierta"), `error`.

Auth is the bearer header at the handshake; one connection per user; max frame size; backpressure drops images before poses; reconnect resumes. The fixture lives with I16's tests.

## Map once, navigate every time

```
ONCE PER SPACE (GPU PC, tools/space-builder/)
  video  ->  COLMAP poses  ->  Gaussian splat  ->  space package (< 50 MB)

EVERY WALK (phone + backend-indoor-positioning on the GPU laptop)
  relocalize (one photo)  ->  track (ARCore 30-60 Hz)  ->  perceive (depth)
  ->  plan (A*, every 200 ms)  ->  guide (beacon sound, vibration, few words)
```

The phone never draws the splat for the user. It uses the maps derived from it.

### The space package

| Part | Content | Used for |
|---|---|---|
| `loc_db/` | Keyframes, SuperPoint descriptors, 3D points, global descriptors | Relocalizing from one photo |
| `occupancy.png` / `.json` | 5 cm grid at three heights: floor (< 0.5 m), waist (0.5–1.2 m), head (1.2–2.0 m) | Routes and fixed obstacles |
| `floor.json` | Floor heights, steps, ramps, drops | Fall alerts |
| `semantics.json` | Doors, seats by row, desk, glass, mirrors | Targets, and dangers the camera can't see |
| `graph.json` | The space's nodes and aisles | Joining 4u's graph |
| `meta.json` | Version, verified scale, capture date and lighting | Versioning |

## Two route graphs

- **Outside:** 4u's walkability graph (anchors and measured connections), unchanged. Its last node is the **entry anchor**, an anchor point whose `space_id` is set.
- **Inside:** A\* on the 5 cm occupancy grid, because at that scale it matters which side of a table you pass.
  - A **hard clearance** of 0.22 m (body radius), which can't be crossed.
  - A **soft one** up to 0.5 m, which only costs more. A single 0.4 m clearance plus the body would close a 75 cm door or a 60 cm aisle.
  - Replanned every 200 ms with live obstacles. A new obstacle overrides the scanned map and is forgotten after 2 s unseen.

## Handoff, outside ↔ inside

4u guides to the entry anchor. The module takes over only if it relocalizes; otherwise 4u's guidance stays on, and the user is never left without guidance.

1. **Outside:** the user asks for "Salón 18-302, fila 3". 4u routes to the space's entry anchor.
2. **Arrival** at that anchor (4u's two-tick arrival check plus the 5 m proximity check, or the user's "I'm at the door"): "Llegaste a la entrada del salón. ¿Entrar en modo interior?"
3. **Relocalize:** download the package unless it's cached, hand the camera over to ARCore, relocalize.
4. **Inside:** once the relocalization is good, 4u's GPS filter pauses and the module guides to the target.
5. **Failure:** no relocalization after 3 tries (10 s). The app says so, goes back to 4u's guidance and suggests asking for help.
6. **Exit:** the "Puerta" target hands control back to 4u.

### The contract

Anchor and session ids are 4u's UUIDs.

```jsonc
// 4u -> indoor module (on entering)
{"space_id": "eafit-18-302", "package_version": 3,
 "target_id": "row3", "entry_anchor_id": "<anchor uuid>",
 "session_id": "<session uuid>", "lang": "es-CO", "verbosity": "normal"}

// indoor module -> 4u (on leaving or failing)
{"result": "arrived" | "exited" | "reloc_failed" | "user_cancelled",
 "exit_anchor_id": "<anchor uuid>", "duration_s": 74,
 "contacts": 0, "session_log_url": "..."}
```

The module knows only the space and the entry anchor, nothing of 4u's GPS or graph.

## Pieces

| Where | What | Issue |
|---|---|---|
| `db_schema/indoor_*.sql` + a migration | `spaces`, `space_packages`, `space_targets`. Nullable `anchor_points.space_id` (the entry geofence; the broader #86 decision stays open). `navigation_sessions.mode` and `navigation_logs.mode` (`outdoor` by default). Storage bucket `space-packages` | I2 |
| `tools/space-builder/` | Its own `uv` project on the GPU PC: capture → COLMAP → splat → package. It can also take a Scaniverse PLY or mesh. CI tests only its pure-Python parts | I3, I12, I13 |
| `backend-indoor-positioning/` | The 8th FastAPI service: `GET /spaces`, `GET /spaces/{id}/package`, `POST /relocalize`, `WS /stream` (poses at 10 Hz, keyframes at 2 Hz), and admin endpoints. Uses `packages` for auth, the version guard and DB errors | I4, I14, I15, I16 |
| `application/android/.../indoor/` + `application/pigeons/indoor.dart` | Kotlin: ARCore pose and depth, a 4×4 m local grid by height band, the obstacle reflex, beacon audio and haptics | I5, I17, I18 |
| `application/lib/indoor/` | The Flutter indoor mode, the handoff, indoor targets in "¿A dónde quieres ir?" (D12 voice rules) | I6, I19 |
| Admin app | Create a space, link its entry anchor, upload a package, name its targets | I7, I20 |
| `backend-navigation-management` | Indoor walks logged with `mode` per log, not only per session | I8 |

### `Relocalizer`

One interface, two backends, chosen by configuration:
- **Own:** EigenPlaces retrieval (the model `backend-ai-training` already uses) on the collection `indoor_keyframes`, then SuperPoint + LightGlue and PnP-RANSAC. Runs in `backend-indoor-positioning`.
- **Niantic VPS 2.0:** runs on the phone (NSDK, Kotlin) and reports its pose through the same contract. It needs an API key and ethics approval, because classroom images go to Niantic. It's tried as a baseline in the same classroom. If it relocalizes as well or better, it's used for new spaces, and our own stays as the cloud-free fallback.

## Where it runs

The lab refuses machines above `.large` and has no GPUs, so the service runs on a **team laptop or PC with a GPU** through the pilot, one user at a time. The phone and the laptop share a hotspot or a router of our own, because campus Wi-Fi may isolate devices. The laptop reaches the gateway through I22's tunnel with WSS; the phone never talks to it directly outside test mode, and the gateway's auth, version guard and per-user limits apply.
- The gateway gets an `/indoor/` route with the WebSocket upgrade. Its upstream goes through a variable and a `resolver`, so nginx still starts without the service. Today nginx resolves every upstream at start.
- **The obstacle reflex runs on the phone**, so the < 150 ms warning never depends on the network.
- Each phone with ARCore is recorded in the device matrix (#178). The app asks for ARCore as *optional*, so phones without it still install the app.
- One camera owner: the trip screen releases its camera before ARCore opens and takes it back on return.

## Wi-Fi

Wi-Fi can only be a coarse layer:
- an RSS fingerprint or 802.11mc RTT to confirm the right entrance, and to narrow relocalization to one room;
- a fallback with step counting, under an "ubicación incierta" warning.

It never gives seat-level precision or obstacles. CSI/BFI sensing identifies people (BFId, ACM CCS 2025), so it's ruled out for privacy. First check whether the building's access points support FTM.

## Pilot targets

| Metric | Target |
|---|---|
| Position error when relocalizing at the door | < 0.3 m |
| Camera to vibration, for an obstacle | < 150 ms |
| People who reach their target, with their cane | ≥ 90 % |
| Head- or waist-height collisions | 0 |

Before the pilot comes a blindfolded test with a companion, door → seat, passed 3 times in a row. The pilot itself has 5–10 blind participants, an orientation and mobility instructor and ethics approval. Results go into `docs/testing/indoor-pilot.md` (or a new section of `field-test.md`), not the outdoor #181 report.

### How each target is measured

- **< 0.3 m at the door:** against taped marks, not the scanned map. A wrong map must show up as error.
- **< 150 ms camera → vibration:** timestamped frame plus the trigger, with the method and device in the report. A stopwatch measures human reaction time, not the app.
- **≥ 90 % arrive:** the count and its confidence interval; with 5–10 participants one miss moves it 10–20 points.
- **0 collisions:** a safety gate, not a rate. Record whether the cane or the companion prevented it, and stop the session on any collision or fall.

## Issue map

The PDF is a snapshot (18 November 2026). The issues and this record are the source of truth.

| Phase | Stories |
|---|---|
| 4u first | 0.6.2: #198, #181, #178, #310 · 0.6.3: #120, #122 · 0.6.4: #263, #300, #182, #177 · 0.6.5: #228, #262, #227, #226, #299, #191, #192 |
| I2 schema | #311 |
| I3 package | #312 · capture #322 · occupancy/semantics #323 |
| I4 service | #313 · relocalizer #324 · planner #325 · stream #326 |
| I5 Android | #314 · depth/reflex #327 · audio/haptics #328 |
| I6 handoff | #315 · targets/voice #329 |
| I7 admin | #316 · upload/targets #330 |
| I8 logs | #317 |
| I9 prototype | #318 |
| Cross-cutting | Niantic #321 · ethics #331 · network #332 · metrics/replay #333 |
| Pilot | #319 (Indoor pilot milestone) |
| Backlog | P3: #246, #245, #187, #247, #86 · P4: #94, #93, #160 · #17 (p3, not scheduled in the PDF) · WiFi/FTM #334 |

Priority labels `priority: p0`–`p4` carry the plan's P0–P4 (plus #310 and #17, which the plan predates or leaves out), so the milestone is readable without the PDF.

## Out of scope for 0.7.0

- More than one floor per space, and more than one space per trip.
- Indoor mode on iOS or the web admin.
- On-device relocalization (LiteRT) and on-device YOLO.
- WiFi/FTM in production; I24 is a Backlog spike.
- A 3D splat viewer; targets are placed on the 2D occupancy map.
- More than one user at a time on the laptop service.

## Risks

| Risk | Mitigation |
|---|---|
| The entry anchor is several metres from the door | The package includes the arrival corridor; Wi-Fi as confirmation |
| The native camera clashes with 4u's camera plugin | One owner at a time (above) |
| The laptop service doesn't scale | One user at a time until the pilot; then more perception on the phone (LiteRT) |
| Campus Wi-Fi isolates devices | A hotspot or a router of our own |
| Ethics committee rejects classroom images | Processing on our own machine, nothing kept; Niantic only with approval |
| The laptop is behind NAT | I22's tunnel, health check and runbook; no direct production path |
| A 50 MB package stalls at the door | Prefetch when the destination is a space; the phone payload excludes `loc_db` |
| A phone has ARCore but no Depth | I17 says so explicitly and keeps 4u's guidance; the matrix records it |
| The prototype's license is incompatible | I9's license check before any code is copied |
| The scanned map is wrong | The pilot's ground truth is taped, not the map (above) |
