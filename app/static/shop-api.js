"use strict";

(() => {
  const csrfToken = () => {
    const part = document.cookie.split("; ").find((item) => item.startsWith("spare_parts_csrf="));
    return part ? decodeURIComponent(part.slice("spare_parts_csrf=".length)) : "";
  };
  async function request(path, options = {}) {
    const headers = new Headers(options.headers || {});
    if (options.body instanceof FormData) {
      headers.set("X-CSRF-Token", csrfToken());
    } else if (options.method && options.method !== "GET") {
      headers.set("Content-Type", "application/json");
      headers.set("X-CSRF-Token", csrfToken());
    }
    const response = await fetch(path, { credentials: "same-origin", ...options, headers });
    const contentType = response.headers.get("content-type") || "";
    const data = contentType.includes("application/json") ? await response.json() : null;
    if (!response.ok) throw new Error(data?.detail || "The request could not be completed.");
    return data;
  }
  window.shopApi = { request };
})();
