import YAML from 'yaml';
import { parse as parseJsonForDiagnostics } from 'jsonc-parser';

const HTTP_METHODS = new Set([
  'get',
  'put',
  'post',
  'delete',
  'options',
  'head',
  'patch',
  'trace',
]);
const MAP_FIELDS = new Set([
  '$defs',
  'callbacks',
  'components',
  'content',
  'definitions',
  'dependentSchemas',
  'encoding',
  'examples',
  'headers',
  'links',
  'parameters',
  'pathItems',
  'paths',
  'patternProperties',
  'properties',
  'requestBodies',
  'responses',
  'schemas',
  'securitySchemes',
  'webhooks',
]);
const SCHEMA_MAPS = new Set([
  '$defs',
  'definitions',
  'dependentSchemas',
  'patternProperties',
  'properties',
  'schemas',
]);

function sourceLocation(error) {
  const linePos = error.linePos?.[0];
  if (!linePos) return {};
  return { line: linePos.line, column: linePos.col };
}

function parseFailure(text, error) {
  const jsonErrors = [];
  parseJsonForDiagnostics(text, jsonErrors, {
    allowTrailingComma: false,
    disallowComments: true,
    allowEmptyContent: false,
  });
  const position = jsonErrors[0]?.offset;
  let location = {};
  if (typeof position === 'number') {
    const priorLines = text.slice(0, position).split(/\r\n|\r|\n/);
    location = {
      line: priorLines.length,
      column: priorLines.at(-1).length + 1,
    };
  }
  return {
    ok: false,
    diagnostics: [
      {
        severity: 'error',
        message: `Invalid JSON: ${error.message}`,
        ...location,
      },
    ],
  };
}

function findExternalReference(
  value,
  seen = new WeakSet(),
  pointer = '',
  insideExamples = false,
  schemaContext = false,
  mapKind = '',
) {
  if (value && typeof value === 'object') {
    if (seen.has(value)) return null;
    seen.add(value);
  }
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findExternalReference(
        value[index],
        seen,
        `${pointer}/${index}`,
        insideExamples,
        schemaContext,
      );
      if (found) return found;
    }
    return null;
  }
  if (!value || typeof value !== 'object') return null;
  for (const [key, child] of Object.entries(value)) {
    const isMapEntry = Boolean(mapKind);
    const inSchema = schemaContext || key === 'schema' || SCHEMA_MAPS.has(key);
    const isExtension = !isMapEntry && key.startsWith('x-');
    const isLiteralExample = !isMapEntry && !schemaContext && key === 'example';
    const isSchemaLiteral =
      !isMapEntry &&
      schemaContext &&
      ['example', 'examples', 'default', 'const', 'enum'].includes(key);
    if (
      isExtension ||
      isLiteralExample ||
      isSchemaLiteral ||
      (insideExamples && key === 'value')
    )
      continue;
    const childPointer = `${pointer}/${key.replaceAll('~', '~0').replaceAll('/', '~1')}`;
    if (key === '$ref' && typeof child === 'string' && !child.startsWith('#')) {
      return { reference: child, pointer: childPointer };
    }
    const found = findExternalReference(
      child,
      seen,
      childPointer,
      insideExamples || (key === 'examples' && !schemaContext),
      inSchema,
      MAP_FIELDS.has(key) &&
        child &&
        typeof child === 'object' &&
        !Array.isArray(child)
        ? key
        : '',
    );
    if (found) return found;
  }
  return null;
}

function hasCycle(value, active = new WeakSet(), visited = new WeakSet()) {
  if (!value || typeof value !== 'object') return false;
  if (active.has(value)) return true;
  if (visited.has(value)) return false;
  active.add(value);
  for (const child of Object.values(value)) {
    if (hasCycle(child, active, visited)) return true;
  }
  active.delete(value);
  visited.add(value);
  return false;
}

function validateSpec(spec) {
  if (!spec || typeof spec !== 'object' || Array.isArray(spec)) {
    return 'The document root must be an OpenAPI object.';
  }
  if (typeof spec.openapi !== 'string') {
    return 'The document does not declare an OpenAPI version in the `openapi` field.';
  }
  if (!/^3\.[01](?:\.|$)/.test(spec.openapi)) {
    return `OpenAPI ${spec.openapi} is unsupported. This viewer supports OpenAPI 3.0 and 3.1.`;
  }
  if (!spec.info || typeof spec.info !== 'object' || Array.isArray(spec.info)) {
    return 'The OpenAPI document must contain an `info` object.';
  }
  const validPaths =
    spec.paths && typeof spec.paths === 'object' && !Array.isArray(spec.paths);
  const validWebhooks =
    spec.webhooks &&
    typeof spec.webhooks === 'object' &&
    !Array.isArray(spec.webhooks);
  const validComponents =
    spec.components &&
    typeof spec.components === 'object' &&
    !Array.isArray(spec.components);
  if (
    !validPaths &&
    !(spec.openapi.startsWith('3.1.') && (validWebhooks || validComponents))
  ) {
    return 'The OpenAPI document must contain a `paths` object or OpenAPI 3.1 `webhooks` or `components` object.';
  }
  return null;
}

export function parseSpec(text, format) {
  try {
    return parseSpecValue(text, format);
  } catch (error) {
    return {
      ok: false,
      diagnostics: [
        {
          severity: 'error',
          message: `Unable to parse the document: ${error.message}`,
        },
      ],
    };
  }
}

function parseSpecValue(text, format) {
  let spec;
  if (format === 'json') {
    try {
      spec = JSON.parse(text);
    } catch (error) {
      return parseFailure(text, error);
    }
  } else if (format === 'yaml') {
    const document = YAML.parseDocument(text, {
      prettyErrors: true,
      uniqueKeys: true,
      maxAliasCount: 100,
    });
    if (document.errors.length) {
      return {
        ok: false,
        diagnostics: document.errors.map((error) => ({
          severity: 'error',
          message: error.message,
          ...sourceLocation(error),
        })),
      };
    }
    try {
      spec = document.toJS({ maxAliasCount: 100 });
    } catch (error) {
      return {
        ok: false,
        diagnostics: [
          {
            severity: 'error',
            message: `Unable to read YAML: ${error.message}`,
          },
        ],
      };
    }
  } else {
    return {
      ok: false,
      diagnostics: [
        {
          severity: 'error',
          message: `Unsupported document format: ${format}.`,
        },
      ],
    };
  }

  const validationMessage = validateSpec(spec);
  if (validationMessage) {
    return {
      ok: false,
      diagnostics: [{ severity: 'error', message: validationMessage }],
    };
  }

  if (hasCycle(spec)) {
    return {
      ok: false,
      diagnostics: [
        {
          severity: 'error',
          message: 'Cyclic YAML aliases are unsupported in OpenAPI documents.',
        },
      ],
    };
  }

  const externalReference = findExternalReference(spec);
  if (externalReference) {
    return {
      ok: false,
      diagnostics: [
        {
          severity: 'error',
          message: `External reference "${externalReference.reference}" is blocked. Only internal references are supported.`,
        },
      ],
    };
  }

  return { ok: true, spec, diagnostics: [] };
}

export function matchesOperationText(values, query) {
  const normalizedQuery = query.trim().toLocaleLowerCase();
  if (!normalizedQuery) return true;
  const searchable = values
    .filter((value) => typeof value === 'string')
    .join('\n')
    .toLocaleLowerCase();
  return searchable.includes(normalizedQuery);
}

export function createInlineSpecBasePlugin(baseURL) {
  return {
    statePlugins: {
      spec: {
        wrapActions: {
          updateUrl: (originalAction) => (url) =>
            originalAction(url || baseURL),
        },
      },
    },
  };
}

export function countOperations(spec) {
  let operationCount = 0;
  for (const pathItem of Object.values(spec.paths ?? {})) {
    if (!pathItem || typeof pathItem !== 'object') continue;
    for (const method of Object.keys(pathItem)) {
      if (HTTP_METHODS.has(method.toLowerCase())) operationCount += 1;
    }
  }
  return operationCount;
}

export function createViewerBridge({
  parse,
  render,
  postMessage,
  clear = () => {},
  updateFilter = () => null,
  applyAppearance = () => {},
}) {
  let currentLoadID = null;
  let currentSpec = null;
  let filter = '';
  let appearance = 'light';

  async function renderCurrent(loadID) {
    if (loadID !== currentLoadID || !currentSpec) return;
    try {
      const rendering = await render(currentSpec, {
        loadID,
        appearance,
        query: filter,
      });
      if (loadID === currentLoadID) {
        postMessage({
          type: 'rendered',
          loadID,
          operationCount:
            rendering?.operationCount ?? countOperations(currentSpec),
        });
      }
    } catch (error) {
      if (loadID === currentLoadID) {
        postMessage({
          type: 'diagnostics',
          loadID,
          diagnostics: [
            {
              severity: 'error',
              message: `Unable to render the document: ${error.message}`,
            },
          ],
        });
      }
    }
  }

  return {
    async loadDocument({ loadID, text, format }) {
      currentLoadID = loadID;
      currentSpec = null;
      clear();
      let result;
      try {
        result = await parse(text, format);
      } catch (error) {
        result = {
          ok: false,
          diagnostics: [
            {
              severity: 'error',
              message: `Unable to parse the document: ${error.message}`,
            },
          ],
        };
      }
      if (loadID !== currentLoadID) return;
      if (!result.ok) {
        postMessage({
          type: 'diagnostics',
          loadID,
          diagnostics: result.diagnostics,
        });
        return;
      }
      currentSpec = result.spec;
      await renderCurrent(loadID);
    },
    async setFilter({ query }) {
      const nextFilter = String(query ?? '');
      if (nextFilter === filter) return;
      filter = nextFilter;
      if (!currentSpec) return;
      const loadID = currentLoadID;
      try {
        const operationCount = await updateFilter({ query: filter, loadID });
        if (loadID === currentLoadID && operationCount !== null) {
          postMessage({
            type: 'rendered',
            loadID,
            operationCount: operationCount ?? countOperations(currentSpec),
          });
        }
      } catch (error) {
        if (loadID === currentLoadID) {
          postMessage({
            type: 'diagnostics',
            loadID,
            diagnostics: [
              {
                severity: 'error',
                message: `Unable to filter the document: ${error.message}`,
              },
            ],
          });
        }
      }
    },
    setAppearance({ appearance: nextAppearance }) {
      appearance = nextAppearance;
      applyAppearance(appearance);
    },
  };
}
