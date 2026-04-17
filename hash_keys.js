#!/usr/bin/env node
/**
 * Convert keys_pool.json to hashed version
 * Run once: node hash_keys.js
 */
const crypto = require('crypto');
const fs = require('fs');

const SECRET = 'eb_secret_2024_dBSound'; // має збігатись з license.js

function hashKey(key) {
  return crypto.createHmac('sha256', SECRET).update(key.trim().toUpperCase()).digest('hex');
}

const keys = JSON.parse(fs.readFileSync('./keys_pool.json', 'utf8'));
const hashed = keys.map(k => hashKey(k));

fs.writeFileSync('./keys_pool_hashed.json', JSON.stringify(hashed));
console.log(`✓ Hashed ${hashed.length} keys → keys_pool_hashed.json`);
