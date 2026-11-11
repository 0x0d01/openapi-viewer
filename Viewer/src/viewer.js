import SwaggerUIBundle from 'swagger-ui-dist/swagger-ui-es-bundle.js';
import {
  createDocumentOutline,
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

function findOutlineTarget(target) {
  if (!target || !activeMount) return null;
  if (target.kind === 'info') {
    return activeMount.querySelector('.information-container');
  }
  if (target.kind === 'servers') {
    return activeMount.querySelector('.scheme-container');
  }
  if (target.kind === 'tag') {
    return [...activeMount.querySelectorAll('.opblock-tag')].find(
      (heading) => heading.dataset.tag === target.tag,
    );
  }
  if (target.kind === 'operation') {
    const section = [
      ...activeMount.querySelectorAll('.opblock-tag-section'),
    ].find(
      (candidate) =>
        candidate.querySelector('.opblock-tag')?.dataset.tag === target.tag,
    );
    return [...(section?.querySelectorAll('.opblock') ?? [])].find(
      (operation) =>
        operation
          .querySelector('.opblock-summary-method')
          ?.textContent.trim()
          .toLowerCase() === target.method &&
        operation.querySelector('.opblock-summary-path')?.textContent.trim() ===
          target.path,
    );
  }
  if (target.kind === 'schema') {
    return document.getElementById(`model-${target.name}`);
  }
  return null;
}

function updateOutlineOperationAvailability() {
  for (const button of document.querySelectorAll('.outline-operation')) {
    const operation = findOutlineTarget(button.outlineTarget);
    button.disabled =
      !operation ||
      operation.hidden ||
      operation.closest('.opblock-tag-section')?.hidden;
  }
}

function scrollToOutlineTarget(target) {
  const element = findOutlineTarget(target);
  if (!element) return;
  if (target.kind === 'operation') {
    const heading = element
      .closest('.opblock-tag-section')
      ?.querySelector('.opblock-tag');
    if (heading?.dataset.isOpen === 'false') heading.click();
  }
  const container = document.getElementById('swagger-ui');
  const scroll = () => {
    const top =
      element.getBoundingClientRect().top -
      container.getBoundingClientRect().top;
    container.scrollTo({
      top: container.scrollTop + top - 16,
      behavior: 'smooth',
    });
  };
  if (target.kind === 'operation') {
    requestAnimationFrame(() => requestAnimationFrame(scroll));
  } else {
    scroll();
  }
}

function renderOutline(spec) {
  const sidebar = document.getElementById('outline-sidebar');
  const tree = document.getElementById('outline-tree');
  const items = createDocumentOutline(spec);
  const createList = (nodes) => {
    const list = document.createElement('ul');
    for (const node of nodes) {
      const item = document.createElement('li');
      if (node.target) {
        const button = document.createElement('button');
        button.type = 'button';
        button.textContent = node.label;
        if (node.target.kind === 'operation') {
          button.classList.add('outline-operation');
          button.outlineTarget = node.target;
        }
        button.addEventListener('click', () =>
          scrollToOutlineTarget(node.target),
        );
        item.append(button);
      } else {
        const label = document.createElement('span');
        label.textContent = node.label;
        item.append(label);
      }
      if (node.children?.length) item.append(createList(node.children));
      list.append(item);
    }
    return list;
  };
  tree.replaceChildren(createList(items));
  sidebar.hidden = items.length === 0;
}

document.getElementById('outline-toggle').addEventListener('click', (event) => {
  const button = event.currentTarget;
  const expanded = button.getAttribute('aria-expanded') === 'true';
  button.setAttribute('aria-expanded', String(!expanded));
  button.setAttribute('aria-label', expanded ? 'Show outline' : 'Hide outline');
  button.title = expanded ? 'Show outline' : 'Hide outline';
  document
    .getElementById('viewer-shell')
    .classList.toggle('outline-collapsed', expanded);
});

function renderSpec(spec, { query }) {
  return new Promise((resolve, reject) => {
    const container = document.getElementById('swagger-ui');
    const mount = document.createElement('div');
    mount.id = `swagger-ui-mount-${++mountSequence}`;
    activeMount = mount;
    container.scrollTop = 0;
    document.getElementById('outline-tree').scrollTop = 0;
    renderOutline(spec);
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
  updateOutlineOperationAvailability();
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
    document.getElementById('outline-sidebar').hidden = true;
    document.getElementById('outline-tree').replaceChildren();
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
