/**
 * Memphis BBQ Admin UI
 *
 * Auth flow: Cognito Hosted UI implicit grant (response_type=token).
 * Tokens land in the URL hash after the Hosted UI redirect.
 *
 * Why implicit and not PKCE: this is a static S3 page with no backend relay.
 * PKCE requires exchanging the authorization code for tokens via a POST to the
 * Cognito token endpoint, which requires CORS support that Cognito only provides
 * for the code flow when a server-side handler performs the exchange.
 * Phase 5 upgrade: replace with PKCE + Lambda@Edge token proxy.
 *
 * Security notes:
 * - Access tokens expire in 60 minutes.
 * - Tokens are stored in sessionStorage (cleared when the tab closes).
 * - Server-side admin group checks are the authoritative control — the client-side
 *   group check below is a UX gate only, not a security boundary.
 * - All API routes independently verify group membership via AdminListGroupsForUser.
 */

let CONFIG = null;
let ACCESS_TOKEN = null;

async function loadConfig() {
  const resp = await fetch("/admin/config.json");
  if (!resp.ok) throw new Error("Failed to load config");
  CONFIG = await resp.json();
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
    // base64url → base64 → JSON
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

async function apiCall(path, method = "GET", body = null) {
  const opts = {
    method,
    headers: { Authorization: `Bearer ${ACCESS_TOKEN}`, "Content-Type": "application/json" },
  };
  if (body) opts.body = JSON.stringify(body);
  const resp = await fetch(`${CONFIG.api_endpoint}${path}`, opts);
  const data = await resp.json();
  return { ok: resp.ok, status: resp.status, data };
}

function showStatus(msg) {
  const el = document.getElementById("status-msg");
  el.textContent = msg;
  el.style.display = "block";
  setTimeout(() => { el.style.display = "none"; }, 4000);
}

// --- Users Panel ---
async function loadUsers() {
  const tbody = document.getElementById("users-tbody");
  tbody.innerHTML = "<tr><td colspan='5'>Loading...</td></tr>";
  const { ok, data } = await apiCall("/v1/admin/users");
  if (!ok) { tbody.innerHTML = `<tr><td colspan='5'>Error loading users</td></tr>`; return; }
  if (!data.users || !data.users.length) { tbody.innerHTML = "<tr><td colspan='5'>No users found</td></tr>"; return; }
  tbody.innerHTML = data.users.map(u => `
    <tr>
      <td>${u.email}</td>
      <td><code style="font-size:.8rem">${u.sub}</code></td>
      <td><span class="badge ${u.enabled ? 'badge-enabled' : 'badge-disabled'}">${u.enabled ? 'Active' : 'Disabled'}</span></td>
      <td>${u.status}</td>
      <td>
        ${u.enabled
          ? `<button class="action-btn btn-disable" onclick="userAction('${u.sub}','disable')">Disable</button>`
          : `<button class="action-btn btn-enable" onclick="userAction('${u.sub}','enable')">Enable</button>`}
        <button class="action-btn btn-reset" onclick="userAction('${u.sub}','force_reset')">Reset Pwd</button>
      </td>
    </tr>`).join("");
}

async function userAction(sub, action) {
  if (!confirm(`${action} user ${sub}?`)) return;
  const { ok, data } = await apiCall(`/v1/admin/users/${sub}/action`, "POST", { action });
  showStatus(ok ? `Done: ${action} on ${sub}` : `Error: ${data.error || "unknown"}`);
  if (ok) loadUsers();
}

// --- Audit Log Panel ---
async function loadAuditLog() {
  const restaurantId = document.getElementById("audit-restaurant-id").value.trim();
  if (!restaurantId) { showStatus("Enter a restaurant ID first"); return; }
  const container = document.getElementById("audit-events");
  container.innerHTML = "<p>Loading...</p>";
  const { ok, data } = await apiCall(`/v1/admin/audit-log?restaurant_id=${encodeURIComponent(restaurantId)}`);
  if (!ok) { container.innerHTML = `<p>Error: ${data.error || "unknown"}</p>`; return; }
  if (!data.events || !data.events.length) { container.innerHTML = "<p>No events found.</p>"; return; }
  container.innerHTML = data.events.map(e => `
    <div class="event-card">
      <div><strong>${e.event_type || "rating_event"}</strong> — user <code>${(e.user_id || "").slice(0, 8)}…</code> scored <strong>${e.score}</strong></div>
      <div class="ts">${e.created_at || ""}</div>
    </div>`).join("");
}

// --- Tab switching ---
function switchTab(name) {
  document.querySelectorAll(".tab").forEach(t => t.classList.toggle("active", t.dataset.tab === name));
  document.querySelectorAll(".panel").forEach(p => p.classList.toggle("active", p.id === `panel-${name}`));
  if (name === "users") loadUsers();
}

// --- Logout ---
function logout() {
  sessionStorage.clear();
  const params = new URLSearchParams({ client_id: CONFIG.cognito_client_id, logout_uri: CONFIG.redirect_uri });
  window.location.href = `https://${CONFIG.cognito_domain}/logout?${params}`;
}

// --- Bootstrap ---
async function main() {
  try {
    await loadConfig();
  } catch {
    document.body.innerHTML = "<p style='padding:2rem'>Failed to load configuration. Check S3 deployment.</p>";
    return;
  }

  // Check for tokens in URL hash (post-login redirect)
  const tokens = parseHashTokens();
  if (tokens) {
    sessionStorage.setItem("access_token", tokens.accessToken);
    sessionStorage.setItem("id_token", tokens.idToken);
    // Strip tokens from URL to avoid accidental sharing/logging.
    history.replaceState(null, "", window.location.pathname);
  }

  ACCESS_TOKEN = sessionStorage.getItem("access_token");
  const idToken = sessionStorage.getItem("id_token");

  if (!ACCESS_TOKEN || !idToken) {
    redirectToLogin();
    return;
  }

  const claims = decodeJwtPayload(idToken);
  const groups = (claims && claims["cognito:groups"]) || [];
  if (!groups.includes("admin")) {
    document.body.innerHTML = `
      <div style="padding:3rem;text-align:center">
        <h2>Access Denied</h2>
        <p>You are not in the admin group.</p>
        <p style="margin-top:1rem;font-size:.85rem;color:#888">
          Sub: ${claims && claims.sub || "unknown"}<br>
          Groups: ${groups.join(", ") || "none"}
        </p>
      </div>`;
    return;
  }

  // Show the admin UI
  document.getElementById("admin-email").textContent = (claims && claims.email) || "admin";
  document.getElementById("app").style.display = "block";
  switchTab("users");
}

main();
