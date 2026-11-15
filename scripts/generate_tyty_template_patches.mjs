// Rebuild only the syntax edits for the pinned TYTY 0.6.6 background. The
// extension program is parsed, never executed. No npm dependency ships in iOS.
// Usage: node scripts/generate_tyty_template_patches.mjs WORKER_JS BABEL_DIR [OUTPUT]
// BABEL_DIR must contain @babel/core 8.1.2 and @babel/plugin-transform-template-literals 8.0.1.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const [worker, babelDirectory, output = 'Soulo/Resources/UserScripts/tyty-0.6.6-template-patches.json'] = process.argv.slice(2);
if (!worker || !babelDirectory) throw Error('Expected WORKER_JS BABEL_DIR [OUTPUT].');
const require = createRequire(path.resolve(babelDirectory, 'package.json'));
const core = require('@babel/core');
const plugin = require('@babel/plugin-transform-template-literals');
if (core.version !== '8.1.2' || require('@babel/plugin-transform-template-literals/package.json').version !== '8.0.1') {
  throw Error('Use Babel core 8.1.2 and the template-literals plugin 8.0.1 for reproducible edits.');
}
const source = fs.readFileSync(worker, 'utf8');
const originalSHA256 = crypto.createHash('sha256').update(source).digest('hex');
if (originalSHA256 !== '21877195d29dc57a97ab457684674bf9fd4ab50915eb7687919044d1360e1036') {
  throw Error('This generator only supports the original TYTY 0.6.6 worker.');
}
const options = { sourceType: 'script', babelrc: false, configFile: false };
const ast = core.parseSync(source, options);
const patches = [];
function visit(node) {
  if (!node || typeof node !== 'object') return;
  if (node.type === 'TaggedTemplateExpression') throw Error('Tagged templates need a separate adaptation.');
  if (node.type === 'TemplateLiteral') {
    const result = core.transformSync('(' + source.slice(node.start, node.end) + ')', {
      ...options, plugins: [plugin.default], comments: false, compact: true
    }).code;
    if (result.startsWith('var ')) throw Error('Unexpected declaration in template expression.');
    patches.push({ start: node.start, length: node.end - node.start, replacement: '(' + result.replace(/;$/, '') + ')' });
    return;
  }
  for (const [key, value] of Object.entries(node)) {
    if (['loc', 'extra', 'tokens', 'comments'].includes(key)) continue;
    if (Array.isArray(value)) value.forEach(visit);
    else if (value && typeof value === 'object') visit(value);
  }
}
visit(ast.program);
patches.sort((a, b) => b.start - a.start);
let transformed = source;
for (const patch of patches) {
  transformed = transformed.slice(0, patch.start) + patch.replacement + transformed.slice(patch.start + patch.length);
}
core.parseSync(transformed, options);
fs.writeFileSync(output, JSON.stringify({ originalSHA256, patches }));
process.stdout.write(`Generated ${patches.length} syntax edits.\n`);
