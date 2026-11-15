"use strict";

document.getElementById("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const error = document.getElementById("login-error");
  const button = form.querySelector("button");
  error.textContent = "";
  button.disabled = true;
  try {
    const response = await fetch("/api/v1/auth/login", {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        login_name: form.elements.login_name.value,
        password: form.elements.password.value,
      }),
    });
    if (!response.ok) {
      error.textContent = response.status === 429
        ? "Sign in is temporarily unavailable. Try again later."
        : "The login name or password is incorrect.";
      return;
    }
    window.location.assign("/");
  } catch (_) {
    error.textContent = "Unable to sign in right now. Please try again.";
  } finally {
    button.disabled = false;
  }
});
