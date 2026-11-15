"use strict";

const demoState = {
  products: [
    { id: "p-101", name: "Ceramic Brake Pad Set", code: "SP-DEMO-101", category: "Braking", location: "A1 · 03", price: 36.5, onHand: 18, marker: 5, icon: "▰", tone: "" },
    { id: "p-202", name: "Spin-On Oil Filter", code: "SP-DEMO-202", category: "Filtration", location: "B2 · 01", price: 12.75, onHand: 7, marker: 8, icon: "◉", tone: "blue" },
    { id: "p-303", name: "Iridium Spark Plug Pair", code: "SP-DEMO-303", category: "Ignition", location: "C1 · 02", price: 24.2, onHand: 24, marker: 6, icon: "ϟ", tone: "gold" },
    { id: "p-404", name: "Alternator Drive Belt", code: "SP-DEMO-404", category: "Engine", location: "D3 · 01", price: 18.9, onHand: 3, marker: 4, icon: "⌁", tone: "rose" },
  ],
  suppliers: [
    { id: "s-1", name: "Northstar Parts House", specialty: "Filters · engine service", contact: "Mira Lane", email: "orders@northstar.example.invalid", phone: "+000 555 0101", city: "Sample District", initials: "NP", note: "Fictional supplier profile. Contact details are reserved examples and cannot receive messages." },
    { id: "s-2", name: "Cedarline Auto Supply", specialty: "Braking · ignition", contact: "Jon Bell", email: "hello@cedarline.example.invalid", phone: "+000 555 0102", city: "Demo Industrial Park", initials: "CA", note: "Fictional supplier profile. No purchase history or balances are stored." },
  ],
  cart: [],
  selectedSupplier: "s-1",
  currentReceipt: null,
  activities: [
    { title: "Sample checkout completed", detail: "Ceramic Brake Pad Set · 2 items", time: "Today · 9:42 AM", tone: "" },
    { title: "Sample stock received", detail: "Spin-On Oil Filter · Northstar Parts House", time: "Today · 8:15 AM", tone: "gold" },
    { title: "Product details updated", detail: "Iridium Spark Plug Pair", time: "Yesterday · 4:06 PM", tone: "blue" },
  ],
};

const sampleWeek = [
  { day: "Mon", amount: 410 }, { day: "Tue", amount: 550 }, { day: "Wed", amount: 375 },
  { day: "Thu", amount: 680 }, { day: "Fri", amount: 590 }, { day: "Sat", amount: 760 }, { day: "Sun", amount: 543 },
];
const byId = (id) => document.getElementById(id);
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (char) => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[char]);
const amount = (value) => Number(value).toFixed(2);
const productById = (id) => demoState.products.find((product) => product.id === id);
let toastTimer;

function showToast(message) {
  const toast = byId("toast");
  toast.textContent = message;
  toast.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove("show"), 2800);
}

function activatePage(page) {
  const allowed = ["dashboard", "products", "inventory", "sales", "receipt", "suppliers", "receiving"];
  const current = allowed.includes(page) ? page : "dashboard";
  document.querySelectorAll("[data-screen]").forEach((screen) => {
    screen.hidden = screen.dataset.screen !== current;
  });
  document.querySelectorAll("[data-page-link]").forEach((link) => {
    const active = link.dataset.pageLink === current;
    link.classList.toggle("active", active);
    if (active) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  });
  const activeLink = document.querySelector(`[data-page-link="${current}"]`);
  byId("screen-label").textContent = activeLink?.textContent.trim() || "Receipt preview";
  byId("sidebar").classList.remove("open");
  byId("mobile-scrim").hidden = true;
  document.querySelector(".mobile-menu").setAttribute("aria-expanded", "false");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function stockStatus(product) {
  return product.onHand <= product.marker ? "low" : "ok";
}

function renderChart() {
  const max = Math.max(...sampleWeek.map((entry) => entry.amount));
  byId("sales-chart").innerHTML = sampleWeek.map((entry) => {
    const height = Math.max(8, Math.round((entry.amount / max) * 100));
    return `<div class="chart-column"><span class="chart-value">${amount(entry.amount)}</span><div class="chart-bar-wrap"><div class="chart-bar" style="height:${height}%" title="Illustrative amount ${amount(entry.amount)}"></div></div><span class="chart-day">${entry.day}</span></div>`;
  }).join("");
}

function renderActivity() {
  byId("activity-list").innerHTML = demoState.activities.slice(0, 5).map((activity) => `
    <div class="activity-item"><span class="activity-dot ${escapeHtml(activity.tone)}"></span><div class="activity-copy"><strong>${escapeHtml(activity.title)}</strong><small>${escapeHtml(activity.detail)} · ${escapeHtml(activity.time)}</small></div></div>
  `).join("");
}

function renderProductRows() {
  const query = byId("product-search").value.trim().toLowerCase();
  const matches = demoState.products.filter((product) => `${product.name} ${product.code} ${product.category}`.toLowerCase().includes(query));
  byId("product-count").textContent = `${matches.length} sample item${matches.length === 1 ? "" : "s"}`;
  byId("product-rows").innerHTML = matches.map((product) => `
    <tr><td><span class="product-name-cell"><span class="product-thumb ${escapeHtml(product.tone)}">${escapeHtml(product.icon)}</span>${escapeHtml(product.name)}</span></td><td><span class="code-text">${escapeHtml(product.code)}</span></td><td>${escapeHtml(product.category)}</td><td>${escapeHtml(product.location || "—")}</td><td>${amount(product.price)}</td><td>${product.onHand}</td><td><button class="row-action" data-action="edit-product" data-id="${escapeHtml(product.id)}">Edit</button></td></tr>
  `).join("") || '<tr><td colspan="7" class="empty-cell">No sample products match that search.</td></tr>';
}

function renderInventoryRows() {
  const query = byId("inventory-search").value.trim().toLowerCase();
  const matches = demoState.products.filter((product) => `${product.name} ${product.code} ${product.location}`.toLowerCase().includes(query));
  byId("inventory-rows").innerHTML = matches.map((product) => {
    const low = stockStatus(product) === "low";
    return `<tr><td><span class="product-name-cell"><span class="product-thumb ${escapeHtml(product.tone)}">${escapeHtml(product.icon)}</span>${escapeHtml(product.name)}</span></td><td><span class="code-text">${escapeHtml(product.code)}</span></td><td>${escapeHtml(product.location || "—")}</td><td><strong>${product.onHand}</strong></td><td>${product.marker} units <span class="code-text">(demo)</span></td><td><span class="status-cell ${low ? "low" : ""}"><i></i>${low ? "Review sample" : "Sample OK"}</span></td></tr>`;
  }).join("") || '<tr><td colspan="6" class="empty-cell">No sample inventory matches that search.</td></tr>';
}

function renderCheckoutProducts() {
  const query = byId("checkout-search").value.trim().toLowerCase();
  const matches = demoState.products.filter((product) => `${product.name} ${product.code}`.toLowerCase().includes(query));
  byId("checkout-products").innerHTML = matches.map((product) => `
    <div class="picker-item"><span class="product-thumb ${escapeHtml(product.tone)}">${escapeHtml(product.icon)}</span><div class="picker-copy"><strong>${escapeHtml(product.name)}</strong><small>${escapeHtml(product.code)} · sample on hand ${product.onHand}</small></div><span class="picker-price">${amount(product.price)}</span><button class="add-line" data-action="add-cart" data-id="${escapeHtml(product.id)}" aria-label="Add ${escapeHtml(product.name)} to sample cart">+</button></div>
  `).join("") || '<p class="footnote">No matching sample products.</p>';
}

function renderCart() {
  const count = demoState.cart.reduce((sum, line) => sum + line.quantity, 0);
  const total = demoState.cart.reduce((sum, line) => sum + line.price * line.quantity, 0);
  byId("cart-count").textContent = `${count} item${count === 1 ? "" : "s"}`;
  byId("cart-lines").innerHTML = demoState.cart.map((line) => `
    <div class="cart-line"><div><div class="cart-line-title">${escapeHtml(line.name)}</div><div class="cart-line-meta">${amount(line.price)} illustrative each</div><div class="quantity-control"><button data-action="decrease-cart" data-id="${escapeHtml(line.id)}" aria-label="Decrease ${escapeHtml(line.name)} quantity">−</button><span>${line.quantity}</span><button data-action="increase-cart" data-id="${escapeHtml(line.id)}" aria-label="Increase ${escapeHtml(line.name)} quantity">+</button></div></div><div class="cart-line-end"><span class="line-amount">${amount(line.price * line.quantity)}</span><button class="remove-line" data-action="remove-cart" data-id="${escapeHtml(line.id)}">Remove</button></div></div>
  `).join("");
  byId("cart-empty").hidden = demoState.cart.length > 0;
  byId("preview-button").disabled = demoState.cart.length === 0;
  byId("cart-subtotal").textContent = amount(total);
  byId("cart-total").textContent = amount(total);
}

function renderSuppliers() {
  const receiveSupplier = byId("receive-supplier").value;
  byId("supplier-list").innerHTML = demoState.suppliers.map((supplier) => `
    <button class="supplier-card ${supplier.id === demoState.selectedSupplier ? "selected" : ""}" data-action="select-supplier" data-id="${escapeHtml(supplier.id)}"><span class="supplier-monogram">${escapeHtml(supplier.initials)}</span><span class="supplier-card-copy"><strong>${escapeHtml(supplier.name)}</strong><small>${escapeHtml(supplier.specialty)}</small></span><span class="supplier-arrow">›</span></button>
  `).join("");
  const supplier = demoState.suppliers.find((entry) => entry.id === demoState.selectedSupplier) || demoState.suppliers[0];
  if (!supplier) return;
  byId("supplier-detail").innerHTML = `
    <div class="supplier-detail-head"><span class="supplier-monogram">${escapeHtml(supplier.initials)}</span><div><h2>${escapeHtml(supplier.name)}</h2><p>${escapeHtml(supplier.specialty)}</p></div></div>
    <div class="detail-fields"><div class="detail-field"><span>Contact</span><strong>${escapeHtml(supplier.contact)}</strong></div><div class="detail-field"><span>Email</span><strong>${escapeHtml(supplier.email)}</strong></div><div class="detail-field"><span>Phone</span><strong>${escapeHtml(supplier.phone)}</strong></div><div class="detail-field"><span>Location</span><strong>${escapeHtml(supplier.city)}</strong></div></div>
    <div class="supplier-note">${escapeHtml(supplier.note)}</div>`;
  byId("receive-supplier").innerHTML = demoState.suppliers.map((entry) => `<option value="${escapeHtml(entry.id)}">${escapeHtml(entry.name)}</option>`).join("");
  if (demoState.suppliers.some((entry) => entry.id === receiveSupplier)) {
    byId("receive-supplier").value = receiveSupplier;
  }
}

function renderReceiveProducts() {
  const selected = byId("receive-product").value;
  byId("receive-product").innerHTML = demoState.products.map((product) => `<option value="${escapeHtml(product.id)}">${escapeHtml(product.name)} · sample ${product.onHand}</option>`).join("");
  if (demoState.products.some((product) => product.id === selected)) byId("receive-product").value = selected;
  updateReceivePreview();
}

function updateReceivePreview() {
  const product = productById(byId("receive-product").value);
  const quantity = Math.max(1, Number(byId("receive-form").elements.quantity.value) || 1);
  byId("receive-preview").textContent = product
    ? `Sample on hand ${product.onHand} → ${product.onHand + quantity} after this browser-only example.`
    : "Add a sample product before previewing a delivery.";
}

function renderDashboard() {
  const lowProducts = demoState.products.filter((product) => stockStatus(product) === "low");
  byId("metric-products").textContent = String(demoState.products.length).padStart(2, "0");
  byId("metric-low-stock").textContent = String(lowProducts.length).padStart(2, "0");
  byId("dashboard-low-stock").innerHTML = lowProducts.map((product) => `
    <div class="low-stock-item"><div><strong>${escapeHtml(product.name)}</strong><small>${escapeHtml(product.code)} · sample on hand ${product.onHand}</small></div><span class="low-pill">Review</span></div>
  `).join("") || '<div class="footnote">No products are below their sample markers.</div>';
}

function renderAll() {
  renderDashboard();
  renderChart();
  renderActivity();
  renderProductRows();
  renderInventoryRows();
  renderCheckoutProducts();
  renderCart();
  renderSuppliers();
  renderReceiveProducts();
  byId("inventory-total").textContent = String(demoState.products.length).padStart(2, "0");
  byId("inventory-units").textContent = String(demoState.products.reduce((sum, product) => sum + product.onHand, 0));
  byId("inventory-alerts").textContent = String(demoState.products.filter((product) => stockStatus(product) === "low").length).padStart(2, "0");
}

function openProductDialog(product = null) {
  const dialog = byId("product-dialog");
  const form = byId("product-form");
  form.reset();
  form.elements.id.value = product?.id || "";
  form.elements.name.value = product?.name || "";
  form.elements.code.value = product?.code || "";
  form.elements.category.value = product?.category || "";
  form.elements.location.value = product?.location || "";
  form.elements.price.value = product?.price ?? "0.00";
  byId("product-dialog-title").textContent = product ? "Edit sample product" : "Add sample product";
  dialog.showModal();
}

function previewReceipt() {
  if (!demoState.cart.length) return;
  demoState.currentReceipt = {
    lines: demoState.cart.map((line) => ({ ...line })),
    total: demoState.cart.reduce((sum, line) => sum + line.price * line.quantity, 0),
    time: new Date().toLocaleString(),
  };
  byId("receipt-date").textContent = demoState.currentReceipt.time;
  byId("receipt-lines").innerHTML = demoState.currentReceipt.lines.map((line) => `
    <tr><td>${escapeHtml(line.name)}</td><td>${line.quantity}</td><td>${amount(line.price)}</td><td>${amount(line.price * line.quantity)}</td></tr>
  `).join("");
  byId("receipt-total").textContent = amount(demoState.currentReceipt.total);
  location.hash = "receipt";
  activatePage("receipt");
}

document.addEventListener("click", (event) => {
  const link = event.target.closest("[data-page-link]");
  if (link) {
    event.preventDefault();
    location.hash = link.dataset.pageLink;
    activatePage(link.dataset.pageLink);
    return;
  }

  const action = event.target.closest("[data-action]");
  if (!action) return;
  const id = action.dataset.id;
  const product = productById(id);
  switch (action.dataset.action) {
    case "go-sales": location.hash = "sales"; activatePage("sales"); break;
    case "go-inventory": location.hash = "inventory"; activatePage("inventory"); break;
    case "go-receiving": location.hash = "receiving"; activatePage("receiving"); break;
    case "add-product": openProductDialog(); break;
    case "edit-product": if (product) openProductDialog(product); break;
    case "close-product-dialog": byId("product-dialog").close(); break;
    case "add-cart": {
      if (!product) break;
      const line = demoState.cart.find((entry) => entry.id === product.id);
      if (line) line.quantity += 1;
      else demoState.cart.push({ id: product.id, name: product.name, price: product.price, quantity: 1 });
      renderCart();
      showToast("Added to this session’s sample cart.");
      break;
    }
    case "increase-cart": {
      const line = demoState.cart.find((entry) => entry.id === id);
      if (line) line.quantity += 1;
      renderCart();
      break;
    }
    case "decrease-cart": {
      const line = demoState.cart.find((entry) => entry.id === id);
      if (line) line.quantity = Math.max(1, line.quantity - 1);
      renderCart();
      break;
    }
    case "remove-cart": demoState.cart = demoState.cart.filter((entry) => entry.id !== id); renderCart(); break;
    case "clear-cart": demoState.cart = []; renderCart(); break;
    case "preview-receipt": previewReceipt(); break;
    case "print-receipt": window.print(); break;
    case "back-to-sales": location.hash = "sales"; activatePage("sales"); break;
    case "select-supplier": demoState.selectedSupplier = id; renderSuppliers(); break;
  }
});

document.addEventListener("input", (event) => {
  if (event.target.id === "product-search") renderProductRows();
  if (event.target.id === "inventory-search") renderInventoryRows();
  if (event.target.id === "checkout-search") renderCheckoutProducts();
  if (event.target.name === "quantity" && event.target.form?.id === "receive-form") updateReceivePreview();
});

byId("product-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  if (!form.reportValidity()) return;
  const fields = new FormData(form);
  const id = String(fields.get("id") || "");
  const existing = productById(id);
  const values = {
    name: String(fields.get("name")).trim(),
    code: String(fields.get("code")).trim(),
    category: String(fields.get("category")).trim(),
    location: String(fields.get("location")).trim(),
    price: Number(fields.get("price")) || 0,
  };
  if (existing) Object.assign(existing, values);
  else demoState.products.push({ id: `demo-${Date.now()}`, ...values, onHand: 0, marker: 4, icon: "◈", tone: "" });
  byId("product-dialog").close();
  renderAll();
  showToast(existing ? "Sample product updated in this browser session." : "Sample product added with zero sample quantity.");
});

byId("receive-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const form = event.currentTarget;
  if (!form.reportValidity()) return;
  const product = productById(form.elements.productId.value);
  const supplier = demoState.suppliers.find((entry) => entry.id === form.elements.supplierId.value);
  const quantity = Number(form.elements.quantity.value);
  if (!product || !supplier || !Number.isInteger(quantity) || quantity < 1) return;
  product.onHand += quantity;
  demoState.activities.unshift({ title: "Demo receiving example", detail: `${product.name} · ${supplier.name} · ${quantity} sample units`, time: "Just now · not saved", tone: "gold" });
  renderAll();
  showToast("Sample quantity updated in memory only; no stock movement was saved.");
});

byId("receive-product").addEventListener("change", updateReceivePreview);
document.querySelector(".mobile-menu").addEventListener("click", (event) => {
  const open = !byId("sidebar").classList.contains("open");
  byId("sidebar").classList.toggle("open", open);
  byId("mobile-scrim").hidden = !open;
  event.currentTarget.setAttribute("aria-expanded", String(open));
});
byId("mobile-scrim").addEventListener("click", () => activatePage(location.hash.slice(1)));
window.addEventListener("hashchange", () => activatePage(location.hash.slice(1)));

renderAll();
activatePage(location.hash.slice(1) || "dashboard");
