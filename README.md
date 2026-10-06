to allow conection from the front end to collect the data in my machine

```bash
sudo ufw disable
```

to create the common forlder for the mono repo follow this tutorial [https://medium.com/@life-is-short-so-enjoy-it/python-monorepo-with-uv-f4ced6f1f425](link)

uv init py-zcommonlib --lib


# Project Definition: GPS Positioning Correction System using AI for Visually Impaired Navigation Assistance

---

## Objective

Develop an assisted navigation system for visually impaired individuals in university environments that **corrects GPS error** (currently 5 to 20 meters) using **computer vision and artificial intelligence**, without requiring additional physical infrastructure (BLE beacons, LIDAR sensors, etc.). The system runs on the user's smartphone and cloud servers, using a hybrid approach that combines **machine learning (visual feature extraction)** and **statistical filtering (Kalman Filter)**.

---

## Technical and Scientific Justification

- **GPS Limitation:** In urban environments and near buildings, GPS has errors of up to 20 meters, insufficient to safely guide a visually impaired person.

- **Costly Physical Infrastructure:** Solutions like Lazarillo and Evelity require BLE beacons (hundreds per building), with high installation and maintenance costs. Our proposal eliminates this need.

- **Scientific Support:** The literature (Zhuang et al., 2023) validates that sensor fusion (GPS + camera + IMU) with machine learning methods outperforms traditional approaches. Computer vision models (YOLO, CNNs) already achieve >83% accuracy in real-time (Ben Attallah et al., 2023).

- **Feasibility:** The user's smartphone is the only required hardware. Heavy processing (AI) is delegated to servers, keeping the app lightweight and accessible.

---

## System Components

### Single Mobile Application (Flutter)

- **Role-Based Access:** Single codebase with two user roles:
  - **User Role:** Sends real-time data (photo, GPS, heading, accelerometer/gyroscope) to the server and receives corrected position for guidance.
  - **Admin Role:** Collects **anchor points** (photos with exact coordinates or ground truth) at strategic campus locations (entrances, intersections, elevators). These points feed the vector database.
- **Testing:** Flutter testing to ensure frontend quality.

### Backend (Python + FastAPI + uv)

Independent microservices for:
- Authentication and role management.
- Data collection and validation.
- **AI Inference** (real-time).
- **Model Training** (offline).
- Route and map management.
- **Unit and integration tests:** pytest for the backend.
- **Code formatting:** Black for consistent Python style.

### Storage

- **Supabase (PostgreSQL):** Users, roles, routes, anchor point metadata.
- **Supabase Storage (S3):** Image storage.
- **Qdrant (Vector Database):** Stores **embeddings** (visual feature vectors) of anchor points for millisecond similarity search.

### Artificial Intelligence (PyTorch + OpenCV)

- **Feature Extractor:** Pre-trained CNN (e.g., ResNet, EfficientNet) that converts any image into a numerical embedding. Trained **once** with anchor point photos.
- **Vector Database (Qdrant):** Indexes embeddings and their associated coordinates. During inference, receives the user's photo embedding and returns the coordinate of the most visually similar anchor point.
- **Kalman Filter:** Fuses in real-time the inertial prediction (IMU), noisy GPS (used only as a geographic filter), and visual correction (anchor point coordinate) to generate a smooth and accurate final position (< 5 meters error).

### Development and CI/CD

- **Version Control:** Git with branch-based workflow (main/develop/features).
- **Continuous Integration and Delivery (CI/CD):** GitHub Actions to automate testing, formatting, and deployment.
- **Code Quality:** Black (Python), Dart format (Flutter), and automated tests (pytest for backend, Flutter testing for frontend).
- **Development Assistant:** Claude Code as a support tool for code writing and review.

---

## Data Flow (Real-Time Inference)

1. **User walks:** App sends every 1-2 seconds: photo + GPS + heading + IMU.
2. **Server (FastAPI):** Receives and authenticates the request.
3. **OpenCV:** Preprocesses the image (resize, normalize).
4. **PyTorch:** Extracts the embedding from the image.
5. **Qdrant:** Searches for the most similar embeddings among anchor points (filtered by geographic proximity using noisy GPS as a filter).
6. **Qdrant:** Returns the exact coordinate of the most similar anchor point.
7. **Kalman Filter:** Fuses inertial prediction (IMU), noisy GPS, and visual correction to calculate the corrected position.
8. **FastAPI:** Returns the corrected coordinate to the App.
9. **App:** Uses the corrected coordinate to provide safe navigation instructions.

---

## Training Process (Offline)

1. **Anchor point collection:** Trained personnel (admin role) walks the campus taking photos at strategic points (entrances, intersections, elevators) with **exact** coordinates (ground truth obtained with high-precision GPS or manual correction on satellite map).
2. **Storage:** Photo → S3, metadata → Supabase.
3. **Embedding extraction:** PyTorch processes photos and generates embeddings.
4. **Indexing in Qdrant:** Embeddings are stored along with their exact coordinates and metadata (building, floor, heading).
5. **The feature extractor model is trained once** and does not need retraining when adding new points; only new embeddings are indexed in Qdrant.

---

## Validation and Evaluation

### Phase 1 (Technical - Laboratory)
- **Metric:** Positioning error (meters) – compare raw GPS vs. corrected GPS.
- **Goal:** Reduce error from 20m to < 5m.
- **Metric:** System latency (< 500ms).

### Phase 2 (Users - Campus)
- **Metric:** Success rate in completing routes without incidents (> 90%).
- **Metric:** Usability (System Usability Scale, SUS > 70).
- **Participants:** Visually impaired users in controlled campus tests.

---

## Local Setup & End-to-End Testing

Each component's own README documents testing it in isolation (`uv run pytest` per backend service, `flutter test` for the app). This section is for testing them *together* — standing up every component against one Supabase project and exercising the real signup → admin capture → route → navigation flow.

### 1. Create a Supabase project

Create one at [supabase.com](https://supabase.com) (or use an existing project). From **Project Settings → API**, note down the **Project URL**, the **anon / publishable** API key, and the **service_role secret** — every `SUPABASE_URL` value below is the same URL; the app's own `.env` (step 5) uses the publishable key, while all 5 backend services (step 4) use the service_role key. **The service_role key bypasses Row Level Security and has full database access — never put it in the app's `.env` or anywhere client-facing, only in the backend services' gitignored `.env` files.**

### 2. Apply the schema

In the Supabase SQL editor, run the files in `db_schema/` **in this order** (later tables reference earlier ones by foreign key):

```
places.sql
roles.sql            -- self-seeds 'user'/'admin'
location_type.sql    -- self-seeds 9 location types
profiles.sql
buildings.sql
anchor_points.sql    -- run `CREATE EXTENSION IF NOT EXISTS btree_gist;` first -
                      -- its GiST index needs it
anchor_point_photos.sql  -- one row per photo (~4-8 per anchor point);
                          -- must come after anchor_points.sql
anchor_point_connections.sql  -- walkability graph edges between anchor points
routes.sql
navigation_sessions.sql
navigation_logs.sql
user_feedback.sql
```

`places` and `buildings` have no seed data. Once the app and `backend-map-management` are running (steps 4-5 below), an admin can create both from the app itself (sign in as `admin` → the **Places**/**Buildings** tab's floating action button) — no SQL needed. To seed them by hand instead (e.g. before the app is running):

```sql
INSERT INTO places (id, code, name, latitude, longitude)
VALUES ('11111111-1111-1111-1111-111111111111', 'CAMPUS', 'Main Campus', 6.2442, -75.5812);

INSERT INTO buildings (id, place_id, code, name, latitude, longitude)
VALUES ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111', 'B1', 'Building 1', 6.2442, -75.5812);
```

### 3. Create Storage buckets

In Supabase Storage, create two **public** buckets — neither service creates its bucket automatically:
- `Photo` (used by `backend-data-collection`)
- `anchor-points` (used by `backend-map-management`)

### 4. Run the backend services

The app talks to all 6 services through a single **API gateway** (`gateway/nginx.conf`, path-prefix reverse proxy) rather than 6 separate ports — see it running via Docker Compose:

```bash
# fill in each service's .env first
for d in backend-data-collection backend-map-management backend-route-management backend-user-management backend-navigation-management backend-ai-training; do
  (cd "$d" && cp .env.example .env)   # fill in credentials from step 1 (backend-ai-training only needs QDRANT_URL/QDRANT_KEY)
done

docker compose up --build
```

This starts all 6 services (no longer individually host-exposed) plus the `gateway` service on port **8000**, which is what the app actually talks to:

| Gateway path prefix | Routes to |
|---|---|
| `/data-collection/*` | `backend-data-collection` |
| `/map/*` | `backend-map-management` |
| `/route/*` | `backend-route-management` |
| `/user/*` | `backend-user-management` |
| `/navigation/*` | `backend-navigation-management` |
| `/ai-training/*` | `backend-ai-training` |

e.g. `POST http://localhost:8000/route/routes` reaches `backend-route-management`'s `POST /routes`. The gateway's port is published on `0.0.0.0`, so it's reachable from another device on the same WiFi network at `http://<your-LAN-IP>:8000`, not just from `localhost` — this matters because the app is normally tested on a physical phone (see step 5), which can't reach the dev machine's `localhost`.

(`backend-data-collection`'s `.env.example` also declares `QDRANT_URL`/`QDRANT_KEY` — nothing in the service currently reads them, so any placeholder value there is fine.)

**To iterate on a single service in isolation** (its own Swagger UI, curl, pytest) rather than through the app, you can still run it standalone with `uv run fastapi dev --port <port>` from within that service's directory — that bypasses the gateway entirely and talks to the service directly, which is fine for isolated debugging but won't be reachable by the app (which only ever calls the gateway's one URL).

### 5. Configure and run the app

```bash
cd application
cp .env.example .env
flutter pub get
flutter run
```

Fill in `application/.env` with the same Supabase URL/key plus the gateway's URL:

```
SUPABASE_URL=https://<project>.supabase.co
SUPABASE_PUBLISHABLE_KEY=<anon key>
API_GATEWAY_URL=http://localhost:8000
```

**If running on a physical phone rather than an emulator — the usual way this app is tested — you must use your machine's LAN IP instead of `localhost`** for `API_GATEWAY_URL`, since the phone can't resolve the dev machine's `localhost`:

```bash
# find your LAN IP
ip addr show | grep 'inet ' | grep -v 127.0.0.1   # Linux
ipconfig getifaddr en0                              # macOS (Wi-Fi)
```

e.g. `API_GATEWAY_URL=http://192.168.1.23:8000`. Also confirm the phone and dev machine are on the same WiFi network, and that the dev machine's firewall allows inbound connections on port 8000 (e.g. on Linux with `ufw` active: `sudo ufw allow 8000/tcp`). See `application/README.md` for ADB pairing steps.

### 6. Run every automated test suite

```bash
for d in packages backend-data-collection backend-ai-training backend-map-management backend-route-management backend-user-management backend-navigation-management; do
  (cd "$d" && uv sync && uv run pytest)
done

cd application && flutter test && flutter analyze
```

### 7. Manual end-to-end walkthrough

1. **Sign up** in the app (creates a Supabase Auth user, then a `profiles` row via `backend-user-management`'s `POST /profiles` with `role_id: 1`).
2. **Promote to admin**: in Supabase, `UPDATE profiles SET role_id = 2 WHERE id = '<the new user's auth id>';` — there's no in-app admin-invite flow yet. Log out and back in.
3. **Capture two anchor points** from the admin screen — if you didn't already create a place/building via SQL in step 2, use the app bar's **Add place** then **Add building** first. Take a photo, pick the building, submit; do this twice in the same building. Open each from **Anchor points** and set its status to **verified** (this both indexes it into Qdrant and is required for the picker in step 6 - unverified points aren't offered as trip start/end choices).
4. **Connect the two anchor points**: from the drawer, open **Connections** → **Connect on map**, tap one anchor point then the other. This writes an `anchor_point_connections` row - without it, step 6's trip has no walkable path between the two points and `find_or_create` 404s.
5. **Sign up a second, regular user** and log in as them.
6. On `UserHomeScreen`, tap **Where to?** and pick the second anchor point as the destination (Place → Building → anchor point drill-down) - the start point is auto-selected as the verified anchor point nearest your current GPS fix, so make sure you're actually near the first anchor point when you do this. Tap **Find route** — this calls `POST /routes/find_or_create`, which computes a path over the connection from step 4 and creates the route on the fly (no manual route-creation step needed anymore).
7. Confirm `navigation_logs` rows accumulate in Supabase roughly every second while `NavigationScreen` stays open (a self-rescheduling loop, not a fixed timer - see `application/CLAUDE.md`'s "Position correction tick"). With a working camera and the verified, indexed anchor points nearby, `corrected_lat`/`corrected_long`/`anchor_match_id`/`confidence_score` populate too; otherwise (no camera on an emulator, no nearby match, `backend-positioning` unreachable) those columns stay `NULL` and only raw GPS is logged for that tick - this is the designed degradation, not a bug.
8. Tap **End navigation** and optionally leave feedback — confirm the session's `status` becomes `completed` and (if entered) a `user_feedback` row appears.
9. **As the admin**, open the drawer's **Live sessions** while the regular user is mid-navigation (steps 6-8) - the active session should appear, and tapping **Watch** should show its trail growing on the map roughly every 4 seconds.

---

## Current Development Status

Tracked 1:1 against the GitHub issues seeded from the week-by-week schedule below (`gh issue list`) plus the admin-tooling work that schedule didn't anticipate. Last audited 2026-10-06.

- **Week 1 — done.** Git branches + CI, Supabase/Qdrant deployed, `uv`/`pyproject.toml` across components, lint+test on every PR.
- **Weeks 2, 3 — partially done.** Done: image preprocessing (OpenCV decode/resize), embedding extraction (pretrained EfficientNet-B0, no fine-tuning), Qdrant indexing (`POST /index_anchor`) and similarity search (`POST /search_similar`) — both real endpoints in `backend-ai-training`, both now with a real caller (an admin-verified anchor point indexes automatically; `NavigationScreen`'s correction tick, via `backend-positioning`, drives the search). Still open: fine-tuning the model on campus images (issue #17, deliberately deferred), and the >80%-accuracy search-validation deliverable (issue #22) — there isn't enough real anchor-point data indexed yet to validate against.
- **Weeks 4, 5, 7 — done.** Supabase Storage upload, Flutter clean-architecture + Auth login/signup, admin photo+coordinate capture, live user photo+GPS+IMU capture screen (issue #35), JWT/role validation in FastAPI (issue #24 — every backend service now requires a verified Supabase bearer token, admin-only or admin-or-self depending on the endpoint, except `backend-ai-training`'s `POST /search_similar`, deliberately left open and tracked on #110), the 20-anchor-point PoC deliverable, corrected-position map visualization (`NavigationScreen` now shows a second marker + text row once a correction lands). Still open: embedding-extractor/Qdrant unit tests as issue #25 originally scoped it (covered in substance now by `backend-ai-training`'s own test suite, but not formally closed under that issue), differentiated user/admin navigation beyond role-based home-screen routing.
- **Week 6, 8 — done, scoped down.** UKF/sensor fusion (`backend-positioning`'s `POST /correct_position`, issues #31-34) and `NavigationScreen` wiring are real and live now. Scoped to **GPS + visual only, not GPS + IMU + visual** — no IMU (accelerometer/gyroscope) capture exists anywhere in the app, confirmed by exhaustive grep (see `backend-positioning/CLAUDE.md`); a follow-up issue (#120) tracks adding it. No navigation instructions/guidance line yet (speaking/haptic feedback on a correction, turn-by-turn prompts) — the correction is computed and logged but surfaced only as a silent text row + map pin, not yet accessible to the visually-impaired user it's for.
- **Weeks 9-12 — not due yet.**
- **Beyond the original schedule (done, admin tooling):** an API gateway in front of all 7 backend services, full admin CRUD for places/buildings/anchor points (create/edit/delete with cascade-impact warnings, search, filtered map overlays), the anchor-points/photos schema split (one point → many photos), an anchor-point-connections walkability graph with a map-tap admin UI to build it, and a real anchor-point verification workflow (pending-review queue, photo review, status-colored map markers, auto-indexing into Qdrant on verify). These went untracked by the original issue set — see issues #67-72 (each closed, crediting the PR that delivered it) for the record.

**Known gaps before testing with real data**: the correction pipeline degrades silently to raw-GPS-only logging whenever the camera, `backend-positioning`, or a visual match isn't available — there's no in-app indicator distinguishing "corrected" from "degraded to raw GPS" ticks beyond the text row simply not appearing. No voice/haptic feedback on a correction (see Week 6/8 above). `backend-ai-training`'s `/search_similar` cost/abuse exposure (#110) is still open since it stays unauthenticated by design.

---

## Technology Stack Summary

| Layer | Technology |
|-------|------------|
| Frontend (single app with roles) | Flutter (Dart) + Flutter Testing |
| Backend | Python + FastAPI + uv + pytest + Black |
| Computer Vision | OpenCV |
| Deep Learning | PyTorch |
| Vector Database | Qdrant |
| Relational Database + Storage | Supabase (PostgreSQL + S3) |
| Version Control | Git |
| CI/CD | GitHub Actions |
| Development Assistant | Claude Code |


---


# Development Schedule in 3 Months  
## Version for Slide Presentations

---

## MONTH 1: System Foundations  
*(Weeks 1–4)*

### Week 1 – Infrastructure and Environment
**Configuration of the technological ecosystem**
- Git repository with branches (`main`, `develop`, `features`) and GitHub Actions configured
- Deployment of Supabase (PostgreSQL + Storage) and Qdrant (vector database)
- Python environment with `uv` and `pyproject.toml` for dependency management
- Basic CI/CD with linting (Black) and automated tests on every PR

---

### Week 2 – AI Pipeline (Embedding Extraction)
**Implementation of the visual feature extractor**
- Loading and configuration of pre-trained **EfficientNet-B0** in PyTorch
- Image preprocessing module with OpenCV (resizing, normalization)
- **Fine-tuning** script with campus images to adapt the model to the domain
- Functional pipeline: image → vector embedding (1280 dimensions)

---

### Week 3 – Vector Database (Qdrant)
**Indexing and similarity search**
- Qdrant client for connection and collection management
- Endpoint `/index_anchor`: upload anchor point (image + exact coordinates)
- Endpoint `/search_similar`: search for top-k most similar embeddings
- Search validation with accuracy > 80% in initial tests

---

### Week 4 – Integration and Initial Testing
**Connection of all base components**
- Integration with Supabase Storage for image storage
- JWT authentication and role validation (user/admin) in FastAPI
- Unit tests (pytest) for embedding extractor and Qdrant client
- **Deliverable:** Proof of concept with 20 anchor points and functional search

---

## MONTH 2: Core System Development  
*(Weeks 5–8)*

### Week 5 – Base Mobile App (Flutter)
**First version of the mobile application**
- Flutter project with clean architecture (models, services, screens, widgets)
- Login/registration screen with JWT authentication (Supabase connection)
- Differentiated navigation for **user** (data sending) and **administrator** (anchor capture)
- **Deliverable:** App with functional authentication and roles

---

### Week 6 – Kalman Filter and Sensor Fusion
**Real-time position correction**
- Implementation of the **Unscented Kalman Filter (UKF)** with `filterpy`
- Fusion module combining: noisy GPS + heading/IMU + visual correction
- Endpoint `/correct_position`: receives photo, GPS and IMU → returns corrected position
- **Metric:** Latency < 500ms and error reduced from 20m to < 5m

---

### Week 7 – Complete App Functionalities
**Interface for both roles**
- User screen: capture photo + GPS + IMU and send to server
- Visualization of corrected position on interactive map
- Administrator screen: capture photo and select exact coordinates on map
- **Deliverable:** Complete app for real-time data sending and receiving

---

### Week 8 – Assisted Navigation
**Step-by-step navigation instructions**
- Generation of navigation instructions (text-to-speech) based on corrected position
- Checkpoint logic: "turn left in 20 meters"
- Guidance line on the map to follow the route
- **Deliverable:** User can receive complete step-by-step navigation instructions

---

## MONTH 3: Integration, Testing and Deployment  
*(Weeks 9–12)*

### Week 9 – Integration and System Testing
**Unification of all components**
- Microservices unified into a single deployment (Docker or serverless)
- Testing environment with 50 anchor points in a real building
- Load testing: simulation of 10 concurrent users
- Integration tests (pytest) for the entire end-to-end flow

---

### Week 10 – User Testing (Internal)
**Validation with visually impaired individuals**
- Recruitment of 3-5 collaborators for controlled testing
- Tests on pre-designed routes within the selected building
- Metrics: positioning error, route success rate, **SUS (System Usability Scale)**
- **Deliverable:** Test report with qualitative feedback and metrics

---

### Week 11 – Refinement and Optimization
**Adjustments based on real data**
- UKF optimization: adjustment of covariance and noise matrices
- Qdrant search improvement: cosine distance and threshold tuning
- Performance optimization: caching, image compression
- Bug fixing in the app (UI, navigation, error handling)

---

### Week 12 – Documentation, Deployment and Closure
**Final project delivery**
- Complete documentation: architecture, API, user manual
- Deployment in production environment with basic monitoring
- Preparation of final presentation and live demo
- Final acceptance testing with users and project closure

---

## Project Success KPIs

| KPI | Target | Expected Status |
|-----|--------|-----------------|
| **Positioning accuracy** | Error < 5 meters | Validated with real data |
| **System latency** | < 500 ms | Met in load testing |
| **Route success rate** | > 90% | Measured with users |
| **Usability (SUS)** | > 70 points | Survey applied |
| **Test coverage** | > 80% | Ensured with pytest |

---

## Role of Claude in Development

- Generation of boilerplate code (endpoints, models, clients)
- Implementation of the UKF and transition matrices
- Creation of automated unit tests
- Documentation and user guides
- Code review and optimization
- Design of SUS questionnaires and test guides
