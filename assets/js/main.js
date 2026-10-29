"use strict";

// Mobile navigation toggle
const toggle = document.querySelector(".nav-toggle");
const nav = document.getElementById("nav");

function setNavOpen(open) {
  nav.classList.toggle("open", open);
  toggle.setAttribute("aria-expanded", String(open));
}

toggle.addEventListener("click", () => {
  setNavOpen(toggle.getAttribute("aria-expanded") !== "true");
});
nav.addEventListener("click", (event) => {
  if (event.target.closest("a")) {
    setNavOpen(false);
  }
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    setNavOpen(false);
  }
});

// Copy-to-clipboard buttons
document.querySelectorAll("[data-copy]").forEach((button) => {
  button.addEventListener("click", async () => {
    const target = document.querySelector(button.dataset.copy);
    try {
      await navigator.clipboard.writeText(target.textContent);
      button.textContent = "Copied";
    } catch (error) {
      button.textContent = "Press Ctrl+C";
    }
    setTimeout(() => {
      button.textContent = "Copy";
    }, 2000);
  });
});

// Footer year
document.getElementById("year").textContent = String(new Date().getFullYear());
