#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { performance } = require('perf_hooks');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (!String(key).startsWith('--')) {
      continue;
    }

    const value = argv[i + 1];
    if (typeof value === 'undefined' || String(value).startsWith('--')) {
      args[key.slice(2)] = '1';
      continue;
    }

    args[key.slice(2)] = value;
    i += 1;
  }

  return args;
}

function hasOwn(input, name) {
  return Boolean(input) && Object.prototype.hasOwnProperty.call(input, name);
}

function resolveTemplateString(value, variables) {
  if (value === null || typeof value === 'undefined') {
    return value;
  }

  const text = String(value);
  if (!variables || !Object.keys(variables).length) {
    return text;
  }

  return text.replace(/\{\{([^}]+)\}\}/g, (_, rawToken) => {
    const token = String(rawToken || '');
    if (token.toLowerCase().startsWith('urlencode:')) {
      const key = token.slice('urlencode:'.length);
      if (hasOwn(variables, key)) {
        return encodeURIComponent(String(variables[key]));
      }
      return `{{${token}}}`;
    }

    if (hasOwn(variables, token)) {
      return String(variables[token]);
    }

    return `{{${token}}}`;
  });
}

function resolveTemplateStringArray(values, variables) {
  return (Array.isArray(values) ? values : []).map((value) => resolveTemplateString(value, variables));
}

function getValueByPath(input, pathValue) {
  if (!pathValue) {
    return input;
  }

  const segments = String(pathValue).split('.');
  let current = input;
  for (const segment of segments) {
    if (current === null || typeof current === 'undefined') {
      return null;
    }

    if (/^\d+$/.test(segment)) {
      const index = Number(segment);
      if (!Array.isArray(current) || index >= current.length) {
        return null;
      }
      current = current[index];
      continue;
    }

    if (!hasOwn(current, segment)) {
      return null;
    }
    current = current[segment];
  }

  return current;
}

function storeStepValues(variables, payload, saveAs, saveFrom, defaultSaveFrom) {
  if (!saveAs) {
    return;
  }

  if (typeof saveAs === 'string') {
    const pathValue = saveFrom || defaultSaveFrom || '';
    variables[saveAs] = getValueByPath(payload, pathValue);
    return;
  }

  for (const [name, pathValue] of Object.entries(saveAs)) {
    variables[name] = getValueByPath(payload, pathValue);
  }
}

function getSurfaceDepth(protocol, surface) {
  const normalized = surface || 'documented';
  const entry = (protocol.escalationLadder || []).find((item) => String(item.id) === String(normalized));
  return entry ? Number(entry.depth) : 0;
}

function getTaskSteps(task) {
  if (task.profiles && task.profiles.playwright && Array.isArray(task.profiles.playwright.steps)) {
    return task.profiles.playwright.steps;
  }
  if (Array.isArray(task.steps)) {
    return task.steps;
  }
  throw new Error(`Task ${task.id} does not declare Playwright steps.`);
}

function getCommandBudget(task, protocol) {
  if (hasOwn(task, 'commandBudget')) {
    return Number(task.commandBudget);
  }
  return Number(protocol.commandBudgetDefault || 12);
}

function getTimeBudgetMs(task, protocol) {
  if (hasOwn(task, 'timeBudgetMs')) {
    return Number(task.timeBudgetMs);
  }
  return Number(protocol.timeBudgetMsDefault || 90000);
}

function getStepCountsAsCommand(step) {
  if (hasOwn(step, 'countsAsCommand')) {
    return Boolean(step.countsAsCommand);
  }
  return !['switchTarget', 'snapshotFindRef'].includes(String(step.type));
}

function getStepCountsAsRefresh(step) {
  if (hasOwn(step, 'countsAsRefresh')) {
    return Boolean(step.countsAsRefresh);
  }
  return false;
}

function assertTextContains(actual, expected, contextLabel) {
  if (typeof actual !== 'string' || !actual.includes(expected)) {
    throw new Error(`${contextLabel} did not contain expected text: ${expected}`);
  }
}

function assertTextEquals(actual, expected, contextLabel) {
  if (String(actual) !== String(expected)) {
    throw new Error(`${contextLabel} was '${actual}' but expected '${expected}'.`);
  }
}

function assertQueryExpectation(result, expectation, contextLabel) {
  if (!expectation) {
    return;
  }

  if (
    Object.prototype.hasOwnProperty.call(expectation, 'returnedCountAtLeast') &&
    Number(result.returnedCount) < Number(expectation.returnedCountAtLeast)
  ) {
    throw new Error(`${contextLabel} returned ${result.returnedCount} rows; expected at least ${expectation.returnedCountAtLeast}.`);
  }
  if (
    Object.prototype.hasOwnProperty.call(expectation, 'matchedCountAtLeast') &&
    Number(result.matchedCount) < Number(expectation.matchedCountAtLeast)
  ) {
    throw new Error(`${contextLabel} matched ${result.matchedCount} rows; expected at least ${expectation.matchedCountAtLeast}.`);
  }
  if (
    Object.prototype.hasOwnProperty.call(expectation, 'visibleCountAtLeast') &&
    Number(result.visibleCount) < Number(expectation.visibleCountAtLeast)
  ) {
    throw new Error(`${contextLabel} exposed ${result.visibleCount} visible rows; expected at least ${expectation.visibleCountAtLeast}.`);
  }

  if (expectation.firstRow) {
    if (!result.rows.length) {
      throw new Error(`${contextLabel} returned no rows; expected a first row.`);
    }

    const actual = result.rows[0];
    for (const [fieldName, expectedValue] of Object.entries(expectation.firstRow)) {
      if (String(actual[fieldName]) !== String(expectedValue)) {
        throw new Error(`${contextLabel} field '${fieldName}' was '${actual[fieldName]}' but expected '${expectedValue}'.`);
      }
    }
  }
}

async function getPageForAlias(contextState, alias) {
  const resolvedAlias = alias || contextState.currentAlias;
  if (!resolvedAlias || !contextState.pages.has(resolvedAlias)) {
    throw new Error(`Unknown target alias: ${resolvedAlias || '<empty>'}`);
  }
  return {
    alias: resolvedAlias,
    page: contextState.pages.get(resolvedAlias)
  };
}

async function run() {
  const args = parseArgs(process.argv.slice(2));
  if (!args['task-file'] || !args['task-id']) {
    throw new Error('playwright-benchmark.js requires --task-file and --task-id.');
  }

  const taskFile = path.resolve(args['task-file']);
  const taskId = String(args['task-id']);
  const mode = String(args.mode || 'warm');
  const headless = String(args.headless || '1') === '1';
  const browserPath = args['browser-path'] ? path.resolve(args['browser-path']) : undefined;
  const playwrightModulePath = args['playwright-module-path']
    ? path.resolve(args['playwright-module-path'])
    : 'playwright';

  const manifest = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
  const protocol = manifest.protocol || {};
  const task = (manifest.tasks || []).find((candidate) => String(candidate.id) === taskId);
  if (!task) {
    throw new Error(`Unknown task id: ${taskId}`);
  }

  const steps = getTaskSteps(task);
  const commandBudget = getCommandBudget(task, protocol);
  const timeBudgetMs = getTimeBudgetMs(task, protocol);

  const { chromium } = require(playwrightModulePath);

  const startupStart = performance.now();
  const browser = await chromium.launch({
    headless,
    executablePath: browserPath
  });
  const context = await browser.newContext();
  const startupMs = Math.round((performance.now() - startupStart) * 1000) / 1000;

  const contextState = {
    pages: new Map(),
    currentAlias: '',
    variables: Object.create(null)
  };

  const result = {
    ok: false,
    tool: 'playwright',
    taskId: String(task.id),
    group: String(task.group || ''),
    mode,
    startupMs,
    taskMs: null,
    wallMs: null,
    finalUrl: null,
    error: null,
    steps: [],
    transcript: [],
    variables: {},
    commandCount: 0,
    contextRefreshCount: 0,
    maxEscalationDepth: 0,
    distinctSurfaces: [],
    escalationTrace: [],
    completedStepCount: 0,
    totalStepCount: steps.length
  };

  const taskStart = performance.now();

  try {
    for (let stepIndex = 0; stepIndex < steps.length; stepIndex += 1) {
      const step = steps[stepIndex];
      const stepType = String(step.type);
      const surface = String(step.surface || 'documented');
      const escalationDepth = getSurfaceDepth(protocol, surface);
      const countsAsCommand = getStepCountsAsCommand(step);
      const countsAsRefresh = getStepCountsAsRefresh(step);
      const targetAlias = resolveTemplateString(hasOwn(step, 'targetAlias') ? step.targetAlias : contextState.currentAlias, contextState.variables);

      if (countsAsCommand && (result.commandCount + 1) > commandBudget) {
        throw new Error(`Command budget exceeded before step ${stepIndex + 1}. Budget: ${commandBudget}`);
      }
      if ((performance.now() - taskStart) > timeBudgetMs) {
        throw new Error(`Time budget exceeded before step ${stepIndex + 1}. Budget: ${timeBudgetMs} ms`);
      }

      const stepRecord = {
        index: stepIndex + 1,
        type: stepType,
        targetAlias,
        surface,
        escalationDepth,
        countsAsCommand,
        countsAsRefresh,
        ok: false,
        elapsedMs: 0,
        toolCommand: '',
        commandArgs: []
      };

      const stepStart = performance.now();
      try {
        let payload = null;

        switch (stepType) {
          case 'navigate': {
            const aliasToStore = targetAlias || 'default';
            let page = contextState.pages.get(aliasToStore);
            if (!page) {
              page = await context.newPage();
              contextState.pages.set(aliasToStore, page);
            }

            const url = resolveTemplateString(step.url, contextState.variables);
            const timeout = Number(step.timeoutMs || 20000);
            await page.goto(url, {
              waitUntil: String(step.waitUntil || 'domcontentloaded'),
              timeout
            });

            contextState.currentAlias = aliasToStore;
            result.finalUrl = page.url();
            payload = {
              resolvedUrl: result.finalUrl,
              targetAlias: aliasToStore
            };
            storeStepValues(contextState.variables, payload, step.saveAs, step.saveFrom, '');
            stepRecord.toolCommand = 'page.goto';
            stepRecord.commandArgs = [url];
            break;
          }
          case 'switchTarget': {
            if (!targetAlias || !contextState.pages.has(targetAlias)) {
              throw new Error(`Unknown target alias: ${targetAlias || '<empty>'}`);
            }
            contextState.currentAlias = targetAlias;
            payload = { targetAlias };
            stepRecord.toolCommand = 'benchmark.switchTarget';
            break;
          }
          case 'waitFor': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.locator(selector).first().waitFor({ state: 'visible', timeout });
            payload = { resolvedUrl: page.url() };
            stepRecord.toolCommand = 'locator.waitFor(visible)';
            stepRecord.commandArgs = [selector];
            break;
          }
          case 'waitForAny': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selectors = resolveTemplateStringArray(step.selectors, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            const handle = await page.waitForFunction(
              (selectorList) => {
                const isVisible = (element) => {
                  if (!element || !element.isConnected) {
                    return false;
                  }
                  const style = window.getComputedStyle(element);
                  if (!style || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') {
                    return false;
                  }
                  if (parseFloat(style.opacity || '1') === 0) {
                    return false;
                  }
                  const rect = element.getBoundingClientRect();
                  return rect.width > 0 && rect.height > 0;
                };

                for (const selector of selectorList) {
                  const element = document.querySelector(selector);
                  if (isVisible(element)) {
                    return { matchedSelector: selector };
                  }
                }
                return false;
              },
              selectors,
              { timeout }
            );
            payload = await handle.jsonValue();
            await handle.dispose();
            stepRecord.toolCommand = 'page.waitForFunction(any-visible)';
            stepRecord.commandArgs = selectors;
            break;
          }
          case 'waitForGone': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.waitForFunction(
              (selectorValue) => {
                const isVisible = (element) => {
                  if (!element || !element.isConnected) {
                    return false;
                  }
                  const style = window.getComputedStyle(element);
                  if (!style || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') {
                    return false;
                  }
                  if (parseFloat(style.opacity || '1') === 0) {
                    return false;
                  }
                  const rect = element.getBoundingClientRect();
                  return rect.width > 0 && rect.height > 0;
                };

                return !Array.from(document.querySelectorAll(selectorValue)).some((element) => isVisible(element));
              },
              selector,
              { timeout }
            );
            payload = { resolvedUrl: page.url() };
            stepRecord.toolCommand = 'page.waitForFunction(gone)';
            stepRecord.commandArgs = [selector];
            break;
          }
          case 'waitForCount': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const rootSelector = hasOwn(step, 'root') ? resolveTemplateString(step.root, contextState.variables) : '';
            const timeout = Number(resolveTemplateString(hasOwn(step, 'timeoutMs') ? step.timeoutMs : 15000, contextState.variables));
            const minCount = Number(resolveTemplateString(hasOwn(step, 'minCount') ? step.minCount : 1, contextState.variables));
            const handle = await page.waitForFunction(
              ({ selectorValue, rootSelectorValue, minCountValue }) => {
                const root = rootSelectorValue ? document.querySelector(rootSelectorValue) : document;
                if (!root) {
                  return false;
                }
                const matchedCount = root.querySelectorAll(selectorValue).length;
                if (matchedCount >= minCountValue) {
                  return { matchedCount };
                }
                return false;
              },
              {
                selectorValue: selector,
                rootSelectorValue: rootSelector,
                minCountValue: minCount
              },
              { timeout }
            );
            payload = await handle.jsonValue();
            await handle.dispose();
            payload.actualCount = Number(payload.matchedCount || 0);
            payload.minCount = minCount;
            stepRecord.toolCommand = 'page.waitForFunction(count)';
            stepRecord.commandArgs = [selector, String(minCount)];
            break;
          }
          case 'waitForVisibleCount': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const rootSelector = hasOwn(step, 'root') ? resolveTemplateString(step.root, contextState.variables) : '';
            const timeout = Number(resolveTemplateString(hasOwn(step, 'timeoutMs') ? step.timeoutMs : 15000, contextState.variables));
            const minCount = Number(resolveTemplateString(hasOwn(step, 'minCount') ? step.minCount : 1, contextState.variables));
            const handle = await page.waitForFunction(
              ({ selectorValue, rootSelectorValue, minCountValue }) => {
                const isVisible = (element) => {
                  if (!element || !element.isConnected) {
                    return false;
                  }
                  const style = window.getComputedStyle(element);
                  if (!style || style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse') {
                    return false;
                  }
                  if (parseFloat(style.opacity || '1') === 0) {
                    return false;
                  }
                  const rect = element.getBoundingClientRect();
                  return rect.width > 0 && rect.height > 0;
                };

                const root = rootSelectorValue ? document.querySelector(rootSelectorValue) : document;
                if (!root) {
                  return null;
                }

                const nodes = Array.from(root.querySelectorAll(selectorValue));
                const visibleCount = nodes.filter((node) => isVisible(node)).length;
                if (visibleCount >= minCountValue) {
                  return {
                    matchedCount: nodes.length,
                    visibleCount
                  };
                }
                return null;
              },
              {
                selectorValue: selector,
                rootSelectorValue: rootSelector,
                minCountValue: minCount
              },
              { timeout }
            );
            payload = await handle.jsonValue();
            await handle.dispose();
            payload.actualCount = Number(payload.visibleCount || 0);
            payload.minCount = minCount;
            stepRecord.toolCommand = 'page.waitForFunction(visible-count)';
            stepRecord.commandArgs = [selector, String(minCount)];
            break;
          }
          case 'waitUntilJs': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const expression = resolveTemplateString(step.expression, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.waitForFunction(
              (source) => {
                try {
                  return Boolean((0, eval)(source));
                } catch (error) {
                  return false;
                }
              },
              expression,
              { timeout }
            );
            payload = { resolvedUrl: page.url() };
            result.finalUrl = page.url();
            stepRecord.toolCommand = 'page.waitForFunction(expression)';
            stepRecord.commandArgs = [expression];
            break;
          }
          case 'query': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const fields = resolveTemplateStringArray(step.fields, contextState.variables);
            const limit = Number(step.limit || 20);
            const rootSelector = hasOwn(step, 'root') ? resolveTemplateString(step.root, contextState.variables) : '';
            const visibleOnly = Boolean(hasOwn(step, 'visibleOnly') ? step.visibleOnly : false);
            const minCount = Number(resolveTemplateString(hasOwn(step, 'minCount') ? step.minCount : 0, contextState.variables));
            payload = await page.evaluate(
              ({ selectorValue, rootSelectorValue, fieldsValue, limitValue, visibleOnlyValue }) => {
                const isVisible = (element) => {
                  if (!element || !element.isConnected) {
                    return false;
                  }

                  const style = window.getComputedStyle(element);
                  if (!style) {
                    return false;
                  }
                  if (style.display === 'none') {
                    return false;
                  }
                  if (style.visibility === 'hidden' || style.visibility === 'collapse') {
                    return false;
                  }
                  if (parseFloat(style.opacity || '1') === 0) {
                    return false;
                  }
                  const rect = element.getBoundingClientRect();
                  return rect.width > 0 && rect.height > 0;
                };

                const readField = (element, field) => {
                  const normalized = String(field || '').toLowerCase();
                  if (normalized === 'text') {
                    const textValue = typeof element.innerText === 'string' ? element.innerText : element.textContent;
                    return textValue == null ? '' : String(textValue);
                  }
                  if (normalized === 'href') {
                    if (typeof element.href === 'string') {
                      return element.href;
                    }
                    return element.getAttribute ? element.getAttribute('href') : null;
                  }
                  if (normalized === 'tag') {
                    return element.tagName ? String(element.tagName).toLowerCase() : null;
                  }
                  if (normalized === 'html') {
                    return typeof element.innerHTML === 'string' ? element.innerHTML : null;
                  }
                  if (normalized === 'outer-html') {
                    return typeof element.outerHTML === 'string' ? element.outerHTML : null;
                  }
                  if (normalized === 'value') {
                    return 'value' in element ? element.value : null;
                  }
                  if (normalized === 'visible') {
                    return isVisible(element);
                  }
                  if (normalized.startsWith('attr:')) {
                    return element.getAttribute ? element.getAttribute(String(field).slice(5)) : null;
                  }
                  if (normalized.startsWith('prop:')) {
                    const propName = String(field).slice(5);
                    try {
                      const propValue = element[propName];
                      if (propValue == null) {
                        return propValue;
                      }
                      if (['string', 'number', 'boolean'].includes(typeof propValue)) {
                        return propValue;
                      }
                      return String(propValue);
                    } catch (error) {
                      return null;
                    }
                  }
                  return null;
                };

                const root = rootSelectorValue ? document.querySelector(rootSelectorValue) : document;
                if (!root) {
                  return {
                    ok: false,
                    code: 'ROOT_NOT_FOUND',
                    rootSelector: rootSelectorValue
                  };
                }

                const nodes = Array.from(root.querySelectorAll(selectorValue));
                const visibleNodes = nodes.filter((node) => isVisible(node));
                const sourceNodes = visibleOnlyValue ? visibleNodes : nodes;
                const rows = sourceNodes.slice(0, limitValue).map((node) => {
                  const row = {};
                  for (const field of fieldsValue) {
                    row[field] = readField(node, field);
                  }
                  return row;
                });
                return {
                  ok: true,
                  rootSelector: rootSelectorValue,
                  totalCount: nodes.length,
                  matchedCount: nodes.length,
                  visibleCount: visibleNodes.length,
                  returnedCount: rows.length,
                  returnedVisibleCount: visibleOnlyValue ? rows.length : Math.min(visibleNodes.length, rows.length),
                  visibleOnly: visibleOnlyValue,
                  rows
                };
              },
              {
                selectorValue: selector,
                rootSelectorValue: rootSelector,
                fieldsValue: fields,
                limitValue: limit,
                visibleOnlyValue: visibleOnly
              }
            );
            if (!payload.ok) {
              if (payload.code === 'ROOT_NOT_FOUND') {
                throw new Error(`query root selector did not match: ${payload.rootSelector}`);
              }
              throw new Error(`query failed for selector ${selector}`);
            }
            const actualCount = visibleOnly ? Number(payload.visibleCount || 0) : Number(payload.matchedCount || 0);
            if (minCount > 0 && actualCount < minCount) {
              throw new Error(
                `query step for task ${taskId} matched ${actualCount} rows for selector ${selector}; expected at least ${minCount}.`
              );
            }
            assertQueryExpectation(payload, step.expect, `query step for task ${taskId}`);
            storeStepValues(contextState.variables, payload, step.saveAs, step.saveFrom, '');
            stepRecord.toolCommand = 'page.evaluate(query)';
            stepRecord.commandArgs = [
              selector,
              fields.join(','),
              visibleOnly ? '--visible-only' : '--all',
              rootSelector || '<document>'
            ];
            break;
          }
          case 'getText': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(hasOwn(step, 'selector') ? step.selector : 'body', contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            const text = await page.locator(selector).first().innerText({ timeout });
            payload = { text };
            const expectIncludes = resolveTemplateString(hasOwn(step, 'expectIncludes') ? step.expectIncludes : null, contextState.variables);
            const expectEquals = resolveTemplateString(hasOwn(step, 'expectEquals') ? step.expectEquals : null, contextState.variables);
            if (expectIncludes) {
              assertTextContains(text, expectIncludes, `getText step for task ${taskId}`);
            }
            if (expectEquals) {
              assertTextEquals(text, expectEquals, `getText step for task ${taskId}`);
            }
            storeStepValues(contextState.variables, payload, step.saveAs, step.saveFrom, 'text');
            stepRecord.toolCommand = 'locator.innerText';
            stepRecord.commandArgs = [selector];
            break;
          }
          case 'type': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const text = resolveTemplateString(step.text, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.locator(selector).first().fill(text, { timeout });
            payload = { textLength: text.length };
            stepRecord.toolCommand = 'locator.fill';
            stepRecord.commandArgs = [selector, text];
            break;
          }
          case 'click': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = resolveTemplateString(step.selector, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.locator(selector).first().click({ timeout });
            result.finalUrl = page.url();
            payload = { resolvedUrl: result.finalUrl };
            stepRecord.toolCommand = 'locator.click';
            stepRecord.commandArgs = [selector];
            break;
          }
          case 'scroll': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const selector = hasOwn(step, 'selector') ? resolveTemplateString(step.selector, contextState.variables) : null;
            const container = hasOwn(step, 'container') ? resolveTemplateString(step.container, contextState.variables) : null;
            const behavior = String(step.behavior || 'auto');
            const block = String(step.block || 'center');
            const inlineMode = String(step.inline || 'nearest');
            const x = hasOwn(step, 'x') ? Number(step.x) : null;
            const y = hasOwn(step, 'y') ? Number(step.y) : null;
            const left = hasOwn(step, 'left') ? Number(step.left) : null;
            const top = hasOwn(step, 'top') ? Number(step.top) : null;
            payload = await page.evaluate(
              ({ selectorValue, containerValue, behaviorValue, blockValue, inlineValue, xValue, yValue, leftValue, topValue }) => {
                const flush = async () => {
                  await Promise.resolve();
                  await new Promise((resolve) => {
                    let done = false;
                    const finish = () => {
                      if (done) {
                        return;
                      }
                      done = true;
                      resolve();
                    };
                    try {
                      requestAnimationFrame(() => finish());
                    } catch (error) {
                      // Ignore.
                    }
                    setTimeout(finish, 32);
                  });
                };

                if (selectorValue) {
                  const element = document.querySelector(selectorValue);
                  if (!element) {
                    return { ok: false, reason: 'not_found' };
                  }
                  if (typeof element.scrollIntoView === 'function') {
                    element.scrollIntoView({ behavior: behaviorValue, block: blockValue, inline: inlineValue });
                  }
                  return flush().then(() => {
                    const rect = element.getBoundingClientRect();
                    return {
                      ok: true,
                      mode: 'element',
                      top: Math.round(rect.top),
                      left: Math.round(rect.left)
                    };
                  });
                }

                const containerNode = containerValue ? document.querySelector(containerValue) : null;
                if (containerValue && !containerNode) {
                  return { ok: false, reason: 'container_not_found' };
                }

                const target = containerNode || window;
                const targetKind = containerNode ? 'container' : 'page';
                const useDelta = xValue !== null || yValue !== null;

                if (useDelta) {
                  const deltaX = xValue === null ? 0 : xValue;
                  const deltaY = yValue === null ? 0 : yValue;
                  if (typeof target.scrollBy === 'function') {
                    target.scrollBy({ left: deltaX, top: deltaY, behavior: behaviorValue });
                  } else {
                    target.scrollLeft = (target.scrollLeft || 0) + deltaX;
                    target.scrollTop = (target.scrollTop || 0) + deltaY;
                  }
                } else {
                  const desiredLeft = leftValue === null
                    ? (targetKind === 'page' ? Math.round(window.scrollX || window.pageXOffset || 0) : Math.round(target.scrollLeft || 0))
                    : leftValue;
                  const desiredTop = topValue === null
                    ? (targetKind === 'page' ? Math.round(window.scrollY || window.pageYOffset || 0) : Math.round(target.scrollTop || 0))
                    : topValue;

                  if (typeof target.scrollTo === 'function') {
                    target.scrollTo({ left: desiredLeft, top: desiredTop, behavior: behaviorValue });
                  } else {
                    target.scrollLeft = desiredLeft;
                    target.scrollTop = desiredTop;
                  }
                }

                return flush().then(() => ({
                  ok: true,
                  mode: useDelta ? 'delta' : 'absolute',
                  targetKind,
                  scrollLeft: targetKind === 'page'
                    ? Math.round(window.scrollX || window.pageXOffset || 0)
                    : Math.round(target.scrollLeft || 0),
                  scrollTop: targetKind === 'page'
                    ? Math.round(window.scrollY || window.pageYOffset || 0)
                    : Math.round(target.scrollTop || 0)
                }));
              },
              {
                selectorValue: selector,
                containerValue: container,
                behaviorValue: behavior,
                blockValue: block,
                inlineValue: inlineMode,
                xValue: x,
                yValue: y,
                leftValue: left,
                topValue: top
              }
            );

            if (!payload || payload.ok === false) {
              if (payload && payload.reason === 'not_found') {
                throw new Error(`No element matched selector: ${selector}`);
              }
              if (payload && payload.reason === 'container_not_found') {
                throw new Error(`No scroll container matched selector: ${container}`);
              }
              throw new Error('scroll failed.');
            }
            stepRecord.toolCommand = 'page.evaluate(scroll)';
            stepRecord.commandArgs = [selector || '', container || ''];
            break;
          }
          case 'assertUrlIncludes': {
            const { page } = await getPageForAlias(contextState, targetAlias);
            const expected = resolveTemplateString(step.includes, contextState.variables);
            const timeout = Number(step.timeoutMs || 15000);
            await page.waitForFunction((value) => location.href.includes(value), expected, { timeout });
            result.finalUrl = page.url();
            payload = { resolvedUrl: result.finalUrl };
            stepRecord.toolCommand = 'page.waitForFunction(url)';
            stepRecord.commandArgs = [expected];
            break;
          }
          case 'snapshot':
          case 'snapshotFindRef':
            throw new Error(`Unsupported benchmark step type for Playwright: ${stepType}`);
          default:
            throw new Error(`Unsupported benchmark step type for Playwright: ${stepType}`);
        }

        stepRecord.ok = true;
        stepRecord.details = payload;
        result.steps.push(stepRecord);
        result.transcript.push(stepRecord);
        result.completedStepCount += 1;
        if (countsAsCommand) {
          result.commandCount += 1;
        }
        if (countsAsRefresh) {
          result.contextRefreshCount += 1;
        }
        if (escalationDepth > result.maxEscalationDepth) {
          result.maxEscalationDepth = escalationDepth;
        }
        if (!result.distinctSurfaces.includes(surface)) {
          result.distinctSurfaces.push(surface);
        }
        if (escalationDepth > 0) {
          result.escalationTrace.push({
            index: stepRecord.index,
            type: stepType,
            surface,
            escalationDepth
          });
        }
      } catch (error) {
        stepRecord.ok = false;
        stepRecord.error = String(error && error.message ? error.message : error);
        result.steps.push(stepRecord);
        result.transcript.push(stepRecord);
        throw error;
      } finally {
        stepRecord.elapsedMs = Math.round((performance.now() - stepStart) * 1000) / 1000;
      }
    }

    result.ok = true;
    result.taskMs = Math.round((performance.now() - taskStart) * 1000) / 1000;
    result.wallMs = mode === 'cold'
      ? Math.round((result.startupMs + result.taskMs) * 1000) / 1000
      : result.taskMs;
    result.variables = contextState.variables;
    if (contextState.currentAlias && contextState.pages.has(contextState.currentAlias)) {
      result.finalUrl = contextState.pages.get(contextState.currentAlias).url();
    }
  } catch (error) {
    result.ok = false;
    result.error = String(error && error.message ? error.message : error);
    result.taskMs = Math.round((performance.now() - taskStart) * 1000) / 1000;
    result.wallMs = mode === 'cold'
      ? Math.round((result.startupMs + result.taskMs) * 1000) / 1000
      : result.taskMs;
    result.variables = contextState.variables;
    if (contextState.currentAlias && contextState.pages.has(contextState.currentAlias)) {
      result.finalUrl = contextState.pages.get(contextState.currentAlias).url();
    }
  } finally {
    await browser.close();
  }

  process.stdout.write(`${JSON.stringify(result)}\n`);
  process.exit(result.ok ? 0 : 1);
}

run().catch((error) => {
  const payload = {
    ok: false,
    tool: 'playwright',
    error: String(error && error.message ? error.message : error),
    steps: [],
    transcript: []
  };
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  process.exit(1);
});
