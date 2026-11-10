// Run with Node's built-in VM; no browser, service or external package needed.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(`${__dirname}/dashboard.js`, "utf8");

function page(saved, blocked = false) {
  const dataset = {};
  const control = { hidden: true };
  let loaded, changed;
  const select = { value: "", addEventListener: (_, fn) => { changed = fn; } };
  const storage = { value: saved, getItem() { if (blocked) throw Error("disabled"); return this.value; },
    setItem(_, value) { if (blocked) throw Error("disabled"); this.value = value; },
    removeItem() { if (blocked) throw Error("disabled"); this.value = null; } };
  const document = { documentElement: { dataset }, addEventListener: (_, fn) => { loaded = fn; },
    querySelector: selector => selector === "#theme-choice" ? select : control };
  vm.runInNewContext(source, { window: { localStorage: storage }, document });
  loaded();
  return { dataset, select, control, storage, choose(value) { select.value = value; changed(); } };
}

for (const theme of ["light", "dark"]) {
  const p = page(theme);
  assert.equal(p.dataset.theme, theme);
  assert.equal(p.select.value, theme);
  assert.equal(p.control.hidden, false);
  p.choose(theme === "dark" ? "light" : "dark");
  assert.equal(p.dataset.theme, p.storage.value);
  p.choose("system");
  assert.equal(p.dataset.theme, undefined);
  assert.equal(p.storage.value, null);
}
for (const saved of [null, "invalid", "<script>bad</script>"]) {
  const p = page(saved);
  assert.equal(p.select.value, "system");
  assert.equal(p.dataset.theme, undefined);
}
const blocked = page("dark", true);
assert.equal(blocked.select.value, "system");
blocked.choose("dark");
assert.equal(blocked.dataset.theme, "dark");
blocked.choose("system");
assert.equal(blocked.dataset.theme, undefined);
const css = fs.readFileSync(`${__dirname}/dashboard.css`, "utf8");
assert.match(css, /prefers-color-scheme:dark/);
assert.match(css, /:root:not\(\[data-theme=light\]\)/);
assert.match(css, /prefers-reduced-motion:reduce/);
console.log("Theme preference: light/dark persistence, System OS fallback, invalid and blocked storage PASS");
