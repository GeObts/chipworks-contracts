// Builds the Box audit package: audit/box-<date>/ with framed pastes, MANIFEST.md and SHA256SUMS,
// in the format the Morpho round used (audit/morpho-2026-09-16). Every file is copied LF-normalised
// and framed by BEGIN/END markers carrying its line count and SHA-256, so a reviewer can prove the
// paste arrived whole.
//
//   node tools/box/audit-pack.cjs <commit> [entropy-src.json]
//
// The optional entropy-src.json is the Basescan getsourcecode response for Pyth's Entropy
// implementation; the reference paste then carries Pyth's own revealWithCallback / structs / status
// constants, so the retryOpen reasoning can be checked against Pyth's code, not our description of it.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const ROOT = path.join(__dirname, '../..');
// The package folder: BOX_AUDIT_DIR, default round 2. Round 1 was audit/box-2026-09-23.
const PKG = path.join(ROOT, process.env.BOX_AUDIT_DIR || 'audit/box-2026-09-24');
const commit = process.argv[2];
if (!commit) throw new Error('usage: node tools/box/audit-pack.cjs <commit> [entropy-src.json]');

const lf = (s) => s.replace(/\r\n/g, '\n').replace(/\n?$/, '\n');
const put = (rel, text) => {
  const p = path.join(PKG, rel);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, lf(text));
};
const copy = (src, rel) => put(rel, fs.readFileSync(path.join(ROOT, src), 'utf8'));

// ---- the files --------------------------------------------------------------------------------
const P1 = [
  ['AUDIT_BRIEF.md', null],
  ['src/box/Box.sol', 'contracts/Box.sol'],
  ['src/box/PrizeVault.sol', 'contracts/PrizeVault.sol'],
  ['src/box/ChipConverter.sol', 'contracts/ChipConverter.sol'],
  ...['IBox', 'IPrizeVault', 'IChipConverter', 'IEntropyV2', 'IStockRegistry', 'ISwapRouters', 'IUniswapV4', 'IAggregatorV3']
    .map((n) => [`src/interfaces/${n}.sol`, `contracts/interfaces/${n}.sol`]),
];
const P2 = [
  ...['BoxRebuild.t.sol', 'BoxAuditPoC.t.sol', 'BoxVault.t.sol', 'Box.t.sol', 'BoxTestBase.sol'].map((n) => [`test/box/${n}`, `tests/${n}`]),
  ['test/box/BoxAuditRound1.t.sol', 'tests/BoxAuditRound1.t.sol'],
  [null, 'TRIAGE-ROUND1.md'],
  ['test/fork/BoxFork.t.sol', 'tests/BoxFork.t.sol'],
  ...['MockEntropyV2.sol', 'MockPoolManager.sol', 'MockStockRegistry.sol', 'MockSwapRouter.sol'].map((n) => [`test/mocks/${n}`, `tests/mocks/${n}`]),
  ['tools/box/box-callback-sim.cjs', 'gas/box-callback-sim.cjs'],
  ['tools/box/box-callback-sim.out.txt', 'gas/box-callback-sim.out.txt'],
];
const P3 = [['src/lottery/ChipLottery.sol', 'reference/ChipLottery.sol']];

for (const [src, rel] of [...P1, ...P2, ...P3]) if (rel && src) copy(src, rel);

// Pyth's own code, extracted from the verified implementation's sources.
if (process.argv[3]) {
  const j = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
  let src = j.result[0].SourceCode;
  if (src.startsWith('{{')) src = src.slice(1, -1);
  const files = JSON.parse(src).sources;
  const pick = (suffix) => Object.entries(files).find(([k]) => k.endsWith(suffix))[1].content;
  const entropy = pick('contracts/entropy/Entropy.sol');
  const start = entropy.indexOf('    function revealWithCallback(');
  const end = entropy.indexOf('\n    }\n', start) + 7;
  if (start < 0 || end < start) throw new Error('revealWithCallback not found in Entropy.sol');
  put('reference/pyth-entropy__revealWithCallback.excerpt.sol',
    `// EXCERPT from Pyth Entropy.sol, verified implementation 0x4ced698548f7d068f2f6e92d66f404a8a10db83b on Base.\n// Only revealWithCallback, verbatim. Full source: Basescan.\n\n${entropy.slice(start, end)}`);
  put('reference/pyth-entropy__EntropyStructsV2.sol', pick('EntropyStructsV2.sol'));
  put('reference/pyth-entropy__EntropyStatusConstants.sol', pick('EntropyStatusConstants.sol'));
  P3.push(['', 'reference/pyth-entropy__revealWithCallback.excerpt.sol'], ['', 'reference/pyth-entropy__EntropyStructsV2.sol'],
    ['', 'reference/pyth-entropy__EntropyStatusConstants.sol']);
}

// ---- framing ------------------------------------------------------------------------------------
const meta = (rel) => {
  const buf = fs.readFileSync(path.join(PKG, rel));
  const text = buf.toString('utf8');
  const lines = text.split('\n').length - 1;
  const last = text.trimEnd().split('\n').pop();
  return { rel, text, lines, sha: crypto.createHash('sha256').update(buf).digest('hex'), last };
};
const relOf = ([src, rel]) => rel || src; // [null, rel] = a file already in the package
const all = [];
const paste = (name, title, list) => {
  const ms = list.map((f) => meta(relOf(f)));
  all.push(...ms);
  let out = `CHIPWORKS BOX AUDIT PACKAGE - ${name}\nsource commit ${commit} (chipworks-contracts, branch box-rebuild). ${title} Files in this paste: ${ms.length}.\n`
    + 'Every file is framed by BEGIN/END markers stating its line count and SHA-256. The content between the\n'
    + 'marker lines is the file, byte for byte. If an END marker is missing, the paste was truncated: say so.\n\n'
    + ms.map((m, i) => `  ${i + 1}. ${m.rel}  (${m.lines} lines, sha256 ${m.sha})`).join('\n') + '\n\n';
  for (const m of ms) {
    out += `===== BEGIN FILE ${m.rel} | ${m.lines} lines | sha256 ${m.sha} =====\n${m.text}===== END FILE ${m.rel} =====\n\n`;
  }
  out += `===== END OF ${name}: ${ms.length} files. If you can read this line, nothing was cut off. =====\n`;
  fs.writeFileSync(path.join(PKG, name), out);
  console.log(`${name}: ${ms.length} files, ${out.length} chars`);
};
// Kept under ~75k characters each: a paste cut off in transit is the failure section 0 exists for.
paste('PASTE-1-brief-and-box.txt', 'Priority 1: the brief and Box.sol.', P1.slice(0, 2));
paste('PASTE-2-vault-converter-interfaces.txt', 'Priority 1: PrizeVault, ChipConverter and every interface.', P1.slice(2));
paste('PASTE-3-triage-and-rebuild-tests.txt', 'Round 1 triage, its verification tests, and the rebuild tests.', [P2[6], P2[5], P2[0]]);
paste('PASTE-4-poc-fork-and-gas.txt', 'The audit PoCs, the Base fork test, and the live-node gas simulation with its output.',
  [P2[1], P2[7], P2[12], P2[13]]);
paste('PASTE-5-remaining-tests-and-mocks.txt', 'The remaining unit tests, the shared fixture and the mocks.',
  [P2[2], P2[3], P2[4], P2[8], P2[9], P2[10], P2[11]]);
paste('PASTE-6-reference-optional.txt', 'Optional reference: the v4 swap pattern the converter follows, and Pyth\'s own Entropy code.', P3);

const seen = new Set();
const uniq = all.filter((m) => !seen.has(m.rel) && seen.add(m.rel));
fs.writeFileSync(path.join(PKG, 'SHA256SUMS'), uniq.map((m) => `${m.sha}  ${m.rel}`).join('\n') + '\n');
fs.writeFileSync(path.join(PKG, 'MANIFEST.md'), '# Manifest\n\nSHA-256 over the exact file bytes (UTF-8, LF, trailing newline included). Line count = number of newline-terminated lines.\n\n'
  + '| file | lines | sha256 | last non-empty line |\n|---|---|---|---|\n'
  + uniq.map((m) => `| ${m.rel} | ${m.lines} | ${m.sha} | \`${m.last.slice(0, 80).replace(/\|/g, '\\|')}\` |`).join('\n') + '\n');
fs.writeFileSync(path.join(PKG, '.gitattributes'), '* -text\n');
console.log(`manifest: ${uniq.length} files`);
