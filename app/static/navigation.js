const menuButton = document.querySelector(".menu-toggle");
const navigation = document.querySelector("#primary-nav");

menuButton?.addEventListener("click", () => {
  const expanded = menuButton.getAttribute("aria-expanded") === "true";
  menuButton.setAttribute("aria-expanded", String(!expanded));
  navigation?.classList.toggle("open", !expanded);
});

navigation?.addEventListener("click", (event) => {
  const link = event.target.closest("a[aria-disabled='true']");
  if (link) event.preventDefault();
});

const logoutButton = document.getElementById("logout-button");
logoutButton?.addEventListener("click", async () => {
  const csrf = document.cookie.split("; ").find((part) => part.startsWith("spare_parts_csrf="));
  const token = csrf ? decodeURIComponent(csrf.split("=").slice(1).join("=")) : "";
  const response = await fetch("/api/v1/auth/logout", {
    method: "POST",
    credentials: "same-origin",
    headers: { "X-CSRF-Token": token },
  });
  if (response.ok) window.location.assign("/login");
});
