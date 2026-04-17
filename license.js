const crypto = require('crypto');
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://gormgyzofsyhtamwiwao.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdvcm1neXpvZnN5aHRhbXdpd2FvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQyODE2NjIsImV4cCI6MjA4OTg1NzY2Mn0.S6Yv05FKEBSvvGu4EL24o143jcR-Nor-GgfeBsQRnHs';
const TRIAL_DAYS = 7;
const STORAGE_KEY = 'license.json';

// ─────────────────────────────────────────────
// Machine ID — серійний номер Mac (незмінний)
// ─────────────────────────────────────────────
function getMachineId() {
  try {
    const { execSync } = require('child_process');
    const serial = execSync(
      'ioreg -l | grep IOPlatformSerialNumber | head -1 | awk -F\\" \'{print $4}\'',
      { encoding: 'utf8', timeout: 3000 }
    ).trim();
    if (serial && serial.length > 4) {
      return crypto.createHash('sha256').update(serial).digest('hex').slice(0, 16);
    }
  } catch (e) {}
  const os = require('os');
  const fallback = [os.hostname(), os.platform(), os.arch()].join('|');
  return crypto.createHash('sha256').update(fallback).digest('hex').slice(0, 16);
}

// ─────────────────────────────────────────────
// HTTP helper для Supabase
// ─────────────────────────────────────────────
function supabaseRequest(method, path, body) {
  return new Promise((resolve, reject) => {
    const bodyStr = body ? JSON.stringify(body) : null;
    const options = {
      hostname: 'gormgyzofsyhtamwiwao.supabase.co',
      path,
      method,
      headers: {
        'apikey': SUPABASE_KEY,
        'Authorization': `Bearer ${SUPABASE_KEY}`,
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
        ...(bodyStr ? { 'Content-Length': Buffer.byteLength(bodyStr) } : {})
      }
    };
    const req = https.request(options, res => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try { resolve({ status: res.statusCode, data: JSON.parse(data) }); }
        catch { resolve({ status: res.statusCode, data }); }
      });
    });
    req.on('error', reject);
    if (bodyStr) req.write(bodyStr);
    req.end();
  });
}

// ─────────────────────────────────────────────
// TRIAL — отримати інфо про тріал з Supabase
// ─────────────────────────────────────────────
async function getTrialInfo() {
  const machineId = getMachineId();

  try {
    const res = await supabaseRequest(
      'GET',
      `/rest/v1/trials?machine_id=eq.${encodeURIComponent(machineId)}&select=*`
    );

    // Немає запису — тріал не починався
    if (res.status !== 200 || !Array.isArray(res.data) || res.data.length === 0) {
      return { started: false, active: false, expired: false, daysRemaining: 0 };
    }

    const trial = res.data[0];
    const now = new Date();
    const expiresAt = new Date(trial.expires_at);
    const msRemaining = expiresAt - now;

    if (msRemaining > 0) {
      const daysRemaining = Math.ceil(msRemaining / (1000 * 60 * 60 * 24));
      return {
        started: true,
        active: true,
        expired: false,
        daysRemaining,
        expiresAt: trial.expires_at
      };
    } else {
      return {
        started: true,
        active: false,
        expired: true,
        daysRemaining: 0,
        expiresAt: trial.expires_at
      };
    }

  } catch (e) {
    // Немає інтернету — блокуємо
    return {
      started: false,
      active: false,
      expired: false,
      offline: true,
      error: 'No internet connection'
    };
  }
}

// ─────────────────────────────────────────────
// TRIAL — активувати тріал (тільки якщо ще не починався)
// ─────────────────────────────────────────────
async function activateTrial() {
  const machineId = getMachineId();

  // Спочатку перевіряємо чи вже є
  const existing = await getTrialInfo();

  if (existing.offline) {
    return { ok: false, reason: 'No internet connection. Please connect to start your trial.' };
  }

  if (existing.active) {
    return { ok: true, active: true, daysRemaining: existing.daysRemaining };
  }

  if (existing.expired) {
    return { ok: false, expired: true, reason: 'Trial expired. Purchase at easybounce.app' };
  }

  // Перший запуск — створюємо запис
  try {
    const now = new Date();
    const expiresAt = new Date(now.getTime() + TRIAL_DAYS * 24 * 60 * 60 * 1000);

    const res = await supabaseRequest(
      'POST',
      '/rest/v1/trials',
      {
        machine_id: machineId,
        started_at: now.toISOString(),
        expires_at: expiresAt.toISOString()
      }
    );

    if (res.status === 201 || res.status === 200) {
      return { ok: true, active: true, daysRemaining: TRIAL_DAYS };
    }

    // Якщо 409 — machine_id вже існує (race condition), просто читаємо
    if (res.status === 409) {
      const info = await getTrialInfo();
      if (info.active) return { ok: true, active: true, daysRemaining: info.daysRemaining };
      if (info.expired) return { ok: false, expired: true, reason: 'Trial expired. Purchase at easybounce.app' };
    }

    return { ok: false, reason: 'Could not start trial. Try again.' };

  } catch (e) {
    return { ok: false, reason: 'No internet connection. Please connect to start your trial.' };
  }
}

// ─────────────────────────────────────────────
// LICENSE — валідація ключа (без змін)
// ─────────────────────────────────────────────
async function validateKey(key) {
  if (!key || typeof key !== 'string') {
    return { valid: false, reason: 'No key provided' };
  }

  key = key.trim().toUpperCase();

  const oldFormat = /^EB1-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}-[A-F0-9]{4}$/.test(key);
  const newFormat = /^EB-[A-Z0-9][A-Z0-9\-]{2,31}$/.test(key);

  if (!oldFormat && !newFormat) {
    return { valid: false, reason: 'Invalid key format' };
  }

  const machineId = getMachineId();

  try {
    const res = await supabaseRequest(
      'GET',
      `/rest/v1/Licenses?license_key=eq.${encodeURIComponent(key)}&select=*`
    );

    if (res.status !== 200 || !Array.isArray(res.data) || res.data.length === 0) {
      return { valid: false, reason: 'Invalid license key. Purchase at easybounce.app' };
    }

    const license = res.data[0];

    if (license.license_type === 'subscription') {
      if (license.subscription_status !== 'active') {
        return { valid: false, reason: 'Your subscription is inactive. Renew at easybounce.app' };
      }
      if (license.subscription_end && new Date(license.subscription_end) < new Date()) {
        return { valid: false, reason: 'Your subscription has expired. Renew at easybounce.app' };
      }
    }

    if (license.machine_id && license.machine_id !== machineId) {
      return {
        valid: false,
        reason: 'This key is already activated on another Mac. Contact support: easybounce.app@gmail.com'
      };
    }

    if (!license.machine_id) {
      await supabaseRequest(
        'PATCH',
        `/rest/v1/Licenses?license_key=eq.${encodeURIComponent(key)}`,
        { machine_id: machineId, activated_at: new Date().toISOString() }
      );
    }

    // Повертаємо тип: 'lifetime' або 'subscription'
    const licenseType = (license.license_type === 'subscription') ? 'subscription' : 'lifetime';
    return { valid: true, email: license.email, licenseType };

  } catch (e) {
    return { valid: false, reason: 'Could not connect to activation server. Check your internet connection.', offline: true };
  }
}

module.exports = { validateKey, getMachineId, getTrialInfo, activateTrial, STORAGE_KEY };
