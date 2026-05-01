#!/usr/bin/env node
/**
 * Assign next available key to a buyer
 * Run: node assign_key.js "buyer@email.com"
 */
const fs = require('fs');

const trackingFile = './keys_tracking.json';
const email = process.argv[2];

if (!email) {
  console.log('Usage: node assign_key.js "buyer@email.com"');
  process.exit(1);
}

const tracking = JSON.parse(fs.readFileSync(trackingFile, 'utf8'));
const available = tracking.find(k => k.status === 'available');

if (!available) {
  console.log('❌ No available keys! Generate more with: node generate_bulk.js');
  process.exit(1);
}

available.status = 'assigned';
available.email = email;
available.assignedAt = new Date().toISOString();

fs.writeFileSync(trackingFile, JSON.stringify(tracking, null, 2));

const remaining = tracking.filter(k => k.status === 'available').length;

console.log('\n🎛  EasyBounce Key Assignment');
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log(`📧  Email:     ${email}`);
console.log(`🔑  Key:       ${available.key}`);
console.log(`📦  Remaining: ${remaining} keys left`);
console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
console.log('\nSend this key to your customer!\n');
