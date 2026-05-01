#!/usr/bin/env node
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const SECRET = 'eb_secret_2024_dBSound'; // має збігатися з license.js!
const ISSUED_FILE = path.join(__dirname, 'issued_keys.json');

function generateKey(email = 'user', type = 'standard') {
  const timestamp = Date.now().toString(36).toUpperCase();
  const rand = crypto.randomBytes(4).toString('hex').toUpperCase();
  const payload = `${type}:${email}:${timestamp}:${rand}`;
  const hmac = crypto.createHmac('sha256', SECRET)
    .update(payload)
    .digest('hex')
    .toUpperCase()
    .slice(0, 16);
  const key = `EB1-${hmac.slice(0,4)}-${hmac.slice(4,8)}-${hmac.slice(8,12)}-${hmac.slice(12,16)}`;
  return { key, email, type, createdAt: new Date().toISOString() };
}

function saveKey(keyData) {
  let issued = [];
  try { issued = JSON.parse(fs.readFileSync(ISSUED_FILE, 'utf8')); } catch(e) {}
  // Store full key string for validation
  if (!issued.includes(keyData.key)) {
    issued.push(keyData.key);
    fs.writeFileSync(ISSUED_FILE, JSON.stringify(issued, null, 2));
  }
  // Also save details
  const detailsFile = path.join(__dirname, 'issued_keys_details.json');
  let details = [];
  try { details = JSON.parse(fs.readFileSync(detailsFile, 'utf8')); } catch(e) {}
  details.push(keyData);
  fs.writeFileSync(detailsFile, JSON.stringify(details, null, 2));
}

const email = process.argv[2] || 'user@example.com';
const type = process.argv[3] || 'standard';
const result = generateKey(email, type);
saveKey(result);

console.log('\n🎛  EasyBounce License Key Generator');
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log(`📧  Email:   ${email}`);
console.log(`📦  Type:    ${type}`);
console.log(`🔑  Key:     ${result.key}`);
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log(`✓  Saved to issued_keys.json\n`);

module.exports = { generateKey };
