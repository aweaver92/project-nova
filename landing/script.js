/* ============ NAV: scroll state + mobile menu ============ */
const nav = document.getElementById("nav");
const navToggle = document.getElementById("nav-toggle");
const mobileMenu = document.getElementById("mobile-menu");

const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 8);
window.addEventListener("scroll", onScroll, { passive: true });
onScroll();

navToggle.addEventListener("click", () => {
  const open = mobileMenu.classList.toggle("open");
  navToggle.classList.toggle("open", open);
  navToggle.setAttribute("aria-expanded", String(open));
});

mobileMenu.querySelectorAll("a").forEach((link) =>
  link.addEventListener("click", () => {
    mobileMenu.classList.remove("open");
    navToggle.classList.remove("open");
    navToggle.setAttribute("aria-expanded", "false");
  })
);

/* ============ SCROLL REVEAL ============ */
const revealObserver = new IntersectionObserver(
  (entries) => {
    for (const entry of entries) {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        revealObserver.unobserve(entry.target);
      }
    }
  },
  { threshold: 0.12, rootMargin: "0px 0px -40px 0px" }
);
document.querySelectorAll(".reveal").forEach((el) => revealObserver.observe(el));

/* ============ HERO DEMO CONVERSATION ============ */
const demoBody = document.getElementById("demo-body");

const script = [
  { who: "user", text: "Nova, is the front door locked?" },
  { who: "tool", text: "→ home_assistant · lock.front_door" },
  { who: "nova", text: "Yes — the front door locked 20 minutes ago. The garage is still open, want me to close it?" },
  { who: "user", text: "Yeah. And what did we decide about the audio pipeline yesterday?" },
  { who: "tool", text: "→ knowledge_search · \"audio pipeline decision\"" },
  { who: "nova", text: "Closing the garage. Yesterday you decided to keep barge-in in the domain layer and validate it in the Windows sim before touching the iOS adapters." },
  { who: "user", text: "Right. Let me talk to Claude — have it add latency logging to the sim." },
  { who: "tool", text: "→ push_to_cursor · nova-sim · streaming…" },
  { who: "nova", text: "Claude's on it. I'll read you the summary when the run finishes." },
];

const MSG_DELAY = 2100;
const RESTART_DELAY = 5200;
let demoStarted = false;

function playDemo(index = 0) {
  if (index === 0) demoBody.innerHTML = "";
  if (index >= script.length) {
    setTimeout(() => playDemo(0), RESTART_DELAY);
    return;
  }
  const { who, text } = script[index];
  const el = document.createElement("div");
  el.className = `demo-msg ${who}`;
  el.textContent = text;
  demoBody.appendChild(el);

  // Keep only the last few messages visible so the panel doesn't grow unbounded
  while (demoBody.children.length > 5) demoBody.removeChild(demoBody.firstChild);

  setTimeout(() => playDemo(index + 1), MSG_DELAY);
}

const demoObserver = new IntersectionObserver(
  (entries) => {
    if (entries.some((e) => e.isIntersecting) && !demoStarted) {
      demoStarted = true;
      playDemo();
      demoObserver.disconnect();
    }
  },
  { threshold: 0.3 }
);
demoObserver.observe(demoBody);

/* ============ COPY QUICK-START ============ */
const copyBtn = document.getElementById("copy-btn");
const quickstart = document.getElementById("quickstart-code");

copyBtn.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(quickstart.textContent);
    copyBtn.textContent = "Copied!";
    copyBtn.classList.add("copied");
    setTimeout(() => {
      copyBtn.textContent = "Copy";
      copyBtn.classList.remove("copied");
    }, 1800);
  } catch {
    copyBtn.textContent = "Press Ctrl+C";
    setTimeout(() => (copyBtn.textContent = "Copy"), 1800);
  }
});
