# Admin Guide

This guide is for administrators using the app to add and manage the data that powers the navigation system: places, buildings, anchor points, and the connections between them. It walks through what to do, in what order, and explains what every field on every screen actually means — not just whether it's required.

> This guide describes the app as it exists today. The app's own screens are in English only, so every field below shows its exact on-screen label.

## 1. Getting started

You reach the admin area automatically after logging in with an administrator account — there's no separate admin login, the app routes you to the admin view based on your account's role.

Navigation lives in a side drawer, opened with the hamburger icon (☰) in the top-left corner of the screen. The drawer header shows "Admin" and your signed-in email, and below that, four sections:

- **Places** (flag icon)
- **Buildings** (building icon)
- **Anchor points** (pin icon)
- **Connections** (line icon)

Tap a section to switch to it; the drawer closes automatically. The title at the top of the screen always tells you which section you're currently looking at. Two icons are always available in the top-right corner: a refresh icon (reloads everything from the server) and a logout icon (signs you out immediately, no confirmation).

## 2. Recommended order of work

The four sections aren't independent — each one builds on the last:

1. **Place** — the campus or site. Everything else belongs to one.
2. **Building** — one physical building within a place. You can't create a building until its place exists.
3. **Anchor point** — one specific physical spot inside (or right outside) a building. You can't create one until its building exists.
4. **Photos** — every anchor point needs at least one photo, ideally 4-8 taken facing different directions, before it's useful.
5. **Verification** — after reviewing an anchor point's photos, you set its status to Verified. This is the step that actually makes it usable by the app — see [5.3](#53-reviewing-and-verifying) for why.
6. **Connections** (optional) — once you have two or more verified anchor points, you can mark that people can walk directly between them.

If you try to skip ahead (e.g. add a building before its place exists), the corresponding dropdown will simply be empty, with a message telling you what to add first.

## 3. Places

A **place** is the top of the hierarchy — typically a whole campus or site. Every building belongs to exactly one place.

### Adding a place

1. From the drawer, go to **Places**.
2. Tap the **+** button (bottom-right).
3. Fill in the fields (see table below).
4. Tap **Save place**.

### Editing a place

Tap a place row's pencil (✏️) icon. Note: the **Code** field cannot be changed here — it's fixed once a place is created (see why in the field table).

### Deleting a place

Tap a place row's trash icon. You'll see exactly how many buildings, anchor points, photos, and connections will be deleted along with it, because deleting a place cascades all the way down — see [§7](#7-deleting-things).

### Place fields

| On-screen label | Required? | What it means | Example |
|---|---|---|---|
| **Code** | Required (only shown when adding — can't be changed afterward) | A short, unique identifier for the place, separate from its full name — think of it like an abbreviation or internal reference code. Because other data can end up referencing a place, changing it later isn't supported. | `CAMPUS` (for a place named "Main Campus") |
| **Name** | Required | The full, human-readable name of the place. This is what you'll see everywhere else in the app (dropdowns, lists). | `Main Campus` |
| **Address (optional)** | Optional | A street address, mostly for your own reference — not used anywhere else functionally. | `Cra 80 #65-223, Medellín` |
| **Latitude** / **Longitude** | Required | The GPS coordinates of the place's general center point, in decimal degrees. You can type these directly, or use **Pick on map** (a button below the fields) to tap the location on a map instead — useful when you don't know the exact coordinates off the top of your head. | `6.2442`, `-75.5812` |
| **Active** (edit only) | — | A toggle to mark a place as inactive without deleting it (and everything under it). Turn it off for a place that's no longer in use but whose history you want to keep. | — |

## 4. Buildings

A **building** is one physical building within a place.

### Adding a building

1. From the drawer, go to **Buildings**.
2. Tap **+**.
3. Choose the **Place** this building belongs to (if no places exist yet, you'll be told to add one first).
4. Fill in the rest of the fields.
5. Tap **Save building**.

### Editing a building

Tap the pencil icon on a building row. Like places, **Code** can't be changed after creation — and note that the **Place** field itself doesn't appear on the edit screen at all: moving a building to a different place isn't supported. If a building was assigned to the wrong place, delete and recreate it instead.

### Deleting a building

Same cascade-warning pattern as places — you'll see how many anchor points, photos, and connections go with it.

### Building fields

| On-screen label | Required? | What it means | Example |
|---|---|---|---|
| **Place** (add only) | Required | Which place this building belongs to. Filters the buildings list you'll see elsewhere in the app. | Main Campus |
| **Code** (add only) | Required | Same idea as a place's code — a short, unique, unchangeable identifier for this specific building. | `B1` |
| **Name** | Required | The building's full name, shown throughout the app. | `Main Building` |
| **Address (optional)** | Optional | Reference-only street address. | — |
| **Latitude** / **Longitude** | Required | This building's own GPS position — a separate point from its place's coordinates, since a building sits at a specific spot within the place. Type directly or use **Pick on map**. | `6.2445`, `-75.5810` |
| **Floors** | Defaults to `1` | How many floors the building has. Anchor points inside this building will later reference which floor they're on. | `3` |
| **Has elevator** (checkbox) | Defaults unchecked | Whether the building has an elevator. This is real accessibility information — the app's whole purpose is helping visually impaired users navigate, so knowing how someone actually gets between floors matters. | — |
| **Has stairs** (checkbox) | Defaults checked | Same idea, for stairs. | — |
| **Active** (edit only) | — | Same meaning as a place's Active toggle. | — |

## 5. Anchor points

An **anchor point** is a specific physical spot — a doorway, an intersection of hallways, an elevator lobby — that the app's visual-matching system learns to recognize from real photos. When a user's phone camera later sees something that matches one of these photos, the app uses it to correct that user's GPS position. In other words: an anchor point isn't just a pin on a map, it's a place the app has actually been taught to *see*.

### 5.1 Creating an anchor point

1. From the drawer, go to **Anchor points**.
2. Tap the camera **+** button (bottom-right) — labeled "New anchor point."
3. Choose the **Place**, then the **Building** (filtered to that place).
4. Choose the **Location type** — what kind of spot this is (see the full list in [§8](#8-quick-reference)). For example, if you're standing at a building's main door, choose **entrance**.
5. Fill in the **Description** — required, and important: this is the name you and other admins will see for this point everywhere in the app (search results, lists, dropdowns), so make it describe the actual spot rather than something generic. "Front door, north side" is far more useful later than "Point 1."
6. Set **Indoor location** (on by default) — whether this spot is inside a building or outside. This matters because GPS accuracy is much worse indoors, which is exactly why indoor anchor points matter most for the position-correction system.
7. Optionally set **Lighting** (Bright / Moderate / Dim) and **Surface** (free text, e.g. "tile", "carpet", "concrete", "grass") — see the field table below for why these are worth filling in.
8. Confirm the position — either your device's current GPS location (shown automatically) or, if you tap **Pick on map**, a location you tap on a map instead. A manual pick always overrides GPS. Use this when GPS drift (common near tall buildings) would otherwise place the point in the wrong spot.
9. Tap **Create and add photos** — this saves the anchor point and takes you straight into the photo-capture screen ([§5.2](#52-taking-photos)).

#### Anchor point fields (creation and editing)

| On-screen label | Required? | What it means | Example |
|---|---|---|---|
| **Place** / **Building** | Both required | Which building this point belongs to (the place dropdown just filters the building list). | — |
| **Location type** | Required, defaults to "entrance" | What kind of spot this is. Full option list and meanings in [§8](#8-quick-reference). | `entrance` |
| **Description** | Required | The point's human-readable name — shown everywhere. Describe the spot, not a generic label. | `Front door, north side` |
| **Indoor location** (switch) | Defaults on | Inside vs. outside — see above for why it matters. | — |
| **Lighting** (dropdown) | Optional, defaults "Not set" | Typical lighting at this exact spot: Bright / Moderate / Dim. Useful context for whoever reviews the photos later (a dark photo might just mean a dim hallway, not a bad photo), and this data is meant to help the visual-matching system handle different lighting conditions more reliably over time. | A spot by a large window at midday → `Bright`; an interior stairwell with only ceiling lights → `Dim` |
| **Surface (optional)** | Optional, free text | The physical floor/ground surface. Can serve as a useful orientation cue (e.g. a change from tile to carpet marking a room boundary). | `tile`, `carpet`, `concrete`, `grass` |
| **Location** | Required (GPS or map pick) | The point's actual coordinates. A map pick always takes priority over the device's live GPS reading. | — |

### 5.2 Taking photos

Why multiple photos: a user could approach the same physical spot from any direction, so the app needs to recognize what it looks like from each side — not just one angle.

1. On the photo screen, you'll see a live camera preview. A small badge in the top-right corner shows **"Facing: N°"** — your device's live compass heading (not GPS direction), updating in real time. This is recorded automatically with each photo, so the app knows which direction that photo faces.
2. Tap **Take photo** to capture one. It uploads automatically and appears in a thumbnail grid below, with the heading it was taken at shown in the corner of each thumbnail.
3. Repeat facing different directions — as a guideline, aim for 4-8 photos, roughly facing north/south/east/west from the same spot (adjust based on the actual space — a corner spot might only have two or three sensible directions to photograph). The app does not enforce a minimum, so this is on you to get right.
4. Made a mistake? Tap the trash icon on a thumbnail to delete that photo (with a confirmation prompt).
5. When you're done, tap the checkmark (✓) in the top-right of the screen — labeled "Done."

You can always come back to add or remove photos later from an anchor point's **Manage photos** button (see below).

### 5.3 Reviewing and verifying

The edit screen for an anchor point is also where you review it and decide whether it's ready for real use. This is more than just changing a label:

- **Status: Verified** — saving with this status automatically indexes the point's photos into the app's search system, making it real, live data that the app can actually match a user's camera against. This is the step that makes an anchor point *do* anything.
- **Status: Pending** or **Rejected** — saving with either of these removes the point from that search index (if it was there), so a downgraded or rejected point stops being usable by the live app, without deleting the point itself.

So before setting a point to Verified, actually look at its photos first (a read-only thumbnail strip is shown on this screen) — are they clear, correctly oriented, actually showing the right spot? Use **Manage photos** to fix anything before verifying.

To edit an anchor point: tap the pencil icon on its row. You'll see the same fields as creation (all editable), plus:

| On-screen label | What it means |
|---|---|
| **Status** (dropdown: pending / verified / rejected) | See above — this is the real switch that turns a captured point into usable navigation data, or takes it back out. |
| Photo thumbnail strip (read-only) | A quick visual check before you decide on status. |
| **Manage photos** button | Opens the same photo screen from [§5.2](#52-taking-photos) to add or delete photos. |
| **Move on map** button | Lets you re-pick the point's position on a map, e.g. if it turns out to be in the wrong spot. |

## 6. Connections

A **connection** records that a person can walk directly between two anchor points — it's building up a walkability graph, not just an arbitrary link between two pins. This is meant to eventually support step-by-step route guidance.

There are two ways to create one — pick whichever fits the situation:

### Tap-to-connect on a map

Faster, and works especially well for connecting a whole sequence of points along a corridor:

1. From the drawer, go to **Connections**, then tap the **+** button — labeled "Connect on map."
2. Choose a **Place**, and optionally a **Building** to narrow the map down further.
3. Tap an anchor point on the map to select it.
4. Tap a second anchor point — this creates the connection between them, and the second point **stays selected**, so you can immediately tap a third point to keep chaining connections along the same corridor without starting over each time.
5. Existing connections between visible points are drawn as green lines on the map, so you can see at a glance what's already linked.

### Dropdown form

More precise — use this when you're not looking at a map, or you need to correct the automatically estimated distance:

1. From the Connections screen, tap the list icon in the top-right — labeled "Add connection (form)."
2. Choose **Place**, optionally a **Building** filter, then **Anchor point A** and **Anchor point B** from dropdowns.
3. Optionally fill in **Distance** and **Notes** (see table).
4. Tap **Save connection**.

### Connection fields (form)

| On-screen label | Required? | What it means | Example |
|---|---|---|---|
| **Place** / **Building (optional filter)** | Place required, Building optional | Narrows down which anchor points appear in the dropdowns below. | — |
| **Anchor point A** / **Anchor point B** | Both required, must be different points | The two anchor points being connected. | — |
| **Distance in meters (optional)** | Optional | How far someone would actually walk between the two points. If you leave this blank, the app estimates it as a straight line between their coordinates — which is wrong if the real path bends (around a corner, say) or isn't a straight walk (via an elevator or stairs instead of a direct route). Fill this in whenever the straight-line guess wouldn't be accurate. | `12.5` |
| **Notes (optional)** | Optional | Free text for anything worth flagging about this specific link. | `via elevator, not stairs`, `blocked during exam periods` |

Deleting a connection (trash icon, no edit option — delete and recreate if you need to change it) has no cascade — it doesn't affect the two anchor points themselves.

## 7. Deleting things

Deleting a place, building, or anchor point always shows a confirmation dialog stating exactly what else will be deleted with it, because the data is hierarchical (place → building → anchor point → photos/connections):

- **Deleting a place** also deletes its buildings, their anchor points, those points' photos, and any connections involving them.
- **Deleting a building** also deletes its anchor points, their photos, and any connections involving them.
- **Deleting an anchor point** also deletes its photos and any connections involving it.
- **Deleting a connection** affects nothing else.

The confirmation always shows the real counts (e.g. "will also delete 3 buildings, 12 anchor points, 45 photos, and 8 connections") before you confirm — read it. None of this can be undone.

## 8. Quick reference

### Location types

| Option shown in the app | Meaning |
|---|---|
| entrance | Building entrance or main door |
| intersection | Hallway intersection |
| elevator | Elevator area |
| stairwell | Staircase area |
| classroom | Classroom location |
| office | Office location |
| restroom | Restroom location |
| cafeteria | Cafeteria or dining area |
| hallway | A hallway or corridor segment — not an intersection, just a stretch of hallway (useful as a waypoint between two intersections) |
| ramp | An accessibility ramp |
| outdoor_path | An outdoor walkway or path between buildings |
| parking | A parking area or lot |
| lobby | A building lobby or atrium |
| auditorium | An auditorium or large lecture hall |
| courtyard | An outdoor courtyard or plaza |
| crosswalk | A pedestrian crosswalk or road crossing |
| bus_stop | A campus bus or shuttle stop |
| other | Anything that doesn't fit the above |

### Anchor point status

| Status | Meaning |
|---|---|
| **pending** | Captured, not yet reviewed — not usable by the live app yet |
| **verified** | Reviewed and confirmed good — indexed into the search system, usable by the live app |
| **rejected** | Reviewed and rejected (bad photos, wrong location, duplicate, etc.) — excluded from the search system |

### Lighting

| Option | Meaning |
|---|---|
| Not set | No lighting info recorded |
| Bright | Well-lit, e.g. daylight through windows |
| Moderate | Normal indoor lighting |
| Dim | Poorly lit, e.g. an interior stairwell |
