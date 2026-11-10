// Takes the admin guide's screenshots from the real web app, against
// mock_server.py's made-up data. See README.md.
//
//   node take_screenshots.mjs [--lang es] [--only name[,name...]]
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = 'http://localhost:8765';
const arg = (name) => {
  const i = process.argv.indexOf(name);
  return i < 0 ? null : process.argv[i + 1];
};
const only = arg('--only');
// The new spot tapped in the shot of moving a point: just beside the point,
// which search centres in the Map section's map at this window size.
const SHEET_POINT = { x: 840, y: 630 };

/** One language's run: the page, its labels, and the helpers shots use. */
class Run {
  constructor(lang) {
    this.lang = lang;
    this.arb = JSON.parse(
      readFileSync(join(here, `../../../application/lib/l10n/app_${lang}.arb`)),
    );
    this.out = join(here, `../images/${lang}`);
    mkdirSync(this.out, { recursive: true });
  }

  /** A button's label in this language. */
  t(key, args = {}) {
    let text = this.arb[key];
    if (text === undefined) throw new Error(`no key ${key}`);
    for (const [name, value] of Object.entries(args)) {
      text = text.replace(`{${name}}`, value);
    }
    return text;
  }

  get back() {
    return this.lang === 'es' ? 'Atrás' : 'Back';
  }

  async open({ width = 1280, height = 1000 } = {}) {
    await fetch(`${SERVER}/__reset`, { method: 'POST' });
    await fetch(`${SERVER}/__language`, {
      method: 'POST',
      body: JSON.stringify({ language: this.lang }),
    });
    this.browser = await chromium.launch({
      args: ['--use-gl=swiftshader', '--enable-webgl', '--ignore-gpu-blocklist'],
    });
    const context = await this.browser.newContext({
      viewport: { width, height },
      locale: this.lang === 'es' ? 'es-CO' : 'en-US',
    });
    this.page = await context.newPage();
    this.page.on('pageerror', (e) =>
      console.log('page error:', e.message.slice(0, 200)),
    );
    await this.page.goto(`${SERVER}/admin/`);
    await this.page.waitForFunction(
      () => document.querySelector('flt-semantics-placeholder'),
      { timeout: 60000 },
    );
    await this.wait(1500);
    await this.accessibility();
  }

  async close() {
    await this.browser.close();
  }

  wait(ms) {
    return this.page.waitForTimeout(ms);
  }

  /** Flutter builds its accessibility tree, which is what's driven here. */
  async accessibility() {
    for (let tries = 0; tries < 20; tries++) {
      await this.page.evaluate(() =>
        document.querySelector('flt-semantics-placeholder')?.click(),
      );
      await this.wait(800);
      const ready = await this.page.evaluate(
        () => document.querySelectorAll('flt-semantics,input').length > 2,
      );
      if (ready) return;
    }
    throw new Error('the accessibility tree never appeared');
  }

  async signIn() {
    await this.page.locator('input').nth(0).fill('ana@demo.example');
    await this.page.locator('input').nth(1).fill('demo-demo');
    await this.click(this.t('loginButton'), 0, 3000);
    await this.accessibility();
  }

  /** The smallest control labeled [text], the nth of those top to bottom. */
  find(text, nth = 0, exact = false) {
    return this.page.evaluate(
      ([label, n, whole]) => {
        const visible = (e) => {
          const r = e.getBoundingClientRect();
          return r.width > 0 && r.height > 0 && r.x < innerWidth && r.y < innerHeight;
        };
        const named = [
          ...document.querySelectorAll('flt-semantics,input,textarea'),
        ]
          .filter(visible)
          .filter((e) => {
            const aria = e.getAttribute('aria-label') || '';
            const text = e.textContent.trim();
            return whole
              ? aria === label || text === label
              : aria.includes(label) || text.includes(label);
          });
        if (!named.length) return null;
        const area = (e) => {
          const r = e.getBoundingClientRect();
          return r.width * r.height;
        };
        const controls = named.filter(
          (e) => e.getAttribute('role') || e.tagName !== 'FLT-SEMANTICS',
        );
        const pool = controls.length ? controls : named;
        const least = Math.min(...pool.map(area));
        // A row clipped by the list's edge is smaller, but not the first.
        const e = pool
          .filter((c) => area(c) <= least * 2.5)
          .sort(
            (a, b) =>
              a.getBoundingClientRect().y - b.getBoundingClientRect().y ||
              a.getBoundingClientRect().x - b.getBoundingClientRect().x,
          )[n];
        if (!e) return null;
        const r = e.getBoundingClientRect();
        return { x: r.x, y: r.y, w: r.width, h: r.height };
      },
      [text, nth, exact],
    );
  }

  /** The button labeled [button] on the row labeled [row]. */
  async inRow(row, button) {
    const rowBox = await this.find(row);
    if (!rowBox) throw new Error(`no row ${row}`);
    for (let n = 0; n < 60; n++) {
      const box = await this.find(button, n);
      if (!box) break;
      if (box.y >= rowBox.y - 1 && box.y + box.h <= rowBox.y + rowBox.h + 1) {
        return box;
      }
    }
    throw new Error(`no ${button} on row ${row}`);
  }

  async clickBox(box, wait = 900) {
    await this.page.mouse.click(box.x + box.w / 2, box.y + box.h / 2);
    await this.wait(wait);
  }

  /** Waits for a map's tiles. */
  async mapLoaded() {
    await this.page.waitForLoadState('networkidle', { timeout: 20000 }).catch(() => {});
    await this.wait(3000);
  }

  async click(text, nth = 0, wait = 900, exact = false) {
    const box = await this.find(text, nth, exact);
    if (!box) throw new Error(`no control "${text}" (${nth})`);
    await this.clickBox(box, wait);
  }

  /** Types into a search box. */
  async search(_hint, text) {
    // The hint is its label only while it's empty; the tab has this one box.
    const box = await this.page.locator('input').first().boundingBox();
    await this.page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await this.wait(300);
    await this.page.keyboard.press('Control+A');
    if (text) await this.page.keyboard.type(text);
    else await this.page.keyboard.press('Delete');
    await this.wait(600);
  }

  async goBack() {
    // Rebuilding the tree can take a moment after a heavy page.
    for (let tries = 0; tries < 4; tries++) {
      const box = await this.find(this.back);
      if (box) return this.clickBox(box);
      await this.wait(500);
    }
    throw new Error('no back button');
  }

  /** Saves a screenshot, with numbered markers on [marks]: labels, [label,
   * nth] pairs, or boxes. */
  async shot(name, marks = []) {
    if (only && !only.split(',').includes(name)) return;
    await this.wait(600);
    const boxes = [];
    for (const mark of marks) {
      const box = mark.w
        ? mark
        : Array.isArray(mark)
          ? await this.find(mark[0], mark[1], mark[2])
          : await this.find(mark);
      if (!box) throw new Error(`${name}: nothing to mark for ${mark}`);
      boxes.push(box);
    }
    await this.page.evaluate((list) => {
      const layer = document.createElement('div');
      layer.id = 'guide-marks';
      layer.style = 'position:fixed;inset:0;z-index:99999;pointer-events:none';
      list.forEach((b, i) => {
        const outline = document.createElement('div');
        outline.style = `position:absolute;left:${b.x}px;top:${b.y}px;width:${b.w}px;height:${b.h}px;border:2px solid #d32f2f;border-radius:6px;box-sizing:border-box`;
        const dot = document.createElement('div');
        dot.textContent = i + 1;
        const left = Math.max(2, Math.min(innerWidth - 26, b.x - 12));
        const top = Math.max(2, Math.min(innerHeight - 26, b.y - 12));
        dot.style = `position:absolute;left:${left}px;top:${top}px;width:24px;height:24px;border-radius:50%;background:#d32f2f;color:#fff;font:bold 13px/24px sans-serif;text-align:center;box-shadow:0 1px 3px #0008`;
        layer.append(outline, dot);
      });
      document.body.append(layer);
    }, boxes);
    const png = join(this.out, `${name}.png`);
    await this.page.screenshot({ path: png });
    await this.page.evaluate(() =>
      document.getElementById('guide-marks')?.remove(),
    );
    console.log(this.lang, name);
  }
}

/** Every shot of the guide, in the order of its pages. */
async function allShots(r) {
  const t = (key, args) => r.t(key, args);

  await r.open();
  await r.shot('login', [
    t('loginEmailLabel'),
    t('loginPasswordLabel'),
    t('loginButton'),
    t('loginSignupPrompt'),
  ]);
  await r.signIn();

  // The menu and the top bar.
  await r.shot('home-menu', [
    t('adminGuide'),
    t('adminSectionMap'),
    t('adminSectionUniversities'),
    t('adminSectionBuildings'),
    t('adminSectionAnchorPoints'),
    t('adminSectionConnections'),
    t('adminUsersTabLabel'),
    t('adminSessions'),
    t('feedbackScreenTitle'),
    t('adminReindexMenu'),
    t('adminHealthUnconnected', { count: 1 }),
    t('adminHealthHiddenNamed', { count: 2 }),
    t('adminHealthLongConnections', { count: 1 }),
    t('adminHealthFloorChange', { count: 1 }),
    t('adminGuideSectionTooltip'),
    t('commonRefresh'),
    t('homeSettingsTooltip'),
    t('commonLogOut'),
  ]);

  // The map, where the app opens (C2): universities, then a building's
  // points, found by search.
  await r.mapLoaded();
  await r.shot('map-home', [
    t('adminMapSearchHint'),
    t('adminMapAll'),
    t('adminFabNewAnchorPoint'),
  ]);
  await r.search(t('adminMapSearchHint'), 'Universidad Demo');
  await r.click('Universidad Demo', 0, 1500);
  await r.mapLoaded();
  await r.shot('map-university', [
    t('adminMapAll'),
    t('adminMapOpenBuildingsList'),
    t('commonEdit'),
  ]);
  await r.search(t('adminMapSearchHint'), 'Sala');
  await r.shot('map-search', ['Sala de estudio']);
  await r.click('Sala de estudio', 0, 1500);
  await r.mapLoaded();
  await r.shot('map-point', [
    t('adminMapDetailsTooltip'),
    t('adminAnchorMoveAction'),
    [t('adminAnchorConnectAction'), 1],
  ]);

  // Universities.
  await r.click(t('adminSectionUniversities'), 0, 1500);
  await r.shot('universities', [
    t('adminSearchPlacesHint'),
    'Universidad Demo',
    t('commonEdit'),
    t('commonDelete'),
    t('adminFabAddUniversity'),
  ]);
  await r.click(t('adminFabAddUniversity'));
  await r.shot('university-form', [
    t('commonCode'),
    t('commonName'),
    t('commonAddress'),
    t('commonLatitude'),
    t('commonLongitude'),
    t('commonPickOnMap'),
    t('addPlaceSaveButton'),
  ]);
  await r.goBack();

  // Buildings.
  await r.click(t('adminSectionBuildings'));
  await r.shot('buildings', [
    t('commonUniversityLabel'),
    t('adminSearchBuildingsHint'),
    'Biblioteca',
    [t('commonEdit'), 0],
    [t('commonDelete'), 0],
    t('adminFabAddBuilding'),
  ]);
  await r.click(t('adminFabAddBuilding'));
  await r.shot('building-form', [
    t('commonUniversityLabel'),
    t('commonCode'),
    t('commonName'),
    t('commonAddress'),
    t('commonLatitude'),
    t('commonLongitude'),
    t('commonPickOnMap'),
    t('commonFloors'),
    t('commonHasElevator'),
    t('commonHasStairs'),
    t('addBuildingSaveButton'),
  ]);
  await r.goBack();

  // Anchor points: list, filters, row menu.
  await r.click(t('adminSectionAnchorPoints'));
  await r.shot('points-list', [
    t('commonUniversityLabel'),
    t('commonBuildingLabel'),
    t('adminSearchAnchorPointsHint'),
    'Archivo',
    t('adminAnchorVerifyTooltip'),
    [t('commonEdit'), 0],
    [t('adminMoreActionsTooltip'), 0],
    t('adminFiltersButton'),
    t('adminFabNewAnchorPoint'),
  ]);
  await r.click(t('adminFiltersButton'));
  await r.shot('points-filters');
  await r.page.keyboard.press('Escape');
  await r.wait(600);
  await r.click(t('adminMoreActionsTooltip'), 0);
  await r.shot('points-row-menu', [
    t('adminAddPhotoTooltip'),
    [t('commonDelete'), 0],
  ]);
  await r.page.keyboard.press('Escape');
  await r.wait(600);

  // Verifying a point with no connections.
  await r.search(t('adminSearchAnchorPointsHint'), 'Salón 102');
  await r.clickBox(await r.inRow('Salón 102', t('adminAnchorVerifyTooltip')));
  await r.shot('verify-needs-photo');
  await r.search(t('adminSearchAnchorPointsHint'), 'Salón 103');
  await r.clickBox(await r.inRow('Salón 103', t('adminAnchorVerifyTooltip')));
  await r.shot('verify-unconnected');
  await r.click(t('commonCancel'));
  await r.search(t('adminSearchAnchorPointsHint'), '');

  // New point form.
  await r.click(t('adminFabNewAnchorPoint'));
  await r.shot('point-form', [
    t('commonUniversityLabel'),
    t('commonBuildingLabel'),
    t('commonFloorLabel'),
    t('commonLocationTypeLabel'),
    t('commonDescriptionLabel'),
    t('captureIndoor'),
    t('captureOutdoor'),
    t('commonLightingLabel'),
    t('commonSurfaceLabel'),
    t('commonPickOnMap'),
    t('captureUseMyLocation', { meters: '?' }),
    t('captureSubmitButton'),
  ]);
  // The location picker, on the form's floor.
  await r.click(t('commonPickOnMap'), 0, 2000);
  await r.mapLoaded();
  await r.shot('location-picker', [
    t('locationPickerConfirmTooltip'),
    t('mapFloorUp'),
    t('mapFloorDown'),
    t('mapOnlyThisFloor'),
  ]);
  await r.goBack();
  await r.goBack();

  // Editing a point, its photos.
  await r.clickBox(await r.inRow('Baño mujeres', t('commonEdit')));
  await r.shot('point-edit', [
    t('commonDescriptionLabel'),
    t('commonFloorLabel'),
    t('commonLocationTypeLabel'),
    t('commonIndoorLocationLabel'),
    t('commonLightingLabel'),
    t('commonSurfaceLabel'),
    t('editAnchorManagePhotosButton', { count: 4 }),
    t('editAnchorStatusLabel'),
    t('editAnchorMoveOnMapButton'),
    t('commonSaveChanges'),
  ]);
  await r.click(t('editAnchorManagePhotosButton', { count: 4 }), 0, 1800);
  await r.shot('point-photos', [
    ['N', 0, true],
    t('capturePhotoWebUploadButton', { count: 4 }),
    t('capturePhotoDoneTooltip'),
  ]);
  await r.goBack();
  await r.goBack();

  // The points map: the Map section, still on the Biblioteca from the
  // search above (C3).
  await r.click(t('adminSectionMap'), 0, 1500);
  await r.mapLoaded();
  await r.shot('points-map', [
    t('mapFloorUp'),
    t('mapFloorDown'),
    t('mapOnlyThisFloor'),
    t('adminFabNewAnchorPoint'),
  ]);
  await r.shot('map-filters', [t('adminFiltersButton'), t('adminMapConnectChip')]);
  await r.click(t('mapFloorUp'), 0, 1500);
  await r.shot('points-map-floor2', [t('mapFloorUp'), t('mapFloorDown')]);
  await r.click(t('mapOnlyThisFloor'), 0, 1500);
  await r.shot('points-map-only-floor', [t('mapOnlyThisFloor')]);
  await r.click(t('mapOnlyThisFloor'), 0, 800);
  await r.click(t('mapFloorDown'), 0, 800);
  // A point's actions, found by search.
  await r.search(t('adminMapSearchHint'), 'Sala de estudio');
  await r.click('Sala de estudio', 0, 1500);
  await r.shot('point-sheet', [
    // The second: the first is the map's Connect chip, with the same label.
    [t('adminAnchorConnectAction'), 1],
    t('adminAnchorMoveAction'),
    t('adminAnchorUnverifyTooltip'),
    t('adminAddPhotoTooltip'),
    t('commonEdit'),
  ]);
  await r.click(t('adminAnchorMoveAction'), 0, 1000);
  await r.page.mouse.click(SHEET_POINT.x, SHEET_POINT.y);
  await r.wait(900);
  await r.shot('point-moving');
  await r.click(t('commonCancel'));

  // Tapping a point's row opens the map in Connect mode, with it selected.
  await r.click(t('adminSectionAnchorPoints'), 0, 1200);
  await r.search(t('adminSearchAnchorPointsHint'), 'Sala de estudio');
  await r.click('Sala de estudio', 0, 1500);
  await r.mapLoaded();
  await r.shot('connect-selected', [
    t('adminMapConnectChip'),
    t('adminMapConnectDone'),
    t('mapFloorUp'),
    t('mapFloorDown'),
    t('mapOnlyThisFloor'),
    t('adminGuideSectionTooltip'),
  ]);
  await r.click(t('adminMapConnectDone'));
  await r.click(t('adminSectionAnchorPoints'), 0, 1200);
  await r.search(t('adminSearchAnchorPointsHint'), '');

  // Connections.
  await r.click(t('adminSectionConnections'));
  await r.shot('connections', [
    t('commonUniversityLabel'),
    t('commonBuildingLabel'),
    t('adminSearchConnectionsHint'),
    t('adminAddConnectionFormTooltip'),
    'Tres escalones',
    [t('commonDelete'), 0],
    t('adminFiltersButton'),
    t('adminFabConnectOnMap'),
  ]);
  await r.click('Tres escalones', 0, 900);
  await r.shot('connection-warning');
  await r.click(t('commonCancel'));
  await r.click(t('adminAddConnectionFormTooltip'));
  await r.shot('connection-form', [
    t('commonUniversityLabel'),
    t('commonBuildingLabel'),
    t('addConnectionAnchorPointALabel'),
    t('addConnectionAnchorPointBLabel'),
    t('addConnectionDistanceLabel'),
    t('connectionWarningLabel'),
    t('addConnectionSaveButton'),
  ]);
  await r.goBack();
  // A connection on the map: its data and actions.
  await r.click(t('adminMapShowOnMap'), 0, 1800);
  await r.mapLoaded();
  await r.shot('map-connection', [
    t('adminConnectionEditWarning'),
    t('commonDelete'),
  ]);
  await r.click(t('adminSectionConnections'), 0, 1200);
  await r.click(t('adminFabConnectOnMap'), 0, 1500);
  await r.mapLoaded();
  await r.shot('connect-map');
  await r.click(t('adminMapConnectDone'));

  // Users.
  await r.click(t('adminUsersTabLabel'));
  await r.shot('users', [
    'Luis Usuario',
    [t('adminUsersPromote'), 0],
    [t('adminUserDeactivateTooltip'), 1],
    t('adminUserActivateTooltip'),
  ]);

  // Sessions.
  await r.click(t('adminSessions'), 0, 1200);
  await r.shot('sessions', ['Luis Usuario', 'Marta Ejemplo']);
  await r.click('Luis Usuario', 0, 1200);
  await r.shot('user-sessions', [
    [t('userSessionsWatchButton'), 0, true],
    t('userSessionsFeedbackTooltip'),
    t('commonDelete'),
  ]);
  await r.click(t('userSessionsWatchButton'), 0, 1500, true);
  await r.mapLoaded();
  await r.shot('session-tracking');
  await r.goBack();
  await r.goBack();
  await r.goBack();

  // Feedback, settings.
  await r.click(t('feedbackScreenTitle'), 0, 1200);
  await r.shot('feedback');
  await r.goBack();
  await r.click(t('homeSettingsTooltip'), 0, 1200);
  await r.shot('settings', [
    t('settingsVerbosityLabel'),
    t('settingsHighContrastLabel'),
    t('settingsLanguageLabel'),
    t('settingsSaveButton'),
  ]);
  await r.goBack();

  // The menu's notices.
  await r.click(t('adminHealthLongConnections', { count: 1 }));
  await r.shot('health-long-connections');
  await r.page.keyboard.press('Escape');
  await r.wait(700);
  await r.click(t('adminHealthFloorChange', { count: 1 }));
  await r.shot('health-floor-change');
  await r.page.keyboard.press('Escape');
  await r.wait(700);
  await r.click(t('adminHealthHiddenNamed', { count: 2 }));
  await r.shot('health-hidden-names');
  await r.page.keyboard.press('Escape');
  await r.wait(700);
  await r.click(t('adminReindexMenu'), 0, 2500);
  await r.shot('reindex');
  await r.close();

  // Phone width: the same app, the menu slides in.
  await r.open({ width: 412, height: 800 });
  await r.signIn();
  await r.click(t('adminSectionAnchorPoints')).catch(() => {});
  await r.shot('phone-home');
  await r.page.mouse.click(28, 28);
  await r.wait(900);
  await r.shot('phone-menu');
  await r.close();
}

for (const lang of arg('--lang') ? [arg('--lang')] : ['es', 'en']) {
  const r = new Run(lang);
  await allShots(r);
}
// WebP is about a tenth of the PNG's size.
execFileSync(
  'uv',
  ['run', '--with', 'pillow', 'python', join(here, 'to_webp.py'), join(here, '../images')],
  { stdio: 'inherit' },
);
