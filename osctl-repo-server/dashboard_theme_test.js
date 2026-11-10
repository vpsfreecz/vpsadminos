// Run with Node's built-in VM; no browser, service or external package needed.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(`${__dirname}/dashboard.js`, "utf8");

function page(saved, blocked = false) {
  const dataset = {}, ready = [];
  const buttons = ["system", "light", "dark"].map(theme => ({dataset: {themeChoice: theme}, attrs: {},
    setAttribute(key, value) { this.attrs[key] = value; }, addEventListener(_, fn) { this.click = fn; }}));
  const control = {hidden: true, querySelectorAll: () => buttons};
  const storage = {value: saved, getItem() { if (blocked) throw Error("disabled"); return this.value; },
    setItem(_, value) { if (blocked) throw Error("disabled"); this.value = value; },
    removeItem() { if (blocked) throw Error("disabled"); this.value = null; }};
  const document = {documentElement: {dataset}, addEventListener(_, fn) { ready.push(fn); },
    querySelector: selector => selector === "[data-theme-control]" ? control : null};
  vm.runInNewContext(source, {window: {localStorage: storage}, document});
  ready.forEach(fn => fn());
  return {dataset, buttons, control, storage, choose(value) { buttons.find(b => b.dataset.themeChoice === value).click(); }};
}
for (const theme of ["light", "dark"]) {
  const p = page(theme);
  assert.equal(p.dataset.theme, theme);
  assert.equal(p.buttons.find(b => b.dataset.themeChoice === theme).attrs["aria-pressed"], "true");
  assert.equal(p.control.hidden, false);
  p.choose(theme === "dark" ? "light" : "dark");
  assert.equal(p.dataset.theme, p.storage.value);
  p.choose("system");
  assert.equal(p.dataset.theme, undefined);
  assert.equal(p.storage.value, null);
  assert.equal(p.buttons[0].attrs["aria-pressed"], "true");
}
for (const saved of [null, "invalid", "<script>bad</script>"]) {
  const p = page(saved);
  assert.equal(p.buttons[0].attrs["aria-pressed"], "true");
  assert.equal(p.dataset.theme, undefined);
}
const blocked = page("dark", true);
blocked.choose("dark"); assert.equal(blocked.dataset.theme, "dark");
blocked.choose("system"); assert.equal(blocked.dataset.theme, undefined);
console.log("Theme icon buttons: persisted overrides, System fallback, invalid/blocked storage and pressed labels PASS");

// Exercise the actual delegated usage handler with its response held while a
// catalog navigation completes. The response may update usage, never rewind
// the catalog URL selected after the request started.
async function usageNavigationOverlap(catalogSearch) {
  const ready = [], handlers = {};
  let address = new URL("https://repo.example/?catalog_distribution=old&period=7d#images"), resolveFetch, replaced = false;
  const location = {get href() { return address.href; }, get origin() { return address.origin; }, get protocol() { return address.protocol; }, get hash() { return address.hash; }};
  const history = {state: null, replaceState(state, _, raw) { this.state = state; address = new URL(raw, address); },
    pushState(state, _, raw) { this.state = state; address = new URL(raw, address); }};
  const element = () => ({isConnected: true, textContent: "", setAttribute() {}, remove() { this.isConnected = false; }, focus() {}, getAttribute() { return null; }});
  const heading = element();
  const incoming = {querySelectorAll: () => [], querySelector: () => heading};
  const panel = {classList: {add() {}}, setAttribute() {}, removeAttribute() {}, querySelector: () => null, prepend() {}, replaceWith() { replaced = true; }};
  const control = {href: "https://repo.example/?catalog_distribution=old&period=180d&distribution=alpine#usage", isConnected: false,
    getAttribute: () => "/?period=180d&distribution=alpine#usage", matches: selector => selector === "[data-usage-link]", closest: () => panel};
  const document = {documentElement: {dataset: {}}, activeElement: control,
    createElement: element, querySelector: selector => selector === "[data-catalog-tree]" ? {} : selector === "#usage" ? panel : null,
    addEventListener(name, fn) { if (name === "DOMContentLoaded") ready.push(fn); else handlers[name] = fn; }};
  const response = new Promise(resolve => { resolveFetch = resolve; });
  const sandbox = {document, location, history, URL, URLSearchParams, AbortController, scrollX: 0, scrollY: 180,
    window: {localStorage: {getItem: () => null}, addEventListener() {}, scrollTo() {}},
    fetch: () => response, DOMParser: class { parseFromString() { return {querySelector: () => incoming}; } }};
  vm.runInNewContext(source, sandbox);
  ready.forEach(fn => fn());
  handlers.click({button: 0, target: {closest: () => control}, preventDefault() {}});
  // This stands for a completed branch expansion or collapse, not a second
  // usage request: its catalog selection must survive the held response.
  history.pushState({}, "", `/?${catalogSearch}&period=7d#images`);
  resolveFetch({text: async () => "bounded usage HTML"});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(replaced, true, "held usage response should update its panel");
  const result = new URL(location.href);
  const expected = new URLSearchParams(catalogSearch);
  for (const key of ["catalog_distribution", "catalog_arch", "catalog_vendor", "catalog_variant"]) {
    assert.equal(result.searchParams.get(key), expected.get(key), `usage completion rewound ${key}`);
  }
  assert.equal(result.searchParams.get("period"), "180d");
  assert.equal(result.searchParams.get("distribution"), "alpine");
}
(async () => {
  await usageNavigationOverlap("catalog_distribution=debian&catalog_arch=x86_64&catalog_vendor=vpsadminos&catalog_variant=minimal");
  await usageNavigationOverlap("");
  console.log("Held usage completion preserves newer catalog expansion/collapse URL while applying usage fields PASS");
})().catch(error => { console.error(error); process.exitCode = 1; });
