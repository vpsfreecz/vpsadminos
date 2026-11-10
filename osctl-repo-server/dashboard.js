(() => {
  "use strict";
  const key = "osctl-repo-theme";
  const valid = value => ["system", "light", "dark"].includes(value);
  let choice = "system";
  try {
    const saved = window.localStorage.getItem(key);
    if (valid(saved)) choice = saved;
  } catch (_) { /* A disabled storage area must not disable the switch. */ }
  const apply = value => {
    choice = valid(value) ? value : "system";
    if (choice === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = choice;
  };
  apply(choice);
  document.addEventListener("DOMContentLoaded", () => {
    const control = document.querySelector("[data-theme-control]");
    const select = document.querySelector("#theme-choice");
    if (!control || !select) return;
    select.value = choice;
    control.hidden = false;
    select.addEventListener("change", () => {
      apply(select.value);
      try {
        if (choice === "system") window.localStorage.removeItem(key);
        else window.localStorage.setItem(key, choice);
      } catch (_) { /* The selected theme still applies for this page. */ }
    });
  });
})();
