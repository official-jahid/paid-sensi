export default {
  async fetch(request, env) {
    return handleRequest(request, env);
  }
};

const CONFIG = {
  githubRawUrl: 'https://raw.githubusercontent.com/official-jahid/paid-sensi/main/main.ps1',
  youtubeVideoUrl: 'https://youtu.be/GVizJ_jpUnw?si=lbl9QKs9sX7jcrsp',
  licenseAuthApiUrl: 'https://licenseauth.help/api/1.3/',
};

const AUTH_DEFAULTS = { name: 'regix paid sensi', ownerId: 'RTgStl6UQK', version: '1.0' };

// Server-side ONLY fallback (used for /precheck). Prefer setting the
// REGIX_AUTH_SECRET worker secret instead. This is NEVER sent to the client.
const SERVER_SECRET_DEFAULT = 'bea0ec057fb51de71558e9b98af18a77c34aa4e43124670a0a79594d4c50a072';
// Optional token-validation file path. Empty = disabled.
const TOKEN_PATH_DEFAULT = '';

function getAuth(env) {
  const pick = (...vals) => {
    for (const v of vals) if (typeof v === 'string' && v.length > 0) return v;
    return '';
  };
  return {
    name: pick(env && env.REGIX_AUTH_NAME, AUTH_DEFAULTS.name),
    ownerId: pick(env && env.REGIX_AUTH_OWNER, AUTH_DEFAULTS.ownerId),
    version: pick(env && env.REGIX_AUTH_VERSION, AUTH_DEFAULTS.version),
    tokenPath: pick(env && env.REGIX_TOKEN_PATH, TOKEN_PATH_DEFAULT),
    serverSecret: pick(env && env.REGIX_AUTH_SECRET, env && env.REGIX_LICENSE_AUTH_SECRET, SERVER_SECRET_DEFAULT),
  };
}

function isPowerShell(request) {
  const ua = request.headers.get('user-agent') || '';
  return ua.includes('PowerShell') || ua.includes('WindowsPowerShell') || ua.includes('pwsh');
}

function escPs(value) {
  return String(value == null ? '' : value).replace(/'/g, "''");
}

function jsonResponse(obj, status) {
  return new Response(JSON.stringify(obj), {
    status: status || 200,
    headers: { 'content-type': 'application/json; charset=utf-8', 'Access-Control-Allow-Origin': '*' },
  });
}

function buildLauncherPs(auth, rawUrl) {
  const lines = [
    '#Requires -Version 5.1',
    '<# REGIX Studio secure launcher - served by Cloudflare worker (worker.js).',
    '   Downloads main.ps1 from GitHub raw, verifies the REGIX auth gate, runs it.',
    '   Auth menu inside main.ps1: [1] username + password | [2] licence key. #>',
    `$env:REGIX_AUTH_NAME = '${escPs(auth.name)}'`,
    `$env:REGIX_AUTH_OWNER = '${escPs(auth.ownerId)}'`,
    `$env:REGIX_AUTH_VERSION = '${escPs(auth.version)}'`,
    `$env:REGIX_TOKEN_PATH = '${escPs(auth.tokenPath)}'`,
    `$env:REGIX_PS1_URL = '${escPs(rawUrl)}'`,
    `$ErrorActionPreference = 'Stop'`,
    `try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }`,
    `$scriptUrl = $env:REGIX_PS1_URL`,
    `Write-Host ''`,
    `Write-Host '  REGIX Studio secure launcher' -ForegroundColor Cyan`,
    `Write-Host ('  Source: ' + $scriptUrl) -ForegroundColor DarkGray`,
    `Write-Host '  Menu: [1] username + password | [2] licence key' -ForegroundColor Yellow`,
    `try { $body = (Invoke-WebRequest -Uri $scriptUrl -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop).Content }`,
    `catch { Write-Host ('  Download failed: ' + $_.Exception.Message) -ForegroundColor Red; exit 1 }`,
    `if (-not $body -or $body -notmatch 'function Invoke-Authentication' -or $body -notmatch 'REGIX Studio') {`,
    `  Write-Host '  Downloaded file failed verification (REGIX auth gate missing) - aborting.' -ForegroundColor Red`,
    `  exit 1`,
    `}`,
    `$tmp = Join-Path $env:TEMP ('REGIX-Optimizer-' + [Guid]::NewGuid().ToString('N') + '.ps1')`,
    `Set-Content -LiteralPath $tmp -Value $body -Encoding UTF8`,
    `& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmp @args`,
    `$code = $LASTEXITCODE`,
    `Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue`,
    `exit $code`,
    '',
  ];
  return lines.join('\r\n');
}

async function precheckLicenseKey(auth, key, hwid) {
  if (!auth.serverSecret || !auth.name || !auth.ownerId || !key) return null;
  const uuid = (typeof crypto !== 'undefined' && crypto.randomUUID) ? crypto.randomUUID() : 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
  const sentKey = String(uuid).replace(/-/g, '').slice(0, 16);
  const initParams = new URLSearchParams({
    type: 'init', ver: auth.version, hash: '', enckey: sentKey, name: auth.name, ownerid: auth.ownerId,
  });
  try {
    const initRes = await fetch(CONFIG.licenseAuthApiUrl, { method: 'POST', body: initParams });
    const initJson = await initRes.json();
    if (!initJson || !initJson.success || !initJson.sessionid) return { ok: false, message: (initJson && initJson.message) || 'init failed' };
    const licParams = new URLSearchParams({
      type: 'license', key: String(key), hwid: String(hwid || ''),
      sessionid: String(initJson.sessionid), name: auth.name, ownerid: auth.ownerId,
    });
    const licRes = await fetch(CONFIG.licenseAuthApiUrl, { method: 'POST', body: licParams });
    const licJson = await licRes.json();
    if (licJson && licJson.success) return { ok: true, message: String(licJson.message || 'valid') };
    return { ok: false, message: (licJson && licJson.message) || 'invalid key' };
  } catch (err) {
    return { ok: false, message: 'auth service unreachable' };
  }
}

async function handleRequest(request, env) {
  const url = new URL(request.url);
  const auth = getAuth(env);
  const rawUrl = (env && env.REGIX_PS1_URL) || CONFIG.githubRawUrl;

  if (request.method === 'OPTIONS') {
    return new Response(null, {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Access-Control-Allow-Headers': '*',
      },
    });
  }

  if (url.pathname === '/health') return jsonResponse({ ok: true, service: 'regix-studio-launcher' });

  if (url.pathname === '/config') {
    return jsonResponse({ name: auth.name, ownerId: auth.ownerId, version: auth.version, tokenPath: auth.tokenPath, source: rawUrl, authModes: ['1:username-password', '2:licence-key'] });
  }

  if (url.pathname === '/precheck' && request.method === 'POST') {
    let body = {};
    try { body = await request.json(); } catch (e) { body = {}; }
    const result = await precheckLicenseKey(auth, body.key, body.hwid);
    if (!result) return jsonResponse({ ok: false, message: 'server auth not configured' }, 501);
    return jsonResponse(result, result.ok ? 200 : 401);
  }

  if (isPowerShell(request)) {
    const ps = buildLauncherPs(auth, rawUrl);
    return new Response(ps, {
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'no-store',
      },
    });
  }

  return Response.redirect(CONFIG.youtubeVideoUrl, 302);
}

addEventListener('fetch', (event) => {
  event.respondWith(handleRequest(event.request, event.env || {}));
});
