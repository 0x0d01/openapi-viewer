import js from '@eslint/js';

export default [
  {
    ignores: ['Viewer/dist/**', 'Viewer/node_modules/**'],
  },
  js.configs.recommended,
  {
    files: ['Viewer/**/*.js', 'Viewer/**/*.mjs', '*.js'],
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
      globals: {
        document: 'readonly',
        HTMLElement: 'readonly',
        window: 'readonly',
        process: 'readonly',
        URL: 'readonly',
        setTimeout: 'readonly',
        clearTimeout: 'readonly',
        requestAnimationFrame: 'readonly',
        MutationObserver: 'readonly',
      },
    },
    rules: {
      'no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
    },
  },
];
