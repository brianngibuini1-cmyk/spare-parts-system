"use strict";

const productList = document.getElementById("product-list");
const catalogueMessage = document.getElementById("catalogue-message");
const searchInput = document.getElementById("product-search");
const statusInput = document.getElementById("product-status");
const createForm = document.getElementById("product-create-form");

function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text !== undefined && text !== null) element.textContent = text;
  if (className) element.className = className;
  return element;
}

async function loadProducts() {
  catalogueMessage.textContent = "Loading products…";
  const params = new URLSearchParams({ limit: "100" });
  if (searchInput.value.trim()) params.set("q", searchInput.value.trim());
  if (statusInput.value) params.set("approval_status", statusInput.value);
  try {
    const result = await window.shopApi.request(`/api/v1/products?${params}`);
    productList.replaceChildren();
    if (!result.items.length) {
      catalogueMessage.textContent = "No products match this view yet.";
      return;
    }
    catalogueMessage.textContent = `${result.items.length} product${result.items.length === 1 ? "" : "s"}`;
    for (const product of result.items) {
      const card = node("article", undefined, "product-card");
      if (product.image_url) {
        const image = node("img", undefined, "product-thumb");
        image.src = product.image_url;
        image.alt = `Photograph of ${product.name}`;
        card.append(image);
      } else card.append(node("div", "No photo", "product-thumb image-empty"));
      const main = node("div", undefined, "product-card-main");
      const title = node("h3");
      const link = node("a", product.name);
      link.href = `/products/${encodeURIComponent(product.id)}`;
      title.append(link);
      main.append(title, node("p", product.internal_reference, "product-reference"));
      const details = [product.category, product.manufacturer_part_number].filter(Boolean).join(" · ");
      if (details) main.append(node("p", details, "muted"));
      if (product.approval_status === "approved") {
        main.append(node("p", `Selling price: ${product.selling_price}`, "product-price"));
      } else if (product.approval_status === "rejected") {
        main.append(node("p", product.rejection_reason || "Rejected", "rejection-note-text"));
      }
      const status = node("span", product.approval_status, `status-pill status-${product.approval_status}`);
      card.append(main, status);
      productList.append(card);
    }
  } catch (error) {
    catalogueMessage.textContent = error.message;
  }
}

let searchTimer;
searchInput.addEventListener("input", () => {
  window.clearTimeout(searchTimer);
  searchTimer = window.setTimeout(loadProducts, 200);
});
statusInput.addEventListener("change", loadProducts);

const imageInput = document.getElementById("product-image-input");
const preview = document.getElementById("image-preview");
let previewUrl;
imageInput.addEventListener("change", () => {
  if (previewUrl) URL.revokeObjectURL(previewUrl);
  const file = imageInput.files[0];
  preview.hidden = !file;
  if (file) {
    previewUrl = URL.createObjectURL(file);
    preview.src = previewUrl;
  }
});

createForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const message = document.getElementById("product-form-message");
  const form = new FormData(createForm);
  const payload = Object.fromEntries(["name", "description", "category", "manufacturer_part_number"].map((key) => [key, form.get(key) || null]));
  try {
    const product = await window.shopApi.request("/api/v1/products", { method: "POST", body: JSON.stringify(payload) });
    const image = imageInput.files[0];
    if (image) {
      const upload = new FormData();
      upload.set("file", image);
      await window.shopApi.request(`/api/v1/products/${product.id}/image`, { method: "POST", body: upload });
    }
    createForm.reset();
    preview.hidden = true;
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = null;
    message.textContent = `Submitted ${product.internal_reference} for owner review.`;
    await loadProducts();
  } catch (error) {
    message.textContent = error.message;
  }
});

loadProducts();
