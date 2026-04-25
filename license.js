const crypto = require('crypto');
const https = require('https');

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://gormgyzofsyhtamwiwao.supabase.co';
const SUPABASE_KEY = process.env.SUPABASE_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdvcm1neXpvZnN5aHRhbXdpd2FvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQyODE2NjIsImV4cCI6MjA4OTg1NzY2Mn0.S6Yv05FKEBSvvGu4EL24o143jcR-Nor-GgfeBsQRnHs';
const TRIAL_DAYS = 7;
const STORAGE_KEY = 'license.json';

// ─────────────────────────────────────────────
// Machine ID — серійний номер Mac (незмінний)
// ─────────────────────────────────────────────
let _machineIdCache = null;
function getMachineId() {
  if (_machineIdCache) return _machineIdCache;
  try {
    const { execSync } = require('child_process');
    const serial = execSync(
      'ioreg -l | grep IOPlatformSerialNumber | head -1 | awk -F\\" \'{print $4}\'',
      { encoding: 'utf8', timeout: 3000 }
    ).trim();
    if (serial && serial.length > 4) {
      _machineIdCache = crypto.createHash('sha256').update(serial).digest('hex').slice(0, 16);
      return _machineIdCache;
    }
  } catch (e) {}
  const os = require('os');
  const fallback = [os.hostname(), os.platform(), os.arch()].join('|');
  _machineIdCache = crypto.createHash('sha256').update(fallback).digest('hex').slice(0, 16);
  return _machineIdCache;
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
      'POST',
      '/rest/v1/rpc/get_trial_info',
      { p_machine_id: machineId }
    );

    if (res.status !== 200 || !res.data || typeof res.data !== 'object') {
      return { started: false, active: false, expired: false, offline: true, error: 'No internet connection' };
    }
    return res.data;

  } catch (e) {
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

  try {
    const res = await supabaseRequest(
      'POST',
      '/rest/v1/rpc/activate_trial',
      { p_machine_id: machineId, p_trial_days: TRIAL_DAYS }
    );

    if (res.status !== 200 || !res.data || typeof res.data !== 'object') {
      return { ok: false, reason: 'No internet connection. Please connect to start your trial.' };
    }
    return res.data;

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
      'POST',
      '/rest/v1/rpc/validate_license',
      { p_key: key, p_machine_id: machineId }
    );

    if (res.status !== 200 || !res.data || typeof res.data !== 'object') {
      return { valid: false, reason: 'Could not connect to activation server. Check your internet connection.', offline: true };
    }
    return res.data;

  } catch (e) {
    return { valid: false, reason: 'Could not connect to activation server. Check your internet connection.', offline: true };
  }
}

// ─────────────────────────────────────────────
// HMAC sign / verify license.json
// Key is derived from machine_id + pepper, so the file
// cannot be copied to another Mac (signature won't match).
// ─────────────────────────────────────────────
const _SIG_PEPPER = 'eb-7f3c-licsig-v1';
function _sigKey() {
  return crypto.createHash('sha256').update(_SIG_PEPPER + getMachineId()).digest();
}
function signLicenseData(data) {
  const { sig: _ignore, ...rest } = data || {};
  const payload = JSON.stringify(rest);
  const sig = crypto.createHmac('sha256', _sigKey()).update(payload).digest('hex');
  return { ...rest, sig };
}
function verifyLicenseData(data) {
  if (!data || typeof data !== 'object' || !data.sig) return false;
  const { sig, ...rest } = data;
  const expected = crypto.createHmac('sha256', _sigKey())
    .update(JSON.stringify(rest)).digest('hex');
  // constant-time compare
  if (sig.length !== expected.length) return false;
  try { return crypto.timingSafeEqual(Buffer.from(sig, 'hex'), Buffer.from(expected, 'hex')); }
  catch { return false; }
}

module.exports = { validateKey, getMachineId, getTrialInfo, activateTrial, STORAGE_KEY, signLicenseData, verifyLicenseData };
