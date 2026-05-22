/**
 * Memphis BBQ Rankings — Public Landing Page
 *
 * Auth flow: Cognito Hosted UI implicit grant (response_type=token).
 * Tokens land in the URL hash after redirect. Same pattern as the admin UI.
 *
 * Public routes (no JWT required):
 *   GET /v1/restaurants   — full restaurant list
 *   GET /v1/leaderboard   — ranked snapshot
 *
 * Authenticated route:
 *   POST /v1/ratings      — submit a rating (1–5); requires Bearer token
 *
 * Security notes:
 * - Access tokens stored in sessionStorage only (cleared when tab closes).
 * - Token is never written to localStorage or cookies.
 * - Implicit flow is a known tradeoff at this stage (Phase 5: PKCE + Lambda@Edge).
 */

let CONFIG = null;
let ACCESS_TOKEN = null;
let USER_EMAIL = null;

// Keyed by restaurant_id. Holds the pending star selection before submit.
const pendingRatings = {};

async function init() {
  try {
    CONFIG = await loadConfig();
  } catch {
    showGlobalError("Failed to load application config. Please refresh.");
    return;
  }

  const tokens = parseHashTokens();
  if (tokens) {
    ACCESS_TOKEN = tokens.accessToken;
    const payload = decodeJwtPayload(tokens.idToken);
    USER_EMAIL = payload?.email || "";
    sessionStorage.setItem("access_token", ACCESS_TOKEN);
    sessionStorage.setItem("user_email", USER_EMAIL);
    // Clean the hash from the URL so tokens don't stay visible or get bookmarked.
    history.replaceState(null, "", window.location.pathname);
  } else {
    ACCESS_TOKEN = sessionStorage.getItem("access_token") || null;
    USER_EMAIL = sessionStorage.getItem("user_email") || null;
  }

  updateAuthUI();

  // Fetch public data — no auth header needed.
  const [restaurants, leaderboard] = await Promise.all([
    fetchRestaurants(),
    fetchLeaderboard(),
  ]);

  renderLeaderboard(leaderboard, restaurants);
  renderRestaurants(restaurants, leaderboard);
}

async function loadConfig() {
  const resp = await fetch("/config.json");
  if (!resp.ok) throw new Error("config fetch failed");
  return resp.json();
}

function parseHashTokens() {
  const hash = window.location.hash.slice(1);
  if (!hash) return null;
  const params = new URLSearchParams(hash);
  const accessToken = params.get("access_token");
  const idToken = params.get("id_token");
  if (!accessToken || !idToken) return null;
  return { accessToken, idToken };
}

function decodeJwtPayload(token) {
  try {
    const payload = token.split(".")[1];
    const padded = payload.replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(padded));
  } catch {
    return null;
  }
}

function redirectToLogin() {
  const params = new URLSearchParams({
    client_id: CONFIG.cognito_client_id,
    response_type: "token",
    scope: "openid email profile",
    redirect_uri: CONFIG.redirect_uri,
  });
  window.location.href = `https://${CONFIG.cognito_domain}/oauth2/authorize?${params}`;
}

function logout() {
  sessionStorage.removeItem("access_token");
  sessionStorage.removeItem("user_email");
  ACCESS_TOKEN = null;
  USER_EMAIL = null;
  const params = new URLSearchParams({
    client_id: CONFIG.cognito_client_id,
    logout_uri: CONFIG.redirect_uri,
  });
  window.location.href = `https://${CONFIG.cognito_domain}/logout?${params}`;
}

function handleAuthClick() {
  if (ACCESS_TOKEN) {
    logout();
  } else {
    redirectToLogin();
  }
}

function updateAuthUI() {
  const btn = document.getElementById("auth-btn");
  const emailEl = document.getElementById("user-email");
  if (ACCESS_TOKEN) {
    emailEl.textContent = USER_EMAIL || "";
    btn.textContent = "Sign out";
    btn.classList.add("logout");
  } else {
    emailEl.textContent = "";
    btn.textContent = "Sign in to rate";
    btn.classList.remove("logout");
  }
  // Refresh all submit button states without re-rendering the full grid.
  document.querySelectorAll(".submit-btn").forEach(updateSubmitBtn);
}

function updateSubmitBtn(btn) {
  const rid = btn.dataset.rid;
  if (ACCESS_TOKEN) {
    btn.textContent = "Submit rating";
    btn.classList.remove("login-prompt");
  } else {
    btn.textContent = "Sign in to rate";
    btn.classList.add("login-prompt");
  }
  // Keep disabled if no star selected AND user is authenticated.
  if (ACCESS_TOKEN && !pendingRatings[rid]) {
    btn.disabled = true;
  } else {
    btn.disabled = false;
  }
}

// --- Data fetching ---

async function fetchRestaurants() {
  try {
    const resp = await fetch(`${CONFIG.api_endpoint}/v1/restaurants`);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    return data.restaurants || [];
  } catch (e) {
    showSectionError("restaurants-error", `Could not load restaurants: ${e.message}`);
    return [];
  }
}

async function fetchLeaderboard() {
  try {
    const resp = await fetch(`${CONFIG.api_endpoint}/v1/leaderboard`);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    return data.leaderboard || [];
  } catch (e) {
    showSectionError("leaderboard-error", `Could not load leaderboard: ${e.message}`);
    return [];
  }
}

// --- Rendering ---

function renderLeaderboard(leaderboard, restaurants) {
  document.getElementById("leaderboard-loading").style.display = "none";

  if (!leaderboard.length) {
    document.getElementById("leaderboard-empty").style.display = "";
    return;
  }

  // Build a lookup for restaurant names from the restaurants list.
  const nameMap = {};
  restaurants.forEach(r => { nameMap[r.restaurant_id] = r.name || r.restaurant_id; });

  const tbody = document.getElementById("leaderboard-tbody");
  leaderboard.slice(0, 10).forEach(entry => {
    const rank = entry.rank;
    const name = nameMap[entry.restaurant_id] || entry.restaurant_id;
    const score = Number(entry.bayesian_score).toFixed(2);
    const count = entry.rating_count;
    // Score bar: scale 1–5 to 0–100%.
    const pct = Math.round(((Number(entry.bayesian_score) - 1) / 4) * 100);

    const tr = document.createElement("tr");
    tr.innerHTML = `
      <td class="rank-cell ${rank <= 3 ? `rank-${rank}` : ""}">${rankLabel(rank)}</td>
      <td>${escHtml(name)}</td>
      <td class="score-cell">
        <div class="score-bar-wrap">
          <div class="score-bar"><div class="score-bar-fill" style="width:${pct}%"></div></div>
          ${score}
        </div>
      </td>
      <td class="rating-count">${count}</td>
    `;
    tbody.appendChild(tr);
  });

  document.getElementById("leaderboard-table").style.display = "";
}

function rankLabel(rank) {
  if (rank === 1) return "🥇";
  if (rank === 2) return "🥈";
  if (rank === 3) return "🥉";
  return `#${rank}`;
}

function renderRestaurants(restaurants, leaderboard) {
  document.getElementById("restaurants-loading").style.display = "none";

  if (!restaurants.length) {
    document.getElementById("restaurants-empty").style.display = "";
    return;
  }

  // Build a rank lookup.
  const rankMap = {};
  leaderboard.forEach(e => { rankMap[e.restaurant_id] = e.rank; });

  const grid = document.getElementById("restaurants-grid");
  grid.style.display = "";

  // Sort: ranked restaurants first (by rank), then unranked alphabetically.
  const sorted = [...restaurants].sort((a, b) => {
    const ra = rankMap[a.restaurant_id];
    const rb = rankMap[b.restaurant_id];
    if (ra && rb) return ra - rb;
    if (ra) return -1;
    if (rb) return 1;
    return (a.name || "").localeCompare(b.name || "");
  });

  sorted.forEach(r => {
    const card = buildRestaurantCard(r, rankMap[r.restaurant_id]);
    grid.appendChild(card);
  });
}

function buildRestaurantCard(restaurant, rank) {
  const rid = restaurant.restaurant_id;
  const name = restaurant.name || rid;
  const location = restaurant.location || "";

  const card = document.createElement("div");
  card.className = "restaurant-card";
  card.id = `card-${rid}`;

  const badgeHtml = rank
    ? `<span class="card-badge ranked">#${rank} ranked</span>`
    : `<span class="card-badge">Unranked</span>`;

  const isAuthed = !!ACCESS_TOKEN;
  const submitLabel = isAuthed ? "Submit rating" : "Sign in to rate";
  const submitClass = isAuthed ? "submit-btn" : "submit-btn login-prompt";

  card.innerHTML = `
    <div class="restaurant-name">${escHtml(name)}</div>
    ${location ? `<div class="restaurant-location">${escHtml(location)}</div>` : ""}
    ${badgeHtml}
    <div class="rating-section">
      <div class="stars" id="stars-${rid}">
        ${[1,2,3,4,5].map(n =>
          `<span class="star" data-rid="${rid}" data-score="${n}" onclick="selectStar('${rid}', ${n})">★</span>`
        ).join("")}
      </div>
      <button class="${submitClass}" data-rid="${rid}" onclick="handleSubmit('${rid}')" ${isAuthed ? "disabled" : ""}>${submitLabel}</button>
      <div class="card-status" id="status-${rid}"></div>
    </div>
  `;

  return card;
}

function selectStar(rid, score) {
  pendingRatings[rid] = score;

  // Update star visuals.
  const stars = document.querySelectorAll(`#stars-${rid} .star`);
  stars.forEach(star => {
    star.classList.toggle("active", Number(star.dataset.score) <= score);
  });

  // Enable the submit button if authenticated.
  const btn = document.querySelector(`button[data-rid="${rid}"]`);
  if (btn) {
    btn.disabled = false;
  }
}

async function handleSubmit(rid) {
  if (!ACCESS_TOKEN) {
    redirectToLogin();
    return;
  }

  const score = pendingRatings[rid];
  if (!score) return;

  const btn = document.querySelector(`button[data-rid="${rid}"]`);
  const statusEl = document.getElementById(`status-${rid}`);

  btn.disabled = true;
  btn.textContent = "Submitting…";
  statusEl.textContent = "";
  statusEl.className = "card-status";

  try {
    const resp = await fetch(`${CONFIG.api_endpoint}/v1/ratings`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${ACCESS_TOKEN}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ restaurant_id: rid, score }),
    });

    if (resp.status === 401) {
      // Token expired — clear session and prompt re-login.
      sessionStorage.removeItem("access_token");
      sessionStorage.removeItem("user_email");
      ACCESS_TOKEN = null;
      USER_EMAIL = null;
      updateAuthUI();
      statusEl.textContent = "Session expired — please sign in again.";
      statusEl.className = "card-status error";
      return;
    }

    if (!resp.ok) {
      const data = await resp.json().catch(() => ({}));
      throw new Error(data.message || `HTTP ${resp.status}`);
    }

    statusEl.textContent = `Your ${score}-star rating was saved.`;
    statusEl.className = "card-status";
    btn.textContent = "Rating saved";
  } catch (e) {
    statusEl.textContent = `Error: ${e.message}`;
    statusEl.className = "card-status error";
    btn.disabled = false;
    btn.textContent = "Submit rating";
  }
}

// --- Utilities ---

function escHtml(str) {
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function showSectionError(elId, msg) {
  const el = document.getElementById(elId);
  if (el) { el.textContent = msg; el.style.display = ""; }
}

function showGlobalError(msg) {
  document.body.innerHTML = `<div style="padding:2rem;color:#e07070;font-family:sans-serif">${escHtml(msg)}</div>`;
}

document.addEventListener("DOMContentLoaded", init);
