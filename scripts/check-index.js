#!/usr/bin/env node
// Sanity-checks public/index.html before it ships. A bad bundle renders a black screen with no server-side error.
//   1. every __bundler/* payload parses as JSON (a literal </script> inside one ends the tag early)
//   2. the template HTML's text/x-dc logic script is valid JS
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const file = path.join(__dirname, '..', 'public', 'index.html');
const html = fs.readFileSync(file, 'utf8');
const errors = [];

const payloads = {};
const re = /<script type="__bundler\/([\w-]+)">([\s\S]*?)<\/script>/g;
let m;
while ((m = re.exec(html))) {
  try {
    payloads[m[1]] = JSON.parse(m[2]);
  } catch (e) {
    errors.push(`__bundler/${m[1]}: invalid JSON (${e.message})`);
  }
}
for (const k of ['manifest', 'template']) {
  if (!(k in payloads) && !errors.some(e => e.startsWith(`__bundler/${k}:`))) errors.push(`__bundler/${k}: missing`);
}

if (typeof payloads.template === 'string') {
  const sre = /<script([^>]*)>([\s\S]*?)<\/script>/g;
  let s, n = 0;
  while ((s = sre.exec(payloads.template))) {
    if (!/type="text\/x-dc"/.test(s[1]) || !s[2].trim()) continue;
    n++;
    try {
      new vm.Script(`(function(){${s[2]}\n})`, { filename: 'template logic script' });
    } catch (e) {
      errors.push(`template logic script #${n}: ${e.message}`);
    }
  }
  if (!n) errors.push('template: no text/x-dc logic script found');
}

if (errors.length) {
  console.error('public/index.html check FAILED:');
  for (const e of errors) console.error('  - ' + e);
  process.exit(1);
}
console.log('public/index.html check ok');
