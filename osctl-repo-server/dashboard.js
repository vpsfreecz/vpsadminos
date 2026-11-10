(() => {
  "use strict";
  const key = "osctl-repo-theme";
  const valid = value => ["system", "light", "dark"].includes(value);
  let choice = "system";
  try {
    const saved = window.localStorage.getItem(key);
    if (valid(saved)) choice = saved;
  } catch (_) { /* A disabled storage area must not disable the controls. */ }
  const apply = value => {
    choice = valid(value) ? value : "system";
    if (choice === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = choice;
  };
  apply(choice);
  document.addEventListener("DOMContentLoaded", () => {
    const control = document.querySelector("[data-theme-control]");
    if (!control) return;
    const buttons = control.querySelectorAll("[data-theme-choice]");
    const selected = () => buttons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.themeChoice === choice)));
    selected(); control.hidden = false;
    buttons.forEach(button => button.addEventListener("click", () => {
      apply(button.dataset.themeChoice); selected();
      try {
        if (choice === "system") window.localStorage.removeItem(key);
        else window.localStorage.setItem(key, choice);
      } catch (_) { /* The selected theme still applies for this page. */ }
    }));
  });
})();

(() => {
  "use strict";
  document.addEventListener("DOMContentLoaded", () => {
    if (typeof location !== "undefined" && location.pathname === "/" && ["#usage", "#images", "#status"].includes(location.hash)) {
      location.replace("/" + location.hash.slice(1) + location.search); return;
    }
    document.addEventListener("keydown", event => {
      if (event.key === "Escape") document.querySelectorAll(".history-warning").forEach(item => { if (item.open || item.matches(":hover, :focus-within")) { item.open = false; item.querySelector("summary")?.focus(); item.classList.add("dismissed"); } });
    });
    document.addEventListener("click", event => { event.target.closest(".history-warning")?.classList.remove("dismissed"); });
    document.addEventListener("focusin", event => { event.target.closest(".history-warning")?.classList.remove("dismissed"); });
    const images = document.querySelector("[data-catalog-tree]");
    const usage = document.querySelector("#usage");
    if (!images && !usage) return;
    const pending = new Map();
    let usageRequest, navigationRequest, usageSerial = 0;
    const catalogKeys = ["catalog_distribution", "catalog_arch", "catalog_vendor", "catalog_variant", "catalog_cursor"];
    const usageKeys = ["distribution", "arch", "vendor", "variant", "version", "usage_cursor"];
    const node = (tag, text, attributes = {}) => {
      const out = document.createElement(tag);
      if (text !== null) out.textContent = text;
      for (const [key, value] of Object.entries(attributes)) out.setAttribute(key, value);
      return out;
    };
    const bytes = value => {
      let amount = Number(value), index = 0; const units = ["B", "KiB", "MiB", "GiB", "TiB"];
      while (amount >= 1024 && index < units.length - 1) { amount /= 1024; index++; }
      return (index ? amount.toFixed(1).replace(/\.0$/, "") : String(amount)) + " " + units[index];
    };
    const modified = value => {
      if (!value || !Number.isFinite(Date.parse(value))) return node("span", "—", {"aria-label": "Last modified unknown"});
      const date = new Date(value); return node("time", date.toISOString().replace("T", " ").replace(/\.\d{3}Z$/, " UTC"), {datetime: date.toISOString()});
    };
    const currentURL = raw => {
      const out = new URL(raw, location.href);
      if (out.origin !== location.origin || out.protocol !== location.protocol) throw Error("origin");
      return out;
    };
    const remember = control => history.replaceState({dashboard: true, x: scrollX, y: scrollY, focus: (control || document.activeElement)?.getAttribute("href") || null}, "", location.href);
    const catalogURL = raw => {
      const requested = currentURL(raw), url = new URL(location.href);
      catalogKeys.forEach(key => url.searchParams.delete(key));
      catalogKeys.forEach(key => { if (requested.searchParams.has(key)) url.searchParams.set(key, requested.searchParams.get(key)); });
      url.pathname = "/images"; url.hash = ""; return url;
    };
    const navigate = (raw, focus, savePrevious = true) => {
      const url = currentURL(raw); if (savePrevious) remember();
      history.pushState({dashboard: true, x: scrollX, y: scrollY, focus: focus || null}, "", url.pathname + url.search + url.hash);
    };
    const stableFocus = (control, x, y) => {
      if (control && control.isConnected) control.focus({preventScroll: true});
      window.scrollTo(x, y);
      if (history.state?.dashboard) history.replaceState({...history.state,x,y,focus:control?.getAttribute("href") || history.state.focus},"",location.href);
    };
    const listOf = parent => Array.from(parent.children).find(child => child.tagName === "UL");
    const pageURL = query => {
      const url = new URL(location.href); catalogKeys.forEach(key => url.searchParams.delete(key));
      for (const key of ["distribution", "arch", "vendor", "variant", "cursor"]) {
        if (query.get(key)) url.searchParams.set(`catalog_${key}`, query.get(key));
      }
      url.pathname = "/images"; url.hash = ""; return url;
    };
    const usageURL = tuple => {
      const url = new URL(location.href); usageKeys.forEach(key => url.searchParams.delete(key));
      for (const key of ["distribution", "arch", "vendor", "variant", "version"]) if (tuple[key]) url.searchParams.set(key, tuple[key]);
      url.pathname = "/usage"; url.hash = ""; return url;
    };
    const branchRow = (row, group, parentQuery) => {
      const li = node("li", null, {"data-catalog-node": ""});
      const line = node("div", null, {class: "tree-link"});
      const name = node("span", null, {class: "tree-name"});
      const actions = node("span", null, {class: "tree-actions"});
      const query = new URLSearchParams(parentQuery); query.delete("cursor");
      let label = row.version || "", next = "";
      if (group === "distribution") { label = row.distribution; query.set("distribution", row.distribution); next = "arch"; }
      if (group === "arch") { label = row.arch; query.set("arch", row.arch); next = "variant"; }
      if (group === "variant") { label = `${row.vendor} / ${row.variant}`; query.set("vendor", row.vendor); query.set("variant", row.variant); next = "version"; }
      if (next) {
        query.set("group_by", next);
        const link = node("a", label, {class: "tree-toggle", href: pageURL(query).href, "data-catalog-toggle": "", "data-query": query.toString(), "data-parent-url": pageURL(new URLSearchParams(parentQuery)).href, "aria-expanded": "false"});
        const icon = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        icon.setAttribute("class", "icon branch-icon"); icon.setAttribute("viewBox", "0 0 24 24"); icon.setAttribute("aria-hidden", "true");
        const path = document.createElementNS("http://www.w3.org/2000/svg", "path"); path.setAttribute("d", "m9 5 7 7-7 7"); icon.append(path); link.prepend(icon);
        name.append(link);
      } else {
        name.append(node("span", label));
        for (const tag of row.tags || []) name.append(node("span", tag, {class: `tag ${["latest", "stable"].includes(tag) ? "important" : ""}`}));
      }
      if (row.image_versions) actions.append(node("span", String(row.image_versions), {class: "tree-meta"}));
      actions.append(node("a", "Usage", {class: "tree-usage", href: usageURL(row).href, "data-usage-link": ""}));
      const metadata = node("span", null, {class: "listing-metadata"});
      const size = node("span", bytes(row.bytes), {title: `${row.bytes} bytes`});
      metadata.append(size, modified(row.last_modified)); actions.append(metadata);
      line.append(name, actions); li.append(line);
      if (Array.isArray(row.downloads) && row.downloads.length) {
        const details = node("details", null, {class: "leaf-files"}), files = node("ul", null, {class: "file-list"});
        details.append(node("summary", "Files"));
        for (const file of row.downloads) {
          const url = currentURL(file.url);
          if (!url.pathname.startsWith("/v1/")) continue;
          const item = node("li", null); item.append(node("a", file.format, {href: url.href}), " ", node("span", bytes(file.bytes), {title: `${file.bytes} bytes`}), " ", modified(file.last_modified)); files.append(item);
        }
        details.append(files); li.append(details);
      }
      return li;
    };
    const branchMessage = (list, text, retry) => {
      const li = node("li", null, {class: "branch-message", role: "status"});
      li.append(node("span", text));
      if (retry) li.append(" ", retry);
      list.append(li); return li;
    };
    const loadBranch = async (control, more = false) => {
      const holder = more ? control.closest("ul") : control.closest("li[data-catalog-node]");
      if (!holder) return;
      const x = scrollX, y = scrollY;
      const requestedURL = control.href;
      let list = more ? holder : listOf(holder);
      if (!list) { list = node("ul", null, {class: "tree"}); holder.append(list); }
      pending.get(holder)?.abort();
      const request = new AbortController(); pending.set(holder, request);
      holder.setAttribute("aria-busy", "true");
      if (!more) control.setAttribute("aria-expanded", "true");
      const loading = branchMessage(list, "Loading…");
      try {
        const query = new URLSearchParams(control.dataset.query); query.set("limit", "50");
        const api = new URL("/dashboard/api/catalog", location.href); api.search = query.toString();
        const response = await fetch(api, {signal: request.signal, credentials: "same-origin"});
        if (!response.ok) throw Object.assign(Error("catalog"), {status: response.status});
        const page = await response.json();
        if (request.signal.aborted || !holder.isConnected) return;
        if (!Array.isArray(page.rows) || page.rows.length > 100 || page.group_by !== query.get("group_by")) throw Error("page");
        loading.remove();
        const before = more ? control.closest("li") : null;
        const rows = page.rows.map(row => branchRow(row, page.group_by, query));
        rows.forEach(row => list.insertBefore(row, before));
        if (!rows.length && !more) branchMessage(list, "No image versions in this group.");
        if (page.next_cursor) {
          query.set("cursor", page.next_cursor);
          const link = more ? control : node("a", "More", {"data-catalog-more": ""});
          link.textContent = "More";
          link.href = pageURL(query).href; link.dataset.query = query.toString();
          if (!more) { const item = node("li", null, {class: "branch-more"}); item.append(link); list.append(item); }
          else { const item=link.closest("li");item.replaceChildren(link);item.className="branch-more";item.removeAttribute("role"); }
        } else if (more) {
          control.closest("li").remove();
          stableFocus(rows[0]?.querySelector("a") || holder.closest("li")?.querySelector("a"), x, y);
        }
        navigate(catalogURL(requestedURL), control.href);
        stableFocus(control, x, y);
      } catch (error) {
        if (request.signal.aborted || !holder.isConnected) return;
        loading.remove();
        const retryQuery = new URLSearchParams(control.dataset.query);
        if (error.status === 409) retryQuery.delete("cursor");
        const retry = node("a", "Refresh this branch", {href: pageURL(retryQuery).href, "data-catalog-more": "", "data-query": retryQuery.toString()});
        // A replaced snapshot cannot be mixed with previously loaded children.
        if (error.status === 409) list.replaceChildren();
        else if (more) control.closest("li").remove();
        branchMessage(list, error.status === 409 ? "The catalog changed." : "This branch could not be loaded.", retry);
        stableFocus(control.isConnected ? control : retry, x, y);
      } finally {
        if (pending.get(holder) === request) { pending.delete(holder); holder.removeAttribute("aria-busy"); }
      }
    };
    const restorePanels = async () => {
      navigationRequest?.abort(); usageRequest?.abort(); usageSerial++;
      pending.forEach(request => request.abort()); pending.clear();
      const request = new AbortController(); navigationRequest = request;
      try {
        const response = await fetch(location.href, {signal: request.signal, credentials: "same-origin"});
        const html = new DOMParser().parseFromString(await response.text(), "text/html");
        if (request.signal.aborted) return;
        for (const id of ["images", "usage"]) {
          const incoming = html.querySelector(`#${id}`), current = document.querySelector(`#${id}`);
          if (incoming && current) current.replaceWith(incoming);
        }
        {
          const focus = Array.from(document.querySelectorAll("a")).find(link => link.href === history.state?.focus);
          focus?.focus({preventScroll: true});
          window.scrollTo(history.state?.x || 0, history.state?.y || 0);
        }
      } catch (error) { if (!request.signal.aborted) location.reload(); }
    };
    const usageSelectionURL = raw => {
      const requested = currentURL(raw), url = new URL(location.href);
      [...usageKeys, "period", "options_distribution_cursor", "options_arch_cursor", "options_variant_cursor", "options_version_cursor"].forEach(key => url.searchParams.delete(key));
      [...usageKeys, "period"].forEach(key => { if (requested.searchParams.has(key)) url.searchParams.set(key, requested.searchParams.get(key)); });
      url.pathname = "/usage"; url.hash = "";
      return url;
    };
    const loadUsage = async (control, raw = control.href) => {
      const url = usageSelectionURL(raw), panel = document.querySelector("#usage");
      const x = scrollX, y = scrollY, serial = ++usageSerial;
      remember(control);
      usageRequest?.abort(); navigationRequest?.abort();
      const request = new AbortController(); usageRequest = request;
      panel.setAttribute("aria-busy", "true");
      panel.querySelector("[data-usage-loading]")?.remove();
      const loading = node("p", "Loading usage…", {class: "branch-message", role: "status", "data-usage-loading": ""});
      panel.prepend(loading); panel.classList.add("loading");
      // Only the selected bounded usage panel is inserted. The ordinary HTML
      // response keeps the same no-JS rendering and escaping boundary.
      const fetchURL = new URL(url); fetchURL.searchParams.delete("catalog_cursor");
      try {
        const response = await fetch(fetchURL, {signal: request.signal, credentials: "same-origin"});
        const html = new DOMParser().parseFromString(await response.text(), "text/html");
        if (request.signal.aborted || serial !== usageSerial) return;
        const incoming = html.querySelector("#usage");
        if (!incoming) throw Error("usage");
        panel.replaceWith(incoming); navigate(usageSelectionURL(url), control.href || null, false);
        const focus = control.isConnected ? control : Array.from(incoming.querySelectorAll("a")).find(link => link.href === url.href) || incoming.querySelector("h2");
        stableFocus(focus, x, y);
      } catch (error) {
        if (request.signal.aborted || serial !== usageSerial) return;
        loading.textContent = "Usage could not be loaded. Follow the link to try again.";
      } finally {
        if (serial === usageSerial) { panel.removeAttribute("aria-busy"); if (loading.isConnected && loading.textContent === "Loading usage…") loading.remove(); }
      }
    };
    document.addEventListener("click", event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const link = event.target.closest("a"); if (!link) return;
      if (link.matches("[data-choice-page]")) return;
      const destination = new URL(link.href, location.href);
      if (destination.origin !== location.origin) return;
      if (link.matches("[data-catalog-toggle]")) {
        event.preventDefault(); navigationRequest?.abort();
        const holder = link.closest("li[data-catalog-node]"), list = listOf(holder);
        if (link.getAttribute("aria-expanded") === "true" && list) {
          const x=scrollX,y=scrollY;
          pending.forEach((request,target) => { if (holder.contains(target)) request.abort(); });
          list.remove(); link.setAttribute("aria-expanded", "false"); navigate(catalogURL(link.dataset.parentUrl),link.href); stableFocus(link,x,y);
        } else loadBranch(link);
      } else if (link.matches("[data-catalog-more]")) { event.preventDefault(); loadBranch(link, true); }
      else if (usage && destination.pathname === "/usage" && (link.matches("[data-usage-link]") || link.closest("#usage"))) { event.preventDefault(); loadUsage(link); }
    });
    document.addEventListener("change", event => {
      const form = event.target.closest("[data-usage-form]"); if (!form) return;
      const fields = ["distribution", "arch", "vendor", "variant", "version"];
      const changed = fields.indexOf(event.target.name); if (changed < 0) return;
      fields.slice(changed + 1).forEach(name => { const field = form.elements.namedItem(name); if (field) field.value = ""; });
    });
    document.addEventListener("submit", event => {
      if (!event.target.matches("[data-usage-form]")) return;
      event.preventDefault();
      const url = new URL(event.target.action, location.href); url.search = new URLSearchParams(new FormData(event.target)).toString();
      loadUsage(event.submitter || event.target.querySelector("button"), url.href);
    });
    window.addEventListener("popstate", restorePanels);
    remember();
  });
})();
