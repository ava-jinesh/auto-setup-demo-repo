const fs = require('node:fs');
const path = require('node:path');

const rootDir = path.resolve(__dirname, '..');
const outputDir = path.join(rootDir, 'dist');

fs.rmSync(outputDir, { recursive: true, force: true });
fs.mkdirSync(outputDir, { recursive: true });
fs.copyFileSync(path.join(rootDir, 'package.json'), path.join(outputDir, 'package.json'));
fs.copyFileSync(path.join(rootDir, 'server.js'), path.join(outputDir, 'server.js'));
fs.cpSync(path.join(rootDir, 'public'), path.join(outputDir, 'public'), { recursive: true });

console.log(`Build output created at ${outputDir}`);