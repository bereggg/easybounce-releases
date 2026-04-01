// ── EasyBounce Notifications — Telegram & Email ──────────────────────────────
const { app } = require('electron');
const path = require('path');
const fs = require('fs');

const TELEGRAM_TOKEN = '8771970093:AAEcD5rMMTeMNxNllk4b5Edky4N4IJwGVA4';
const RESEND_KEY = 're_Xay9vsTs_6FtDMWroq7NVtp6bRjPu5Diq';

const settingsPath = () => path.join(app.getPath('userData'), 'notifications.json');

// ── Settings persistence ─────────────────────────────────────────────────────
function loadSettings() {
  try { return JSON.parse(fs.readFileSync(settingsPath(), 'utf8')); }
  catch { return {}; }
}

function saveSettings(data) {
  const current = loadSettings();
  const merged = { ...current, ...data };
  fs.writeFileSync(settingsPath(), JSON.stringify(merged, null, 2));
  return merged;
}

// ── Telegram ─────────────────────────────────────────────────────────────────
let _pollInterval = null;
let _lastUpdateId = 0;
const _pendingCodes = new Map(); // code → { created, onConnect }

function generateCode() {
  return Math.floor(10000 + Math.random() * 90000).toString();
}

async function telegramAPI(method, body) {
  const url = `https://api.telegram.org/bot${TELEGRAM_TOKEN}/${method}`;
  const opts = body ? {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  } : {};
  const res = await fetch(url, opts);
  return res.json();
}

async function sendTelegramMessage(chatId, text) {
  return telegramAPI('sendMessage', { chat_id: chatId, text, parse_mode: 'HTML' });
}

async function pollTelegramUpdates() {
  try {
    const data = await telegramAPI(`getUpdates?offset=${_lastUpdateId + 1}&timeout=3`);
    if (!data.ok || !data.result) return;

    for (const update of data.result) {
      _lastUpdateId = update.update_id;
      const msg = update.message;
      if (!msg || !msg.text) continue;

      const text = msg.text.trim();
      const chatId = msg.chat.id;

      // Check if user sent a pending connection code
      if (_pendingCodes.has(text)) {
        const entry = _pendingCodes.get(text);
        _pendingCodes.delete(text);

        // Save chat_id
        saveSettings({ telegramChatId: chatId, telegramConnected: true });

        // Confirm in Telegram
        await sendTelegramMessage(chatId,
          '✅ <b>EasyBounce connected!</b>\n\nYou will now receive bounce notifications here.'
        );

        // Notify renderer
        if (entry.onConnect) entry.onConnect(chatId);
      }

      // Handle /start command
      if (text === '/start') {
        await sendTelegramMessage(chatId,
          '👋 <b>Welcome to EasyBounce!</b>\n\n' +
          'Enter the 5-digit code from the EasyBounce app to connect.'
        );
      }
    }
  } catch (e) {
    // Silent fail — network issues shouldn't crash the app
  }
}

function startTelegramPolling() {
  if (_pollInterval) return;
  _pollInterval = setInterval(pollTelegramUpdates, 2500);
}

function stopTelegramPolling() {
  if (_pollInterval) { clearInterval(_pollInterval); _pollInterval = null; }
}

function registerPendingCode(code, onConnect) {
  _pendingCodes.set(code, { created: Date.now(), onConnect });
  // Auto-expire after 5 minutes
  setTimeout(() => { _pendingCodes.delete(code); }, 5 * 60 * 1000);
}

async function sendTelegramNotification(bounceData) {
  const settings = loadSettings();
  if (!settings.telegramChatId) return { ok: false, reason: 'not connected' };

  const errLine = bounceData.errors > 0
    ? `⚠️ Errors: ${bounceData.errors}\n`
    : `✔️ Errors: 0 — clean\n`;

  const stemsLine = (bounceData.stems && bounceData.stems.length > 0)
    ? bounceData.stems.slice(0, 8).map(s => `  • ${s.name}`).join('\n')
      + (bounceData.stems.length > 8 ? `\n  <i>+${bounceData.stems.length - 8} more</i>` : '')
    : '';

  const text =
    `✅ <b>Bounce complete!</b>\n` +
    `━━━━━━━━━━━━━━━━\n` +
    `📁 <b>${bounceData.project}</b>\n\n` +
    `🎚 Stems: <b>${bounceData.totalFiles}</b>` +
      (bounceData.totalPlanned ? ` of ${bounceData.totalPlanned}` : '') + `\n` +
    `⏱ Time: <b>${bounceData.duration}</b>\n` +
    (bounceData.totalSize ? `💾 Size: <b>${bounceData.totalSize}</b>\n` : '') +
    (bounceData.format ? `🎵 Format: ${bounceData.format}\n` : '') +
    errLine +
    (stemsLine ? `\n<b>Files:</b>\n${stemsLine}\n` : '') +
    `\n📂 <code>${bounceData.folder}</code>`;

  try {
    const result = await sendTelegramMessage(settings.telegramChatId, text);
    return { ok: result.ok };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ── Email (Resend via fetch) ───────────────────────────────────────────────────
async function sendEmailNotification(bounceData) {
  const settings = loadSettings();
  if (!settings.notificationEmail) return { ok: false, reason: 'no email' };

  const durationStr = bounceData.duration || '—';
  const errBadge = bounceData.errors > 0
    ? `<span style="color:#f55;font-weight:700;">${bounceData.errors} error(s)</span>`
    : `<span style="color:#1D9E75;font-weight:700;">0 — clean ✔</span>`;

  const stemsHtml = (bounceData.stems && bounceData.stems.length > 0)
    ? `<tr><td colspan="2" style="padding-top:14px;"></td></tr>
       <tr><td colspan="2" style="padding:4px 0 8px;color:#777;font-size:11px;font-weight:700;text-transform:uppercase;letter-spacing:.08em;border-top:1px solid #2a2a2a;">Files</td></tr>
       ${bounceData.stems.map(s =>
         `<tr><td colspan="2" style="padding:3px 0;font-size:12px;color:#bbb;">• ${s.name}</td></tr>`
       ).join('')}`
    : '';

  const msg = {
    to: settings.notificationEmail,
    from: 'EasyBounce <onboarding@resend.dev>',
    replyTo: 'easybounce.app@gmail.com',
    subject: `Bounce done — ${bounceData.project} (${bounceData.totalFiles} stems)`,
    text:
      `Bounce complete!\n\n` +
      `Project: ${bounceData.project}\n` +
      `Stems: ${bounceData.totalFiles}` + (bounceData.totalPlanned ? ` of ${bounceData.totalPlanned}` : '') + `\n` +
      `Time: ${durationStr}\n` +
      (bounceData.totalSize ? `Size: ${bounceData.totalSize}\n` : '') +
      (bounceData.format ? `Format: ${bounceData.format}\n` : '') +
      `Errors: ${bounceData.errors || 0}\n` +
      `Folder: ${bounceData.folder}`,
    html: `<!DOCTYPE html><html><body style="margin:0;padding:24px;background:#0f0f0f;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;">
      <div style="max-width:500px;margin:0 auto;">
        <div style="margin-bottom:18px;">
          <div style="font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#555;margin-bottom:6px;">EasyBounce</div>
          <div style="font-size:22px;font-weight:700;color:#f0f0f0;">Bounce complete — <span style="color:#1D9E75;">${bounceData.project}</span></div>
        </div>
        <table style="width:100%;border-collapse:separate;border-spacing:8px 8px;margin-bottom:16px;">
          <tr>
            <td style="background:#1a1a1a;border-radius:10px;padding:14px 16px;width:48%;">
              <div style="font-size:10px;color:#555;margin-bottom:6px;text-transform:uppercase;letter-spacing:.08em;">Stems done</div>
              <div style="font-size:28px;font-weight:700;color:#f0f0f0;line-height:1;">${bounceData.totalFiles}</div>
              <div style="font-size:11px;color:#555;margin-top:4px;">of ${bounceData.totalPlanned || bounceData.totalFiles} planned</div>
            </td>
            <td style="background:#1a1a1a;border-radius:10px;padding:14px 16px;width:48%;">
              <div style="font-size:10px;color:#555;margin-bottom:6px;text-transform:uppercase;letter-spacing:.08em;">Time</div>
              <div style="font-size:28px;font-weight:700;color:#f0f0f0;line-height:1;">${durationStr}</div>
              <div style="font-size:11px;color:#555;margin-top:4px;">min:sec</div>
            </td>
          </tr>
          <tr>
            <td style="background:#1a1a1a;border-radius:10px;padding:14px 16px;">
              <div style="font-size:10px;color:#555;margin-bottom:6px;text-transform:uppercase;letter-spacing:.08em;">Total size</div>
              <div style="font-size:24px;font-weight:700;color:#f0f0f0;line-height:1;">${bounceData.totalSize || '—'}</div>
              <div style="font-size:11px;color:#555;margin-top:4px;">${bounceData.format || ''}</div>
            </td>
            <td style="background:#1a1a1a;border-radius:10px;padding:14px 16px;">
              <div style="font-size:10px;color:#555;margin-bottom:6px;text-transform:uppercase;letter-spacing:.08em;">Errors</div>
              <div style="font-size:28px;font-weight:700;line-height:1;color:${(bounceData.errors||0) > 0 ? '#f55' : '#1D9E75'}">${bounceData.errors || 0}</div>
              <div style="font-size:11px;color:#555;margin-top:4px;">${(bounceData.errors||0) === 0 ? 'all clean' : 'check log'}</div>
            </td>
          </tr>
        </table>
        ${(bounceData.stems && bounceData.stems.length > 0) ? `
        <div style="background:#1a1a1a;border-radius:10px;padding:14px 16px;margin-bottom:8px;">
          ${bounceData.stems.map(s => `<div style="padding:5px 0;border-bottom:1px solid #222;font-size:12px;color:#bbb;">• ${s.name}</div>`).join('')}
        </div>` : ''}
        <div style="background:#1a1a1a;border-radius:10px;padding:12px 16px;font-family:monospace;font-size:11px;color:#555;word-break:break-all;">${bounceData.folder}</div>
      </div>
    </body></html>`
  };

  try {
    const res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${RESEND_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(msg)
    });
    const data = await res.json();
    if (!res.ok) return { ok: false, error: data?.message || JSON.stringify(data) };
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message || 'unknown' };
  }
}

// ── Combined: send all enabled notifications ─────────────────────────────────
async function sendBounceNotification(bounceData) {
  const settings = loadSettings();
  const results = {};

  if (settings.telegramChatId && settings.telegramEnabled !== false) {
    results.telegram = await sendTelegramNotification(bounceData);
  }
  if (settings.notificationEmail && settings.emailEnabled !== false) {
    results.email = await sendEmailNotification(bounceData);
  }

  return results;
}

module.exports = {
  loadSettings,
  saveSettings,
  generateCode,
  registerPendingCode,
  startTelegramPolling,
  stopTelegramPolling,
  sendTelegramNotification,
  sendEmailNotification,
  sendBounceNotification
};
