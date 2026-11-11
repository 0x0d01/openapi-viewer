import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  countOperations,
  createDocumentOutline,
  createInlineSpecBasePlugin,
  createViewerBridge,
  matchesOperationText,
  parseSpec,
} from '../src/viewer-core.js';

async function fixture(name) {
  return readFile(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
}

test('parses nested YAML and resolves internal reference data for Swagger', async () => {
  const source = await fixture('nested-api.yaml');
  const parsed = parseSpec(source, 'yaml');

  assert.equal(parsed.ok, true);
  assert.equal(countOperations(parsed.spec), 2);
  assert.equal(
    parsed.spec.paths['/pets/{petId}'].get.responses['200'].content[
      'application/json'
    ].schema.$ref,
    '#/components/schemas/Pet',
  );
  assert.equal(
    parsed.spec.components.schemas.Pet.properties.owner.$ref,
    '#/components/schemas/Owner',
  );
});

test('passes unresolved path and component references intact to the Swagger renderer', async () => {
  const parsed = parseSpec(await fixture('path-item-references.yaml'), 'yaml');
  const messages = [];
  const filterQueries = [];
  const bridge = createViewerBridge({
    parse: () => parsed,
    render: async (spec, options) => {
      assert.strictEqual(spec, parsed.spec);
      assert.equal(spec.paths['/alias'].$ref, '#/paths/~1source');
      assert.equal(options.query, '');
      return { operationCount: 2 };
    },
    updateFilter: ({ query }) => {
      filterQueries.push(query);
      return 1;
    },
    postMessage: (message) => messages.push(message),
  });

  await bridge.loadDocument({ loadID: 'refs', text: '', format: 'yaml' });
  await bridge.setFilter({ query: 'inventory' });

  assert.deepEqual(filterQueries, ['inventory']);
  assert.deepEqual(
    messages
      .filter((message) => message.type === 'rendered')
      .map((message) => message.operationCount),
    [2, 1],
  );
});

test('parses equivalent JSON and YAML OpenAPI documents', async () => {
  const yamlParsed = parseSpec(await fixture('nested-api.yaml'), 'yaml');
  const jsonParsed = parseSpec(JSON.stringify(yamlParsed.spec), 'json');

  assert.equal(jsonParsed.ok, true);
  assert.deepEqual(jsonParsed.spec, yamlParsed.spec);
});

test('reports YAML and JSON syntax errors with source locations when available', async () => {
  const yamlParsed = parseSpec(
    'openapi: 3.0.3\ninfo:\n  title: [broken\n',
    'yaml',
  );
  const jsonParsed = parseSpec('{\n  "openapi": }', 'json');

  assert.equal(yamlParsed.ok, false);
  assert.equal(yamlParsed.diagnostics[0].severity, 'error');
  assert.equal(typeof yamlParsed.diagnostics[0].line, 'number');
  assert.equal(jsonParsed.ok, false);
  assert.equal(typeof jsonParsed.diagnostics[0].line, 'number');
  assert.match(jsonParsed.diagnostics[0].message, /Invalid JSON/);
});

test('rejects unsupported and malformed OpenAPI roots with useful messages', () => {
  const unsupported = parseSpec(
    'openapi: 2.0.0\ninfo: { title: API, version: 1 }\npaths: {}\n',
    'yaml',
  );
  const notSpec = parseSpec('title: Plain YAML\n', 'yaml');

  assert.match(
    unsupported.diagnostics[0].message,
    /supports OpenAPI 3.0 and 3.1/,
  );
  assert.match(
    notSpec.diagnostics[0].message,
    /does not declare an OpenAPI version/,
  );
});

test('rejects remote and relative references before Swagger receives them', async () => {
  const remote = parseSpec(await fixture('external-reference.yaml'), 'yaml');
  const relative = parseSpec(
    'openapi: 3.0.3\ninfo: { title: API, version: 1 }\npaths: {}\ncomponents: { schemas: { Pet: { $ref: "../common.yaml#/Pet" } } }\n',
    'yaml',
  );

  assert.match(remote.diagnostics[0].message, /External reference.*blocked/);
  assert.match(
    relative.diagnostics[0].message,
    /Only internal references are supported/,
  );
});

test('keeps reference-looking data in examples and extensions as user content', async () => {
  const parsed = parseSpec(
    await fixture('literal-reference-values.yaml'),
    'yaml',
  );

  assert.equal(parsed.ok, true);
  assert.equal(
    parsed.spec.paths['/item'].get.responses['200'].content['application/json']
      .example.$ref,
    'https://example.invalid/data',
  );
  assert.equal(
    parsed.spec.paths['/item'].get.responses['200'].content['application/json']
      .examples.sample.value.$ref,
    '../literal.json',
  );
});

test('blocks external references in schemas whose property names resemble data fields', () => {
  for (const property of [
    'example',
    'x-pet',
    'default',
    'enum',
    'const',
    'examples',
  ]) {
    const parsed = parseSpec(
      `openapi: 3.1.0\ninfo: { title: External Schema, version: 1 }\npaths: {}\ncomponents:\n  schemas:\n    Pet:\n      type: object\n      properties:\n        ${property}:\n          $ref: https://example.invalid/schema.json\n`,
      'yaml',
    );

    assert.equal(
      parsed.ok,
      false,
      `external reference under property ${property} should be blocked`,
    );
    assert.match(parsed.diagnostics[0].message, /External reference.*blocked/);
  }
});

test('treats schema component names and parameter examples as map data', () => {
  for (const schemaName of ['example', 'default', 'x-Pet']) {
    const parsed = parseSpec(
      `openapi: 3.1.0\ninfo: { title: External Schema, version: 1 }\npaths: {}\ncomponents:\n  schemas:\n    ${schemaName}:\n      $ref: https://example.invalid/schema.json\n`,
      'yaml',
    );

    assert.equal(
      parsed.ok,
      false,
      `external reference under schema ${schemaName} should be blocked`,
    );
    assert.match(parsed.diagnostics[0].message, /External reference.*blocked/);
  }

  const parameterExample = parseSpec(
    'openapi: 3.0.3\ninfo: { title: Literal Parameter, version: 1 }\npaths:\n  /items:\n    get:\n      parameters:\n        - name: filter\n          in: query\n          schema: { type: object }\n          example: { $ref: https://example.invalid/value }\n      responses: { "200": { description: OK } }\n',
    'yaml',
  );

  assert.equal(parameterExample.ok, true);
});

test('accepts OpenAPI 3.1 webhooks without a paths object', () => {
  const parsed = parseSpec(
    'openapi: 3.1.0\ninfo: { title: Webhook API, version: 1 }\nwebhooks: { event: { post: { responses: { "204": { description: Done } } } } }\n',
    'yaml',
  );

  assert.equal(parsed.ok, true);
  assert.equal(countOperations(parsed.spec), 0);
});

test('accepts OpenAPI 3.1 components-only documents', () => {
  const parsed = parseSpec(
    'openapi: 3.1.0\ninfo: { title: Reusable Schemas, version: 1 }\ncomponents: { schemas: { Pet: { type: object } } }\n',
    'yaml',
  );

  assert.equal(parsed.ok, true);
  assert.equal(parsed.spec.components.schemas.Pet.type, 'object');
});

test('rejects cyclic YAML aliases without overflowing traversal', () => {
  const parsed = parseSpec(
    'openapi: 3.1.0\ninfo: { title: Cyclic API, version: 1 }\npaths: {}\nx-cycle: &cycle\n  child: *cycle\n',
    'yaml',
  );

  assert.equal(parsed.ok, false);
  assert.match(parsed.diagnostics[0].message, /Cyclic YAML aliases/);
});

test('matches operation text across path, method, tag, and summary fields', () => {
  const operationText = ['/read-items', 'GET', 'readers', 'Fetch inventory'];

  for (const query of ['/read-items', 'get', 'READERS', 'inventory']) {
    assert.equal(matchesOperationText(operationText, query), true);
  }
  assert.equal(matchesOperationText(operationText, 'nothing'), false);
  assert.equal(matchesOperationText(operationText, '  '), true);
});

test('builds a hierarchical outline for tagged operations and schemas', async () => {
  const parsed = parseSpec(await fixture('nested-api.yaml'), 'yaml');
  const outline = createDocumentOutline(parsed.spec);

  assert.deepEqual(
    outline.map((node) => node.label),
    ['Shelter API', 'pets', 'Components'],
  );
  assert.deepEqual(outline[0], {
    label: 'Shelter API',
    target: { kind: 'info' },
  });
  assert.deepEqual(
    outline[1].children.map((node) => node.label),
    ['GET /pets/{petId}', 'POST /pets'],
  );
  assert.equal(outline[1].target.kind, 'tag');
  assert.deepEqual(outline[1].children[0].target, {
    kind: 'operation',
    tag: 'pets',
    method: 'get',
    path: '/pets/{petId}',
  });
  assert.equal(outline[2].children[0].label, 'Schemas');
  assert.deepEqual(
    outline[2].children[0].children.map((node) => node.label),
    ['PetId', 'Pet', 'Owner', 'Address'],
  );
});

test('groups untagged path operations under the default tag', () => {
  const parsed = parseSpec(
    'openapi: 3.0.3\ninfo: { title: API, version: 1 }\npaths:\n  /status:\n    get:\n      responses: { "200": { description: OK } }\n',
    'yaml',
  );

  assert.deepEqual(createDocumentOutline(parsed.spec), [
    {
      label: 'API',
      target: { kind: 'info' },
    },
    {
      label: 'default',
      target: { kind: 'tag', tag: 'default' },
      children: [
        {
          label: 'GET /status',
          target: {
            kind: 'operation',
            tag: 'default',
            method: 'get',
            path: '/status',
          },
        },
      ],
    },
  ]);
});

test('adds a navigable servers entry when servers are present', () => {
  const parsed = parseSpec(
    'openapi: 3.0.3\ninfo: { title: API, version: 1 }\nservers: [{ url: https://api.example.invalid }]\npaths: {}\n',
    'yaml',
  );

  assert.deepEqual(createDocumentOutline(parsed.spec), [
    { label: 'API', target: { kind: 'info' } },
    { label: 'Servers', target: { kind: 'servers' } },
  ]);
});

test('clears the previous rendering before reporting a failed new load', async () => {
  const messages = [];
  let clearCount = 0;
  const bridge = createViewerBridge({
    parse: () => ({
      ok: false,
      diagnostics: [{ severity: 'error', message: 'Bad source.' }],
    }),
    render: async () => assert.fail('invalid input should not render'),
    clear: () => {
      clearCount += 1;
    },
    postMessage: (message) => messages.push(message),
  });

  await bridge.loadDocument({ loadID: 'bad', text: '', format: 'yaml' });

  assert.equal(clearCount, 1);
  assert.equal(messages[0].type, 'diagnostics');
});

test('preserves quotes, backticks, and HTML-like source as data', () => {
  const text = `openapi: 3.0.3\ninfo:\n  title: 'Quote " and \\ backtick'\n  version: 1\n  description: "\`<script>alert(1)</script>\`"\npaths: {}\n`;
  const parsed = parseSpec(text, 'yaml');

  assert.equal(parsed.ok, true);
  assert.equal(parsed.spec.info.description, '`<script>alert(1)</script>`');
  assert.match(parsed.spec.info.title, /Quote/);
});

test('uses a synthetic resolver base only when the inline Swagger URL is empty', () => {
  const baseURL = 'https://openapi-viewer.invalid/openapi.json';
  const receivedURLs = [];
  const wrapUpdateUrl =
    createInlineSpecBasePlugin(baseURL).statePlugins.spec.wrapActions.updateUrl;
  const updateUrl = wrapUpdateUrl((url) => {
    receivedURLs.push(url);
    return url;
  });

  assert.equal(updateUrl(''), baseURL);
  assert.equal(
    updateUrl('https://docs.example.invalid/openapi.json'),
    'https://docs.example.invalid/openapi.json',
  );
  assert.deepEqual(receivedURLs, [
    baseURL,
    'https://docs.example.invalid/openapi.json',
  ]);
});

test('loads only the newest document when an earlier parse finishes late', async () => {
  let finishOldParse;
  const messages = [];
  const renderedIDs = [];
  const bridge = createViewerBridge({
    parse: async (text) =>
      text === 'old'
        ? new Promise((resolve) => {
            finishOldParse = () =>
              resolve({ ok: true, spec: { openapi: '3.1.0', paths: {} } });
          })
        : { ok: true, spec: { openapi: '3.1.0', paths: {} } },
    render: async (_spec, { loadID }) => renderedIDs.push(loadID),
    postMessage: (message) => messages.push(message),
  });

  const oldLoad = bridge.loadDocument({
    loadID: 'old-id',
    text: 'old',
    format: 'yaml',
  });
  const newLoad = bridge.loadDocument({
    loadID: 'new-id',
    text: 'new',
    format: 'yaml',
  });
  await newLoad;
  finishOldParse();
  await oldLoad;

  assert.deepEqual(renderedIDs, ['new-id']);
  assert.deepEqual(
    messages
      .filter((message) => message.type === 'rendered')
      .map((message) => message.loadID),
    ['new-id'],
  );
});

test('suppresses stale render completions and ignores unchanged filter values', async () => {
  const finishes = [];
  const messages = [];
  let renderCount = 0;
  const bridge = createViewerBridge({
    parse: () => ({
      ok: true,
      spec: { openapi: '3.1.0', paths: { '/x': { get: {} } } },
    }),
    render: () => {
      renderCount += 1;
      return new Promise((resolve) => finishes.push(resolve));
    },
    postMessage: (message) => messages.push(message),
  });

  const first = bridge.loadDocument({
    loadID: 'first',
    text: '',
    format: 'json',
  });
  await Promise.resolve();
  const second = bridge.loadDocument({
    loadID: 'second',
    text: '',
    format: 'json',
  });
  await Promise.resolve();
  finishes[0]();
  await first;
  finishes[1]();
  await second;
  await bridge.setFilter({ query: '' });

  assert.equal(renderCount, 2);
  assert.deepEqual(
    messages
      .filter((message) => message.type === 'rendered')
      .map((message) => message.loadID),
    ['second'],
  );
});

test('turns renderer failures into diagnostics for the current load', async () => {
  const messages = [];
  const bridge = createViewerBridge({
    parse: () => ({ ok: true, spec: { openapi: '3.1.0', paths: {} } }),
    render: async () => {
      throw new Error('renderer failure');
    },
    postMessage: (message) => messages.push(message),
  });

  await bridge.loadDocument({
    loadID: 'render-error',
    text: '',
    format: 'json',
  });

  assert.equal(messages[0].type, 'diagnostics');
  assert.equal(messages[0].loadID, 'render-error');
  assert.match(messages[0].diagnostics[0].message, /renderer failure/);
});

test('bundled viewer blocks network-capable resources and request execution', async () => {
  const html = await readFile(
    new URL('../index.html', import.meta.url),
    'utf8',
  );
  const source = await readFile(
    new URL('../src/viewer.js', import.meta.url),
    'utf8',
  );

  assert.match(html, /connect-src 'none'/);
  assert.match(html, /img-src 'self' data:/);
  assert.match(html, /font-src 'self' data:/);
  assert.match(source, /supportedSubmitMethods: \[\]/);
  assert.match(source, /validatorUrl: null/);
  assert.doesNotMatch(source, /fetch\s*\(/);
});

test('loads and filters the large nested fixture without losing references', async () => {
  const source = await fixture('large-nested.json');
  const parsed = parseSpec(source, 'json');
  const hasOwnerMatch = Object.entries(parsed.spec.paths).some(
    ([path, pathItem]) =>
      Object.entries(pathItem).some(([method, operation]) =>
        matchesOperationText(
          [path, method, operation.summary, ...(operation.tags ?? [])],
          'owner',
        ),
      ),
  );

  assert.equal(parsed.ok, true);
  assert.equal(countOperations(parsed.spec), 240);
  assert.equal(hasOwnerMatch, true);
  assert.equal(
    parsed.spec.components.schemas.Resource.properties.owner.$ref,
    '#/components/schemas/Owner',
  );
  assert.ok(source.length > 100_000);
});
