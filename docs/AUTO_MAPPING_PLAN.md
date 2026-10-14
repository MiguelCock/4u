# Automatic anchor-point mapping via Google Maps + AI (plan, not implemented)

## Problem

Every anchor point today is captured by hand: an admin walks to the exact spot, takes 4-8 photos facing different directions, and records coordinates (`capture_screen.dart`/`capture_photo_screen.dart`). This doesn't scale past one or two buildings without a lot of admin time, and it's the main bottleneck on getting enough real anchor-point density to validate the correction pipeline (issue #26).

## What Google's data can and can't actually give us

This is the part worth getting right before investing in it: **Google's imagery is outdoor/building-exterior only.** Street View Static API and the Places API have no visibility into hallways, elevators, classrooms, or any other indoor space - which is most of this app's anchor-point inventory (`location_type.sql`'s seeded types are overwhelmingly indoor: `classroom`, `office`, `restroom`, `hallway`, `elevator`, `stairwell`, `lobby`, `auditorium`; only `entrance`, `outdoor_path`, `crosswalk`, `bus_stop`, `parking`, `courtyard` are reachable this way).

So the realistic scope is: **auto-seed outdoor anchor points only** (building entrances, campus pathway intersections, outdoor landmarks) - cutting manual work roughly in half for a typical campus, not eliminating it. Indoor capture still needs a human with a phone, same as today.

## Candidate approach

1. **Candidate discovery**: Google Places API (`findPlaceFromText`/Nearby Search) to enumerate real-world points of interest around the campus's known lat/lng bounding box - building names, entrances if tagged, path intersections aren't really "places" so these would likely need to come from a different source (e.g. manually drawn, or OpenStreetMap's footpath data, which unlike Street View is free and already has indoor-vs-outdoor-agnostic path geometry for many campuses).
2. **Reference imagery**: Street View Static API, querying the nearest available panorama to each candidate coordinate, cropped/headed toward the point of interest. This becomes the equivalent of one of the 4-8 admin-captured photos - likely only one angle, not four, so day-one coverage per auto-seeded point would be worse than a manually captured one.
3. **Feed into the existing pipeline unchanged**: the candidate's coordinates + the Street View image go through the exact same `POST /index_anchor` shape the app already posts after a manual capture - this plan doesn't propose a parallel pipeline, just a different *source* for the same inputs. Results land in the existing `pending` status, same admin verification queue (`edit_anchor_point_screen.dart`) every manually-captured point already goes through - a human still signs off before anything becomes searchable, same as today.

## Open questions, not resolved by this plan

- **Coverage gaps**: Street View simply doesn't cover every campus, or may be years out of date (a renovated entrance, a demolished building). Needs a per-campus coverage check before this is worth building at all.
- **Image mismatch**: a Street View panorama was shot by a car-mounted camera from the street, months or years ago, in whatever weather/lighting that day had. A user's phone photo during actual navigation is a completely different angle, height, and lighting. The embedding model may simply not find these similar enough to be useful matches - this needs a real accuracy test against a few campus buildings before committing engineering time, not just an assumption that "a photo of the building is a photo of the building."
- **Licensing**: Google Maps Platform's terms restrict how Street View imagery can be stored/cached/reprocessed server-side (this isn't a "download and keep forever" API by default) - needs a real read of the current ToS before any image gets persisted into Supabase Storage/Qdrant the way a manually-captured photo is today.
- **Cost**: Places + Street View Static are metered, billed APIs - fine for a one-time per-campus seeding pass, not something to call repeatedly or per-request.

## Recommendation

Worth a small, throwaway spike (one campus, a handful of outdoor points, no production code) to answer the image-mismatch and coverage questions before any real implementation - those two answers determine whether this is worth building at all, more than any amount of upfront design would.
