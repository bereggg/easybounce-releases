// ── EasyBounce Notifications — Telegram & Email ──────────────────────────────
const { app } = require('electron');
const path = require('path');
const fs = require('fs');

const SUPABASE_URL = 'https://gormgyzofsyhtamwiwao.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdvcm1neXpvZnN5aHRhbXdpd2FvIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzQyODE2NjIsImV4cCI6MjA4OTg1NzY2Mn0.S6Yv05FKEBSvvGu4EL24o143jcR-Nor-GgfeBsQRnHs';

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
  const res = await fetch(`${SUPABASE_URL}/functions/v1/telegram-proxy`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SUPABASE_ANON}` },
    body: JSON.stringify({ method, body: body || null }),
  });
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

        // Stop polling — no longer needed after connection (we only send, never receive)
        stopTelegramPolling();

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

  const hasErrors = (bounceData.errors || 0) > 0;
  const text = bounceData.failed
    ? `❌ <b>Bounce cancelled / failed!</b>\n` +
      `━━━━━━━━━━━━━━━━\n` +
      `📁 <b>${bounceData.project}</b>\n\n` +
      `⚠️ <b>Reason:</b> ${bounceData.failReason || 'Unknown error'}\n` +
      `🎚 Completed: <b>${bounceData.totalFiles}</b> of ${bounceData.totalPlanned || '?'}\n` +
      `⏱ Time: <b>${bounceData.duration}</b>\n` +
      (stemsLine ? `\n<b>Completed files:</b>\n${stemsLine}\n` : '') +
      `\n📂 <code>${bounceData.folder}</code>`
    : hasErrors
    ? `⚠️ <b>Bounce finished with errors!</b>\n` +
      `━━━━━━━━━━━━━━━━\n` +
      `📁 <b>${bounceData.project}</b>\n\n` +
      `🎚 Done: <b>${bounceData.totalFiles}</b> of ${bounceData.totalPlanned || '?'} — <b>${bounceData.errors} failed</b>\n` +
      `⏱ Time: <b>${bounceData.duration}</b>\n` +
      (bounceData.totalSize ? `💾 Size: <b>${bounceData.totalSize}</b>\n` : '') +
      (bounceData.format ? `🎵 Format: ${bounceData.format}\n` : '') +
      (stemsLine ? `\n<b>Completed:</b>\n${stemsLine}\n` : '') +
      `\n📂 <code>${bounceData.folder}</code>`
    : `✅ <b>Bounce complete!</b>\n` +
      `━━━━━━━━━━━━━━━━\n` +
      `📁 <b>${bounceData.project}</b>\n\n` +
      `🎚 Stems: <b>${bounceData.totalFiles}</b>` +
        (bounceData.totalPlanned ? ` of ${bounceData.totalPlanned}` : '') + `\n` +
      `⏱ Time: <b>${bounceData.duration}</b>\n` +
      (bounceData.totalSize ? `💾 Size: <b>${bounceData.totalSize}</b>\n` : '') +
      (bounceData.format ? `🎵 Format: ${bounceData.format}\n` : '') +
      `✔️ Errors: 0 — clean\n` +
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
    replyTo: 'support@easybounce.app',
    subject: bounceData.failed
      ? `❌ Bounce failed — ${bounceData.project}`
      : (bounceData.errors || 0) > 0
      ? `⚠️ Bounce errors — ${bounceData.project} (${bounceData.errors} failed)`
      : `✅ Bounce done — ${bounceData.project} (${bounceData.totalFiles} stems)`,
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
          ${bounceData.failed
            ? `<div style="font-size:22px;font-weight:700;color:#f0f0f0;">❌ Bounce failed — <span style="color:#f55;">${bounceData.project}</span></div>
               <div style="margin-top:10px;padding:12px 16px;background:#2a1010;border-radius:10px;border:1px solid #5a1a1a;color:#f88;font-size:13px;">⚠️ ${bounceData.failReason || 'Unknown error'}</div>`
            : `<div style="font-size:22px;font-weight:700;color:#f0f0f0;">Bounce complete — <span style="color:#1D9E75;">${bounceData.project}</span></div>`
          }
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
    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-email`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${SUPABASE_ANON}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(msg)
    });
    const data = await res.json();
    if (!data.ok) return { ok: false, error: data?.error || JSON.stringify(data) };
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message || 'unknown' };
  }
}

// ── Feedback form (Resend) ────────────────────────────────────────────────────
const FEEDBACK_TO = 'easybounce.app@gmail.com';

async function sendFeedback({ type, email, message, attachment }) {
  const subject = `[EasyBounce] ${type}${email ? ' from ' + email : ''}`;
  const safeMsg = (message || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/\n/g,'<br>');

  // Detect base type and rating
  const baseType = type.startsWith('Rating') ? 'Rating' : type;
  const ratingMatch = type.match(/\[(\d)\/5 — (.+)\]/);
  const ratingNum = ratingMatch ? parseInt(ratingMatch[1]) : 0;
  const ratingLabel = ratingMatch ? ratingMatch[2] : '';

  // Type config
  const typeConfig = {
    'Bug':        { emoji: '🐛', color: '#e53935', bg: '#fff5f5', badge: '#e53935', label: 'Bug Report' },
    'Question':   { emoji: '❓', color: '#1976d2', bg: '#f0f7ff', badge: '#1976d2', label: 'Question' },
    'Suggestion': { emoji: '💡', color: '#f57c00', bg: '#fff8f0', badge: '#f57c00', label: 'Suggestion' },
    'Rating':     { emoji: '⭐', color: '#6c63ff', bg: '#f5f4ff', badge: '#6c63ff', label: 'Rating' }
  };
  const cfg = typeConfig[baseType] || typeConfig['Bug'];

  // Stars HTML for rating
  const starsHtml = ratingNum > 0 ? `
    <table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 auto 6px;">
      <tr>${[1,2,3,4,5].map(i => `
        <td style="padding:0 2px;font-size:36px;line-height:1;color:${i <= ratingNum ? '#f5a623' : '#ddd'};">★</td>`).join('')}
      </tr>
    </table>
    <div style="text-align:center;font-size:15px;font-weight:600;color:#555;margin-bottom:16px;">${ratingLabel}</div>` : '';

  const html = `<!DOCTYPE html>
<html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f0f2f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f0f2f5;padding:32px 16px;">
<tr><td align="center">
<table role="presentation" width="600" cellpadding="0" cellspacing="0" style="max-width:600px;width:100%;">

  <!-- HEADER -->
  <tr><td style="background:linear-gradient(135deg,#1a1a2e 0%,#16213e 50%,#0f3460 100%);border-radius:16px 16px 0 0;padding:32px 40px 24px;text-align:center;">
    <div style="font-size:11px;font-weight:700;letter-spacing:.2em;text-transform:uppercase;color:rgba(255,255,255,.5);margin-bottom:8px;">EasyBounce</div>
    <div style="display:inline-block;background:${cfg.color};border-radius:50px;padding:8px 22px;margin-bottom:12px;">
      <span style="font-size:14px;font-weight:700;letter-spacing:.08em;text-transform:uppercase;color:#fff;">${cfg.emoji}&nbsp;&nbsp;${cfg.label}</span>
    </div>
    <div style="font-size:28px;font-weight:800;color:#fff;margin:0;line-height:1.2;">User Feedback</div>
  </td></tr>

  <!-- BODY -->
  <tr><td style="background:#fff;padding:0;">

    ${ratingNum > 0 ? `
    <!-- RATING SECTION -->
    <div style="background:${cfg.bg};border-left:4px solid ${cfg.color};padding:28px 40px;text-align:center;">
      ${starsHtml}
      <div style="font-size:12px;font-weight:700;letter-spacing:.1em;text-transform:uppercase;color:${cfg.color};">Rating: ${ratingNum} / 5</div>
    </div>` : ''}

    <!-- SENDER INFO -->
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="padding:28px 40px 0;">
      <tr>
        <td width="50%" style="vertical-align:top;padding-right:10px;">
          <div style="font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#999;margin-bottom:6px;">From</div>
          <div style="font-size:15px;font-weight:600;color:#222;">${email ? `<a href="mailto:${email}" style="color:#6c63ff;text-decoration:none;">${email}</a>` : '<span style="color:#aaa;font-style:italic;">Anonymous</span>'}</div>
        </td>
        <td width="50%" style="vertical-align:top;padding-left:10px;">
          <div style="font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#999;margin-bottom:6px;">Type</div>
          <div style="display:inline-block;background:${cfg.bg};border:1.5px solid ${cfg.color};border-radius:6px;padding:3px 12px;">
            <span style="font-size:13px;font-weight:700;color:${cfg.color};">${cfg.emoji} ${cfg.label}</span>
          </div>
        </td>
      </tr>
    </table>

    ${safeMsg ? `
    <!-- MESSAGE -->
    <div style="padding:24px 40px 32px;">
      <div style="font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#999;margin-bottom:10px;">Message</div>
      <div style="background:#fafafa;border:1px solid #e8e8e8;border-left:3px solid ${cfg.color};border-radius:8px;padding:20px 24px;font-size:15px;line-height:1.7;color:#333;">${safeMsg}</div>
    </div>` : `<div style="padding:24px 40px 32px;"><div style="font-size:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#999;margin-bottom:10px;">Message</div><div style="color:#bbb;font-style:italic;font-size:14px;">No message provided</div></div>`}

  </td></tr>

  <!-- QUICK REPLY BUTTON -->
  ${email ? `
  <tr><td style="background:#fff;padding:0 40px 32px;text-align:center;">
    <a href="mailto:${email}?subject=Re: ${encodeURIComponent(subject)}" style="display:inline-block;background:linear-gradient(135deg,#6c63ff,#5a52d5);color:#fff;font-size:14px;font-weight:700;letter-spacing:.04em;text-decoration:none;padding:14px 36px;border-radius:50px;box-shadow:0 4px 15px rgba(108,99,255,.35);">Reply to User →</a>
  </td></tr>` : ''}

  <!-- FOOTER -->
  <tr><td style="background:#f7f8fa;border-radius:0 0 16px 16px;padding:20px 40px;text-align:center;border-top:1px solid #eee;">
    <div style="font-size:11px;color:#bbb;">Sent via <b style="color:#6c63ff;">EasyBounce</b> in-app feedback &nbsp;·&nbsp; ${new Date().toLocaleDateString('en-US',{year:'numeric',month:'long',day:'numeric'})}</div>
  </td></tr>

</table>
</td></tr>
</table>
</body></html>`;

  const body = {
    from: 'EasyBounce <onboarding@resend.dev>',
    to: FEEDBACK_TO,
    subject,
    html,
    text: `Type: ${type}\nFrom: ${email || 'anonymous'}\n\n${message}`
  };
  if (email && email.includes('@')) body.reply_to = email;
  if (attachment) {
    body.attachments = [{
      content: attachment.base64,
      filename: attachment.name
    }];
  }

  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/send-email`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${SUPABASE_ANON}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body)
    });
    const data = await res.json();
    if (!data.ok) return { ok: false, error: data?.error || JSON.stringify(data) };
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
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
  sendBounceNotification,
  sendFeedback
};
