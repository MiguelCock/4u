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
