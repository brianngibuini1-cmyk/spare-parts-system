"use strict";

const list = document.getElementById("approval-list");
const message = document.getElementById("approval-message");
const make = (tag, text, className) => {
  const el = document.createElement(tag);
  if (text !== undefined) el.textContent = text;
  if (className) el.className = className;
  return el;
};

async function loadQueue() {
  message.textContent = "Loading pending submissions…";
  try {
    const products = await window.shopApi.request("/api/v1/products/pending");
    list.replaceChildren();
    if (!products.length) {
      message.textContent = "There are no pending products.";
      return;
    }
    message.textContent = `${products.length} submission${products.length === 1 ? "" : "s"} awaiting review.`;
    for (const product of products) {
      const card = make("article", undefined, "approval-card");
      if (product.image_url) {
        const image = make("img", undefined, "approval-image");
        image.src = product.image_url;
        image.alt = `Photograph of ${product.name}`;
        card.append(image);
      }
      const info = make("div", undefined, "approval-info");
      const heading = make("h2");
      const link = make("a", product.name);
      link.href = `/products/${encodeURIComponent(product.id)}`;
      heading.append(link);
      info.append(heading, make("p", product.internal_reference, "product-reference"));
      info.append(make("p", `Submitted by ${product.submitted_by_login} · ${new Date(product.submitted_at).toLocaleString()}`));
      if (product.category) info.append(make("p", `Category: ${product.category}`));
      if (product.manufacturer_part_number) info.append(make("p", `Manufacturer part number: ${product.manufacturer_part_number}`));
      if (product.description) info.append(make("p", product.description));
      const approveForm = make("form", undefined, "approval-action-form");
      approveForm.dataset.action = "approve";
      approveForm.dataset.id = product.id;
      const priceLabel = make("label", "Selling price");
      const price = make("input");
      price.name = "selling_price";
      price.type = "number";
      price.min = "0";
      price.max = "99999999999999.9999";
      price.step = "0.0001";
      price.required = true;
      priceLabel.append(price);
      approveForm.append(priceLabel, make("button", "Approve with this price", "button button-primary"));
      const rejectForm = make("form", undefined, "approval-action-form reject-form");
      rejectForm.dataset.action = "reject";
      rejectForm.dataset.id = product.id;
      const reasonLabel = make("label", "Rejection reason");
      const reason = make("textarea");
      reason.name = "reason";
      reason.required = true;
      reason.maxLength = 2000;
      reasonLabel.append(reason);
      rejectForm.append(reasonLabel, make("button", "Reject submission", "button button-danger"));
      card.append(info, approveForm, rejectForm);
      list.append(card);
    }
  } catch (error) {
    message.textContent = error.message;
  }
}

list.addEventListener("submit", async (event) => {
  const form = event.target.closest("form[data-action]");
  if (!form) return;
  event.preventDefault();
  try {
    const data = new FormData(form);
    const isApprove = form.dataset.action === "approve";
    const payload = isApprove ? { selling_price: data.get("selling_price") } : { reason: data.get("reason") };
    await window.shopApi.request(`/api/v1/products/${form.dataset.id}/${form.dataset.action}`, {
      method: "POST", body: JSON.stringify(payload),
    });
    message.textContent = isApprove ? "Product approved and price recorded." : "Submission rejected with reason recorded.";
    await loadQueue();
  } catch (error) {
    message.textContent = error.message;
  }
});

loadQueue();
