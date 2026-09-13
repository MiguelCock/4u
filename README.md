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
routes.sql
navigation_sessions.sql
navigation_logs.sql
user_feedback.sql
```

`places` and `buildings` have no seed data and no CRUD endpoint anywhere in the repo — insert one of each by hand before testing anchor points or routes:

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

`backend-ai-training` has no HTTP server (it's an offline stub — see its own `CLAUDE.md`), so it's not in this list; verify it separately with `uv run pytest` / `uv run dev` inside that directory.

The app talks to all 5 services through a single **API gateway** (`gateway/nginx.conf`, path-prefix reverse proxy) rather than 5 separate ports — see it running via Docker Compose:

```bash
# fill in each service's .env first
for d in backend-data-collection backend-map-management backend-route-management backend-user-management backend-navigation-management; do
  (cd "$d" && cp .env.example .env)   # fill in SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY from step 1
done

docker compose up --build
```

This starts all 5 services (no longer individually host-exposed) plus the `gateway` service on port **8000**, which is what the app actually talks to:

| Gateway path prefix | Routes to |
|---|---|
| `/data-collection/*` | `backend-data-collection` |
| `/map/*` | `backend-map-management` |
| `/route/*` | `backend-route-management` |
| `/user/*` | `backend-user-management` |
| `/navigation/*` | `backend-navigation-management` |

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
3. **Capture two anchor points** from the admin screen (needs the `buildings` row from step 2 above) — take a photo, pick the building, submit. Do this twice; note their ids (`GET http://localhost:8000/map/anchor-points`, or the Supabase table editor).
4. **Create a route** referencing both anchor points — no in-app route-creation UI exists yet, so do it via curl, through the gateway:
   ```bash
   curl -X POST http://localhost:8000/route/routes \
     -H "Content-Type: application/json" \
     -d '{"building_id": "<building id>", "name": "Test route", "start_anchor_id": "<anchor 1 id>", "end_anchor_id": "<anchor 2 id>"}'
   ```
5. **Sign up a second, regular user** and log in as them.
6. Tap **Navigate**, start the route, and confirm `navigation_logs` rows accumulate in Supabase roughly every 5 seconds while the screen stays open.
7. Tap **End navigation** and optionally leave feedback — confirm the session's `status` becomes `completed` and (if entered) a `user_feedback` row appears.

Throughout this, `navigation_logs.corrected_lat`/`corrected_long`/`anchor_match_id`/`confidence_score` stay `NULL` — there's no visual-correction pipeline anywhere in the repo yet (see `backend-ai-training/CLAUDE.md`), so only raw GPS is ever logged.

---

## Current Development Status

- **Completed:** App with basic authentication and roles, Supabase connection, photo + metadata upload, structured Git repository, validated conceptual research, initial CI/CD setup (GitHub Actions).
- **In Progress:** Training pipeline implementation (PyTorch + OpenCV), Qdrant integration, automated tests.
- **Next:** Proof of concept with one campus building (50-100 anchor points) to validate accuracy improvement.

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
