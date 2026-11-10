import SwaggerUIBundle from 'swagger-ui-dist/swagger-ui-es-bundle.js';
import {
  createInlineSpecBasePlugin,
  createViewerBridge,
  matchesOperationText,
  parseSpec,
} from './viewer-core.js';

const INLINE_SPEC_BASE = 'https://openapi-viewer.invalid/openapi.json';
let mountSequence = 0;
let activeMount = null;
let activeFilter = '';
let activeMountReady = false;
let operationObserver = null;

function renderSpec(spec, { query }) {
  return new Promise((resolve, reject) => {
    const container = document.getElementById('swagger-ui');
    const mount = document.createElement('div');
    mount.id = `swagger-ui-mount-${++mountSequence}`;
    activeMount = mount;
    activeFilter = query;
    activeMountReady = false;
    operationObserver?.disconnect();
    container.replaceChildren(mount);
    operationObserver = new MutationObserver(() => {
      if (activeMount === mount) applyOperationFilter(activeFilter, mount);
    });
    operationObserver.observe(mount, { childList: true, subtree: true });
    let settled = false;
    const timeout = setTimeout(() => {
      settled = true;
      reject(
        new Error('Swagger UI did not finish rendering within 20 seconds.'),
      );
    }, 20_000);
    try {
      SwaggerUIBundle({
        dom_id: `#${mount.id}`,
        spec,
        deepLinking: true,
        supportedSubmitMethods: [],
        validatorUrl: null,
        queryConfigEnabled: false,
        displayRequestDuration: false,
        plugins: [createInlineSpecBasePlugin(INLINE_SPEC_BASE)],
        onComplete: () => {
          requestAnimationFrame(() => {
            requestAnimationFrame(() => {
              if (settled) return;
              settled = true;
              clearTimeout(timeout);
              if (activeMount === mount) activeMountReady = true;
              resolve({
                operationCount:
                  activeMount === mount
                    ? applyOperationFilter(activeFilter, mount)
                    : 0,
              });
            });
          });
        },
      });
    } catch (error) {
      settled = true;
      clearTimeout(timeout);
      reject(error);
    }
  });
}

function applyOperationFilter(query, root = activeMount) {
  if (!root) return 0;
  const normalizedQuery = String(query ?? '')
    .trim()
    .toLocaleLowerCase();
  let operationCount = 0;
  for (const operation of root.querySelectorAll('.opblock')) {
    const section = operation.closest('.opblock-tag-section');
    const searchable = [
      operation.querySelector('.opblock-summary-path')?.textContent,
      operation.querySelector('.opblock-summary-method')?.textContent,
      operation.querySelector('.opblock-summary-description')?.textContent,
      section?.querySelector('.opblock-tag')?.textContent,
    ];
    operation.hidden = !matchesOperationText(searchable, normalizedQuery);
    if (!operation.hidden) operationCount += 1;
  }
  for (const section of root.querySelectorAll('.opblock-tag-section')) {
    const operations = [...section.querySelectorAll('.opblock')];
    const tagMatches = matchesOperationText(
      [section.querySelector('.opblock-tag')?.textContent],
      normalizedQuery,
    );
    section.hidden =
      normalizedQuery.length > 0 &&
      operations.length > 0 &&
      !operations.some((operation) => !operation.hidden) &&
      !tagMatches;
  }
  return operationCount;
}

const bridge = createViewerBridge({
  parse: parseSpec,
  render: renderSpec,
  postMessage: (message) =>
    window.webkit.messageHandlers.viewer.postMessage(message),
  clear: () => {
    activeMount = null;
    activeFilter = '';
    activeMountReady = false;
    operationObserver?.disconnect();
    operationObserver = null;
    document.getElementById('swagger-ui').replaceChildren();
  },
  updateFilter: ({ query }) => {
    activeFilter = query;
    if (!activeMountReady) return null;
    return applyOperationFilter(query);
  },
  applyAppearance: (appearance) => {
    document.documentElement.dataset.appearance = appearance;
    document.documentElement.classList.toggle(
      'dark-mode',
      appearance === 'dark',
    );
  },
});

window.viewerBridge = {
  loadDocument: (args) => bridge.loadDocument(args),
  setFilter: (args) => bridge.setFilter(args),
  setAppearance: (args) => bridge.setAppearance(args),
};

window.webkit.messageHandlers.viewer.postMessage({ type: 'ready' });
