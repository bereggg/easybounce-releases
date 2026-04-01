#!/usr/bin/env node
/**
 * Generate 1000 EasyBounce keys at once
 * Run: node generate_bulk.js
 * Output: keys_pool.json (embed in app) + keys_for_you.json (your copy)
 */
const crypto = require('crypto');
const fs = require('fs');

const SECRET = 'eb_secret_2024_dBSound'; // змін на свій!
const COUNT = 1000;

function generateKey(index) {
  const rand = crypto.randomBytes(6).toString('hex').toUpperCase();
  const payload = `EB1:${index}:${rand}:${SECRET}`;
  const hash = crypto.createHmac('sha256', SECRET)
    .update(payload)
    .digest('hex')
    .toUpperCase()
    .slice(0, 16);
  return `EB1-${hash.slice(0,4)}-${hash.slice(4,8)}-${hash.slice(8,12)}-${hash.slice(12,16)}`;
}

console.log(`\n🎛  Generating ${COUNT} EasyBounce keys...`);

const keys = [];
for (let i = 0; i < COUNT; i++) {
  keys.push(generateKey(i));
}

// Save pool for embedding in app (just the keys array)
fs.writeFileSync('keys_pool.json', JSON.stringify(keys, null, 2));

// Save tracking sheet for you (with status)
const tracking = keys.map((key, i) => ({
  index: i + 1,
  key,
  status: 'available',
  email: null,
  assignedAt: null
}));
fs.writeFileSync('keys_tracking.json', JSON.stringify(tracking, null, 2));

console.log(`✓ Generated ${COUNT} keys`);
console.log(`✓ keys_pool.json — embed this in your app`);
console.log(`✓ keys_tracking.json — your master list, assign keys to buyers here`);
console.log(`\nFirst 3 keys preview:`);
keys.slice(0, 3).forEach((k, i) => console.log(`  ${i+1}. ${k}`));
console.log('');
