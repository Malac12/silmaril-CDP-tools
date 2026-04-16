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

function assertTextContains(actual, expected, contextLabel) {
  if (typeof actual !== 'string' || !actual.includes(expected)) {
    throw new Error(`${contextLabel} did not contain expected text: ${expected}`);
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

  if (expectation.firstRow) {
    if (!result.rows.length) {
      throw new Error(`${contextLabel} returned no rows; expected a first row.`);
    }

    const actual = result.rows[0];
    for (const [fieldName, expectedValue] of Object.entries(expectation.firstRow)) {
      const actualValue = actual[fieldName];
      if (String(actualValue) !== String(expectedValue)) {
        throw new Error(`${contextLabel} field '${fieldName}' was '${actualValue}' but expected '${expectedValue}'.`);
      }
    }
  }
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

  const manifest = JSON.parse(fs.readFileSync(taskFile, 'utf8'));
  const task = (manifest.tasks || []).find((candidate) => String(candidate.id) === taskId);
  if (!task) {
    throw new Error(`Unknown task id: ${taskId}`);
  }

  const { chromium } = require('playwright');

  const startupStart = performance.now();
  const browser = await chromium.launch({
    headless,
    executablePath: browserPath
  });
  const context = await browser.newContext();
  const page = await context.newPage();
  const startupMs = Math.round((performance.now() - startupStart) * 1000) / 1000;

  const result = {
    ok: false,
    tool: 'playwright',
    taskId: String(task.id),
    tier: String(task.tier),
    mode,
    startupMs,
    taskMs: null,
    wallMs: null,
    finalUrl: null,
    error: null,
    steps: []
  };

  const taskStart = performance.now();
  try {
    for (const step of task.steps || []) {
      const stepStart = performance.now();
      const stepRecord = {
        type: String(step.type),
        selector: Object.prototype.hasOwnProperty.call(step, 'selector') ? String(step.selector) : null,
        ok: false,
        elapsedMs: 0
      };

      try {
        switch (String(step.type)) {
          case 'navigate': {
            await page.goto(String(step.url), {
              waitUntil: String(step.waitUntil || 'domcontentloaded'),
              timeout: Number(step.timeoutMs || 15000)
            });
            result.finalUrl = page.url();
            stepRecord.details = {
              resolvedUrl: result.finalUrl
            };
            break;
          }
          case 'waitFor': {
            await page.locator(String(step.selector)).first().waitFor({
              state: 'visible',
              timeout: Number(step.timeoutMs || 15000)
            });
            stepRecord.details = {
              resolvedUrl: page.url()
            };
            break;
          }
          case 'waitForGone': {
            await page.locator(String(step.selector)).first().waitFor({
              state: 'hidden',
              timeout: Number(step.timeoutMs || 15000)
            });
            stepRecord.details = {
              resolvedUrl: page.url()
            };
            break;
          }
          case 'waitUntilJs': {
            const expression = String(step.expression);
            await page.waitForFunction(
              (source) => {
                try {
                  return Boolean((0, eval)(source));
                } catch (error) {
                  return false;
                }
              },
              expression,
              {
                timeout: Number(step.timeoutMs || 15000)
              }
            );
            result.finalUrl = page.url();
            stepRecord.details = {
              resolvedUrl: result.finalUrl
            };
            break;
          }
          case 'query': {
            const payload = await page.evaluate(
              ({ selector, fields, limit }) => {
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
                  const f = String(field || '');
                  const lower = f.toLowerCase();
                  if (lower === 'text') {
                    const textValue = typeof element.innerText === 'string' ? element.innerText : element.textContent;
                    return textValue == null ? '' : String(textValue);
                  }

                  if (lower === 'href') {
                    if (typeof element.href === 'string') {
                      return element.href;
                    }
                    return element.getAttribute ? element.getAttribute('href') : null;
                  }

                  if (lower === 'html') {
                    return typeof element.innerHTML === 'string' ? element.innerHTML : null;
                  }

                  if (lower === 'outer-html') {
                    return typeof element.outerHTML === 'string' ? element.outerHTML : null;
                  }

                  if (lower === 'tag') {
                    return element.tagName ? String(element.tagName).toLowerCase() : null;
                  }

                  if (lower === 'value') {
                    return 'value' in element ? element.value : null;
                  }

                  if (lower === 'visible') {
                    return isVisible(element);
                  }

                  if (lower.startsWith('attr:')) {
                    const attrName = f.slice(5);
                    return element.getAttribute ? element.getAttribute(attrName) : null;
                  }

                  if (lower.startsWith('prop:')) {
                    const propName = f.slice(5);
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

                const nodes = Array.from(document.querySelectorAll(selector)).slice(0, limit);
                const rows = nodes.map((node) => {
                  const row = {};
                  for (const field of fields) {
                    row[field] = readField(node, field);
                  }
                  return row;
                });
                return {
                  returnedCount: rows.length,
                  rows
                };
              },
              {
                selector: String(step.selector),
                fields: Array.isArray(step.fields) ? step.fields : [],
                limit: Number(step.limit || 20)
              }
            );
            assertQueryExpectation(payload, step.expect, `query step for task ${taskId}`);
            stepRecord.details = payload;
            break;
          }
          case 'type': {
            await page.locator(String(step.selector)).first().fill(String(step.text), {
              timeout: Number(step.timeoutMs || 15000)
            });
            stepRecord.details = {
              textLength: String(step.text).length
            };
            break;
          }
          case 'click': {
            await page.locator(String(step.selector)).first().click({
              timeout: Number(step.timeoutMs || 15000)
            });
            result.finalUrl = page.url();
            stepRecord.details = {
              resolvedUrl: result.finalUrl
            };
            break;
          }
          case 'assertTextIncludes': {
            const selector = step.selector ? String(step.selector) : 'body';
            const text = await page.locator(selector).first().innerText({
              timeout: Number(step.timeoutMs || 15000)
            });
            assertTextContains(text, String(step.includes), `text assertion for task ${taskId}`);
            stepRecord.details = {
              textLength: text.length
            };
            break;
          }
          default:
            throw new Error(`Unsupported benchmark step type for Playwright: ${step.type}`);
        }

        stepRecord.ok = true;
      } catch (error) {
        stepRecord.ok = false;
        stepRecord.error = String(error && error.message ? error.message : error);
        throw error;
      } finally {
        stepRecord.elapsedMs = Math.round((performance.now() - stepStart) * 1000) / 1000;
        result.steps.push(stepRecord);
      }
    }

    result.ok = true;
    result.taskMs = Math.round((performance.now() - taskStart) * 1000) / 1000;
    result.wallMs = mode === 'cold'
      ? Math.round((result.startupMs + result.taskMs) * 1000) / 1000
      : result.taskMs;
    result.finalUrl = page.url();
  } catch (error) {
    result.ok = false;
    result.error = String(error && error.message ? error.message : error);
    result.taskMs = Math.round((performance.now() - taskStart) * 1000) / 1000;
    result.wallMs = mode === 'cold'
      ? Math.round((result.startupMs + result.taskMs) * 1000) / 1000
      : result.taskMs;
    result.finalUrl = page.url();
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
    steps: []
  };
  process.stdout.write(`${JSON.stringify(payload)}\n`);
  process.exit(1);
});
