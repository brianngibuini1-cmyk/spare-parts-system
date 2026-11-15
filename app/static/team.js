"use strict";

const list = document.getElementById("attendant-list");
const message = document.getElementById("team-message");
const make = (tag, text, className) => {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
};

async function loadAttendants() {
  try {
    const attendants = await window.shopApi.request("/api/v1/attendants");
    list.replaceChildren();
    if (!attendants.length) list.append(make("p", "No attendants have been added."));
    for (const attendant of attendants) {
      const row = make("article", undefined, "attendant-row");
      row.append(make("div", attendant.login_name), make("span", attendant.is_active ? "Active" : "Disabled", "status-pill"));
      const button = make("button", attendant.is_active ? "Disable" : "Enable", "button button-light");
      button.type = "button";
      button.addEventListener("click", async () => {
        try {
          await window.shopApi.request(`/api/v1/attendants/${attendant.id}`, {
            method: "PATCH", body: JSON.stringify({ is_active: !attendant.is_active }),
          });
          message.textContent = "Account status updated.";
          await loadAttendants();
        } catch (error) {
          message.textContent = error.message;
        }
      });
      row.append(button);
      list.append(row);
    }
  } catch (error) {
    message.textContent = error.message;
  }
}

document.getElementById("attendant-create-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  const fields = new FormData(form);
  try {
    await window.shopApi.request("/api/v1/attendants", {
      method: "POST",
      body: JSON.stringify({ login_name: fields.get("login_name"), password: fields.get("password") }),
    });
    form.reset();
    message.textContent = "Attendant account created. Share its initial password securely.";
    await loadAttendants();
  } catch (error) {
    message.textContent = error.message;
  }
});

loadAttendants();
