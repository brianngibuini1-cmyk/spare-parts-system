"use strict";

const page = document.querySelector("main[data-product-id]");
const productId = page.dataset.productId;
const message = document.getElementById("detail-message");
const approvalMessage = document.getElementById("approval-detail-message");

document.getElementById("product-edit-form")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const data = new FormData(event.currentTarget);
  const payload = Object.fromEntries(["name", "description", "category", "manufacturer_part_number"].map((key) => [key, data.get(key)]));
  try {
    await window.shopApi.request(`/api/v1/products/${productId}`, { method: "PATCH", body: JSON.stringify(payload) });
    message.textContent = "Product details saved.";
  } catch (error) {
    message.textContent = error.message;
  }
});

document.getElementById("detail-image-form")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const file = new FormData(event.currentTarget).get("image");
  const data = new FormData();
  data.set("file", file);
  try {
    await window.shopApi.request(`/api/v1/products/${productId}/image`, { method: "POST", body: data });
    window.location.reload();
  } catch (error) {
    message.textContent = error.message;
  }
});

document.getElementById("price-approval-form")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const price = new FormData(event.currentTarget).get("selling_price");
  try {
    await window.shopApi.request(`/api/v1/products/${productId}/approve`, {
      method: "POST", body: JSON.stringify({ selling_price: price }),
    });
    window.location.reload();
  } catch (error) {
    approvalMessage.textContent = error.message;
  }
});

document.getElementById("product-reject-form")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  const reason = new FormData(event.currentTarget).get("reason");
  try {
    await window.shopApi.request(`/api/v1/products/${productId}/reject`, {
      method: "POST", body: JSON.stringify({ reason }),
    });
    window.location.reload();
  } catch (error) {
    approvalMessage.textContent = error.message;
  }
});
