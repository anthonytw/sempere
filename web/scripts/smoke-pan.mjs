// Browser smoke test of sideways panning (docs/web-viewer.md "Reading"), not part of
// `npm test`: serves dist/ and a vault on one origin and drives the viewer in Chromium
// with Playwright, top level and inside an iframe (the website's demo), with the wheel
// and with touch (CDP touch events). Checks:
//   - a note that fits the viewport's width (fit width, and zoomed out below it) never
//     moves sideways, and nothing scrolls sideways;
//   - zoomed in wider than the viewport, the wheel and a touch drag pan sideways.
// Usage: node scripts/smoke-pan.mjs VAULT_DIR KEY_FILE
import { readFileSync } from "node:fs";
import { launchChromium, serveVault } from "./smoke-lib.mjs";

const [vaultDir, keyFile] = process.argv.slice(2);
const { base, close } = await serveVault({
  mounts: [{ prefix: "/static/", vaultDir }],
  extraRoutes: (path, send) => path === "/frame.html"
    && (send(200, `<!doctype html><body style="margin:0"><iframe id="f" src="/" style="border:0;width:100%;height:100vh"></iframe>`, "text/html"), true),
});
const key = readFileSync(keyFile, "utf8");

let failures = 0;
const check = (ok, what) => { console.log(ok ? "ok  " : "FAIL", what); if (!ok) failures++; };

const browser = await launchChromium();
for (const framed of [false, true]) {
  for (const width of [1000, 700]) {
    const ctx = await browser.newContext({ viewport: { width, height: 800 }, hasTouch: true });
    const page = await ctx.newPage();
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(`${base}${framed ? "/frame.html" : "/"}`);
    const app = framed ? page.frameLocator("#f") : page;
    const frame = framed ? page.frames().find((f) => f !== page.mainFrame()) : page.mainFrame();
    await app.locator("input[type=url]").fill(`${base}/static/`);
    await app.locator("form button[type=submit]").click();
    await app.locator("textarea").fill(key);
    await app.locator("form:has(textarea) button[type=submit]").click();
    await app.locator(".note-list button.note").first().click();
    await app.locator(".page svg").first().waitFor({ timeout: 30000 });
    const label = `${framed ? "iframe" : "top"} ${width}px`;

    const state = () => frame.evaluate(() => {
      const vp = document.querySelector(".viewport");
      const m = new DOMMatrix(getComputedStyle(document.querySelector(".pages")).transform);
      const de = document.documentElement;
      return { x: m.m41, z: m.a, vw: vp.clientWidth, w: document.querySelector(".pages").offsetWidth * m.a,
        scroll: [vp.scrollWidth <= vp.clientWidth, de.scrollWidth <= de.clientWidth, vp.scrollLeft, de.scrollLeft, document.body.scrollLeft] };
    });
    const centre = await frame.evaluate(() => { const r = document.querySelector(".viewport").getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; });
    const cdp = await ctx.newCDPSession(page);
    // Touch positions are in the top-level page's coordinates; an iframe at the origin shares them.
    const drag = async (dx, dy) => {
      const pts = (k) => [{ x: centre.x + (dx * k) / 10, y: centre.y + (dy * k) / 10, id: 1 }];
      await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: pts(0) });
      for (let k = 1; k <= 10; k++) await cdp.send("Input.dispatchTouchEvent", { type: "touchMove", touchPoints: pts(k) });
      await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
      await page.waitForTimeout(100);
    };
    const wheel = async (dx, dy) => { await page.mouse.move(centre.x, centre.y); await page.mouse.wheel(dx, dy); await page.waitForTimeout(100); };

    // Fit width: the page is narrower than the viewport.
    await frame.evaluate(() => document.querySelector(".viewport").focus());
    await page.keyboard.press("0");
    await page.waitForTimeout(100);
    const fit = await state();
    check(fit.w <= fit.vw, `${label}: fit width fits (${fit.w.toFixed(0)} <= ${fit.vw})`);
    await wheel(300, 200); await wheel(-300, 50); await drag(-200, -100); await drag(200, 30);
    for (let i = 0; i < 6; i++) await page.keyboard.press(i % 2 ? "ArrowLeft" : "ArrowRight");
    const after = await state();
    check(Math.abs(after.x - fit.x) < 0.5, `${label}: fit width stays centred (x ${fit.x.toFixed(1)} -> ${after.x.toFixed(1)})`);
    check(after.scroll[0] && after.scroll[1] && after.scroll.slice(2).every((v) => v === 0), `${label}: nothing scrolls sideways`);

    // Zoomed out below fit width: still centred, whatever the gesture.
    for (let i = 0; i < 2; i++) await page.keyboard.press("-");
    await page.waitForTimeout(100);
    const small = await state();
    check(small.w < fit.w && Math.abs(small.x - (small.vw - small.w) / 2) < 0.5, `${label}: zoomed out is centred (x ${small.x.toFixed(1)})`);
    await wheel(300, 0); await drag(-200, 0); await page.keyboard.press("ArrowRight");
    const smallAfter = await state();
    check(Math.abs(smallAfter.x - small.x) < 0.5, `${label}: zoomed out stays centred (x ${small.x.toFixed(1)} -> ${smallAfter.x.toFixed(1)})`);

    // Zoomed in: wider than the viewport.
    await page.keyboard.press("0");
    for (let i = 0; i < 4; i++) await page.keyboard.press("+");
    await page.waitForTimeout(100);
    const zoomed = await state();
    check(zoomed.w > zoomed.vw, `${label}: zoomed note is wider than the viewport (${zoomed.w.toFixed(0)} > ${zoomed.vw})`);
    await wheel(120, 0);
    const byWheel = await state();
    check(byWheel.x < zoomed.x - 50, `${label}: wheel pans a zoomed note (x ${zoomed.x.toFixed(1)} -> ${byWheel.x.toFixed(1)})`);
    await drag(80, 0);
    const byTouch = await state();
    check(byTouch.x > byWheel.x + 50, `${label}: touch drag pans a zoomed note (x ${byWheel.x.toFixed(1)} -> ${byTouch.x.toFixed(1)})`);
    check(errors.length === 0, `${label}: no page errors ${JSON.stringify(errors)}`);
    await ctx.close();
  }
}
await browser.close();
close();
process.exit(failures ? 1 : 0);
