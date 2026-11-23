# I1: The indoor module (Splat)

Inside a building GPS is off by more than a corridor is wide, sees no obstacles, and can't tell one row of seats from the next. 4u gets the user to a building. The indoor module takes them from the building's entrance to a seat. It was proposed by a professor at EAFIT in November 2026, and this record is how it fits 4u.

**4u comes first.** The module's code that runs in the app or on the server (I4 onwards) starts only after 0.6.4. By then the outdoor fixes (P0: deployment, metrics, device matrix; P1: position and heading) are released and measured. I1–I3 don't touch 4u's running code, so they can go ahead in parallel. Milestone: **0.7.0**.

## Rules

- **Off by default.** With `indoor_enabled` off, 4u behaves exactly as before, and the existing e2e suite proves it on every PR.
- **Additive only.** New tables and nullable columns, with nothing renamed or dropped (the compatibility rule in the root `CLAUDE.md`).
- **No new dependencies in the 4u services.** PyTorch, hloc, LightGlue and COLMAP live only in `backend-indoor-positioning/` and `tools/space-builder/`.
- **Its own Compose profile.** `docker compose up` still starts the seven 4u services, and `--profile indoor` adds the eighth.
- **The cane comes first.** The app guides and warns; it never replaces the white cane.
- **Images stay private.** Classroom images are processed on our own machine and aren't kept outside tests. Niantic is used only with ethics approval.

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
2. **Arrival** at that anchor (4u's normal arrival check): "Llegaste a la entrada del salón. ¿Entrar en modo interior?"
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
| `db_schema/indoor_*.sql` + a migration | `spaces`, `space_packages`, `space_targets`. Nullable `anchor_points.space_id` (part of #86's geofences). `navigation_sessions.mode` (`outdoor` by default). Storage bucket `space-packages` | I2 |
| `tools/space-builder/` | Its own `uv` project on the GPU PC: capture → COLMAP → splat → package. It can also take a Scaniverse PLY or mesh. CI tests only its pure-Python parts | I3 |
| `backend-indoor-positioning/` | The 8th FastAPI service: `GET /spaces`, `GET /spaces/{id}/package`, `POST /relocalize`, `WS /stream` (image + ARCore pose at 10 Hz), and admin endpoints. Uses `packages` for auth, the version guard and DB errors | I4 |
| `application/android/.../indoor/` + `application/pigeons/indoor.dart` | Kotlin: ARCore pose and depth, a 4×4 m local grid by height band, the obstacle reflex, beacon audio and haptics | I5 |
| `application/lib/indoor/` | The Flutter indoor mode, the handoff, indoor targets in "¿A dónde quieres ir?" (D12 voice rules) | I6 |
| Admin app | Create a space, link its entry anchor, upload a package, name its targets | I7 |
| `backend-navigation-management` | Indoor walks logged with `mode = indoor` | I8 |

### `Relocalizer`

One interface, two backends, chosen by configuration:
- **Own:** EigenPlaces retrieval (the model `backend-ai-training` already uses) on the collection `indoor_keyframes`, then SuperPoint + LightGlue and PnP-RANSAC. Runs in `backend-indoor-positioning`.
- **Niantic VPS 2.0:** runs on the phone (NSDK, Kotlin) and reports its pose through the same contract. It needs an API key and ethics approval, because classroom images go to Niantic. It's tried as a baseline in the same classroom. If it relocalizes as well or better, it's used for new spaces, and our own stays as the cloud-free fallback.

## Where it runs

The lab refuses machines above `.large` and has no GPUs, so the service runs on a **team laptop or PC with a GPU** through the pilot, one user at a time. The phone and the laptop share a hotspot or a router of our own, because campus Wi-Fi may isolate devices.
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

Before the pilot comes a blindfolded test with a companion, door → seat, passed 3 times in a row. The pilot itself has 5–10 blind participants, an orientation and mobility instructor and ethics approval. Results go into the #181 test report.

## Risks

| Risk | Mitigation |
|---|---|
| The entry anchor is several metres from the door | The package includes the arrival corridor; Wi-Fi as confirmation |
| The native camera clashes with 4u's camera plugin | One owner at a time (above) |
| The laptop service doesn't scale | One user at a time until the pilot; then more perception on the phone (LiteRT) |
| Campus Wi-Fi isolates devices | A hotspot or a router of our own |
| Ethics committee rejects classroom images | Processing on our own machine, nothing kept; Niantic only with approval |
