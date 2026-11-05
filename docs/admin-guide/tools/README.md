# Admin guide tools

The admin guide is written in `../es/README.md` and `../en/README.md`. These tools make its pictures and its web page, at `/admin/guide/` next to the admin web app.

**Changed only the text?** Run step 3.

**Changed a screen?** Run all of it, so the pictures match. The numbers in the pictures come from the marks in `take_screenshots.mjs`, and each one must match the table under its picture in both guides.

Run these from this folder:

```bash
# 1. Once: the browser that takes the pictures (node_modules isn't committed).
npm install && npx playwright install chromium

# 2. The pictures, from the real app against made-up data.
(cd ../../../application && flutter build web --release --base-href /admin/)
python3 mock_server.py ../../../application/build/web --port 8765 &   # stop it when done
node take_screenshots.mjs                 # or: --lang es, --only points-map

# 3. The web page, into application/web/guide/ (commit the result).
uv run --no-project --with markdown==3.11.2 python build_site.py
```

CI runs `build_site.py --check`, which fails if step 3 was forgotten.

Flutter's build cache doesn't notice new files in `web/`: after adding a picture, delete `application/.dart_tool/flutter_build` before a local `flutter build web`. CI and the release always build clean.

- **`mock_server.py`** serves the web build and answers sign-in and the backend paths with the fictional "Universidad Demo". It never reads a real key, URL or row, so nothing real can reach the pictures, which are public.
- **`take_screenshots.mjs`** drives the app through Flutter's accessibility tree, by each button's label in the app's own translations. A renamed button makes it stop and say which. `SHEET_POINT` is a fixed spot on the Anchor points map, where a demo point lands at that window size: if the map changes, check the `point-sheet` picture.
- Map backgrounds are real OpenStreetMap tiles, which is why the guide credits it. Each run asks for a few hundred.
- Taking photos with the camera and Test as user need a phone, so the guide describes them in text. Real phone pictures can go in `../images/<language>/`, linked from the Markdown like the others.
