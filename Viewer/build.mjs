import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const viewerDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = path.resolve(viewerDirectory, '..');
const outputDirectory = path.join(viewerDirectory, 'dist');
const vendorDirectory = path.join(repositoryDirectory, 'node_modules');
const swaggerDirectory = path.join(vendorDirectory, 'swagger-ui-dist');
const yamlDirectory = path.join(vendorDirectory, 'yaml');

await mkdir(outputDirectory, { recursive: true });
await build({
  entryPoints: [path.join(viewerDirectory, 'src/viewer.js')],
  bundle: true,
  minify: true,
  format: 'iife',
  target: ['safari17'],
  outfile: path.join(outputDirectory, 'viewer.js'),
  legalComments: 'external',
});

const index = await readFile(path.join(viewerDirectory, 'index.html'), 'utf8');
await writeFile(path.join(outputDirectory, 'index.html'), index);

const notices = [
  ['swagger-ui-dist/LICENSE', 'Swagger UI - Apache License 2.0'],
  ['swagger-ui-dist/NOTICE', 'Swagger UI notice'],
  [
    'swagger-ui-dist/swagger-ui-es-bundle.js.LICENSE.txt',
    'Swagger UI bundled library licenses',
  ],
  ['yaml/LICENSE', 'yaml - ISC License'],
  ['jsonc-parser/LICENSE.md', 'jsonc-parser - MIT License'],
  ['licenses/normalize.css-LICENSE.md', 'normalize.css 7.0.0 - MIT License'],
  [
    'licenses/SWAGGER-UI-runtime-licenses.txt',
    'Swagger UI 5.34.1 runtime dependency licenses and notices',
  ],
];

const noticeParts = [];
for (const [relativePath, heading] of notices) {
  const source = relativePath.startsWith('yaml/')
    ? path.join(yamlDirectory, path.basename(relativePath))
    : relativePath.startsWith('jsonc-parser/')
      ? path.join(vendorDirectory, 'jsonc-parser', path.basename(relativePath))
      : relativePath.startsWith('licenses/')
        ? path.join(viewerDirectory, relativePath)
        : path.join(swaggerDirectory, path.basename(relativePath));
  const contents = await readFile(source, 'utf8');
  noticeParts.push(`${heading}\n${contents.trim()}`);
}
const esbuildLicense = await readFile(
  path.join(outputDirectory, 'viewer.js.LEGAL.txt'),
  'utf8',
);
noticeParts.push(
  `Bundled module notices emitted by esbuild\n${esbuildLicense.trim()}`,
);
await writeFile(
  path.join(outputDirectory, 'THIRD-PARTY-NOTICES.txt'),
  `${noticeParts.join('\n\n')}\n`,
);
await copyFile(
  path.join(viewerDirectory, 'viewer.css'),
  path.join(outputDirectory, 'viewer.css'),
);
await copyFile(
  path.join(swaggerDirectory, 'swagger-ui.css'),
  path.join(outputDirectory, 'swagger-ui.css'),
);
await copyFile(
  path.join(swaggerDirectory, 'favicon-32x32.png'),
  path.join(outputDirectory, 'favicon-32x32.png'),
);
