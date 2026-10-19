#!/usr/bin/env node
// Token amounts on the site must use each token's own decimals: real USDG has 6, the testnet mocks 18.
// This flags the hardcoded 18-decimal patterns that used to parse and format USDG amounts. Prices, rates
// and ETH legitimately stay at 18 and don't match these.
const fs = require('fs');
const path = require('path');

const rules = [
  ['public/js/carry-chain.js', /parseUnits\(raw, 18\)/, 'toWei must parse with the token decimals'],
  ['public/js/carry-chain.js', /convertToAssets', \[10n \*\* 24n\]/, 'share price probe must scale with USDG decimals'],
  ['public/js/carry-chain.js', /\bnum\(a\.(assets|amount|principal|seniorPrincipal|gross|toPosition|toBackstop|fromBackstop|mstrAmount|mstrSold|mstrKept|mstrReturned)\b/, 'event amounts must use usd() or stock()'],
  ['public/js/carry-chain.js', /const usd = \(v\) => num\(v, D\.usdg\)/, null],
  ['public/testnet.html', /const DEC = 18/, 'amounts must use DU / DS read from the tokens'],
  ['public/testnet.html', /fmtSmall = \(v\) => \{ const n = Number\(formatUnits\(v, 18\)\)/, 'fmtSmall must take the token decimals'],
  ['public/testnet.html', /\[DU, DS\] = await/, null],
];

const errors = [];
for (const [rel, re, msg] of rules) {
  const src = fs.readFileSync(path.join(__dirname, '..', rel), 'utf8');
  const hit = re.test(src);
  if (msg && hit) errors.push(`${rel}: ${msg} (${re})`);
  if (!msg && !hit) errors.push(`${rel}: expected ${re} (token decimals are no longer read)`);
}
if (errors.length) {
  console.error('Token decimals check failed:\n  ' + errors.join('\n  '));
  process.exit(1);
}
console.log('token decimals check ok');
