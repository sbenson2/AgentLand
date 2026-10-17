const { chromium } = require('~/.npm/_npx/81bbc6515d992ace/node_modules/playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

async function check() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1100, height: 1300 } });
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  const output = path.resolve(__dirname);
  const goHome = async () => {
    await page.locator('[data-open-work]').click();
    await page.locator('[data-explorer-tab="workspaces"]').click();
    await page.locator('[data-pick="home"]').click();
  };
  try {
    await page.goto('http://127.0.0.1:8769');
    await page.locator('.native-scene img').first().waitFor();
    await page.evaluate(() => Promise.all([...document.images].map(image => image.decode().catch(() => {}))));
    assert.deepEqual(await page.locator('.selected-home [data-action]').allTextContents(),
      ['New Chat', 'New Terminal', 'New Workspace', 'Resume Workspace']);
    const bounds = await page.locator('[data-home-actions]').boundingBox();
    await page.locator('[data-action="New Chat"]').click();
    await page.locator('[data-home-choice="chat:codex"]').waitFor();
    assert.equal(await page.locator('[data-sheet]').isHidden(), true);
    assert.equal(await page.locator('[data-explorer]').isHidden(), true);
    const optionBounds = await page.locator('[data-home-actions]').boundingBox();
    assert.equal(optionBounds.y, bounds.y);
    assert.equal(optionBounds.height, bounds.height);
    await page.locator('.phone').screenshot({ path: path.join(output, 'home-chat-options.png') });
    await page.keyboard.press('Escape');
    await page.locator('[data-action="New Chat"]').waitFor();
    await page.waitForFunction(() => !document.querySelector('[data-home-actions]').hasAttribute('aria-busy'));
    assert.equal(await page.locator('[data-action="New Chat"]').evaluate(node => node === document.activeElement), true);
    await page.locator('.home-context').click();
    await page.locator('.phone').screenshot({ path: path.join(output, 'home-four-actions.png') });
    const geometry = await page.evaluate(() => {
      const grid = document.querySelector('.selected-home .action-grid').getBoundingClientRect();
      const content = document.querySelector('.content-slot').getBoundingClientRect();
      const view = document.querySelector('[data-view]');
      return { bottomGap: content.bottom - grid.bottom, scrollHeight: view.scrollHeight, clientHeight: view.clientHeight };
    });
    assert.ok(geometry.bottomGap >= 70 && geometry.bottomGap <= 86, JSON.stringify(geometry));
    assert.equal(geometry.scrollHeight, geometry.clientHeight);

    await page.locator('[data-action="New Terminal"]').click();
    await page.locator('[data-home-choice="terminal:shell"]').click();
    assert.equal(await page.locator('[data-screen]').getAttribute('data-kind'), 'terminal');
    await goHome();
    await page.locator('[data-action="New Workspace"]').click();
    await page.locator('[data-home-choice="workspace:scratch"]').click();
    assert.equal(await page.locator('[data-workspace-title]').textContent(), 'Scratch project');
    await page.locator('[data-open-work]').click();
    await page.locator('[data-explorer-tab="files"]').click();
    await page.locator('[data-open-file="README.md"]').click();
    assert.equal(await page.locator('[data-screen]').getAttribute('data-kind'), 'file');
    await goHome();
    await page.locator('[data-action="Resume Workspace"]').click();
    await page.waitForFunction(() => !document.querySelector('[data-home-actions]').hasAttribute('aria-busy'));
    await page.locator('.phone').screenshot({ path: path.join(output, 'home-resume-options.png') });
    await page.locator('[data-home-choice="resume:AgentLand"]').click();
    assert.equal(await page.locator('[data-screen]').getAttribute('data-kind'), 'terminal');
    assert.equal(await page.locator('[data-workspace-title]').textContent(), 'AgentLand');
    await goHome();
    await page.locator('[data-action="New Chat"]').click();
    await page.locator('[data-home-choice="chat:codex"]').click();
    assert.equal(await page.locator('[data-screen]').getAttribute('data-kind'), 'chat');
    assert.match(await page.locator('.task-head').textContent(), /Codex/);

    await goHome();
    await page.locator('[data-open-settings]').click();
    await page.locator('[data-setting-category="Appearance"]').click();
    await page.locator('[data-appearance="dark"]').click();
    await page.locator('[data-open-settings]').click();
    await page.locator('[data-settings-panel]').waitFor({ state: 'hidden' });
    await page.locator('.phone').screenshot({ path: path.join(output, 'home-four-actions-dark.png') });

    const widths = [];
    for (const width of [320, 375, 402]) {
      await page.setViewportSize({ width, height: 1100 });
      await page.locator('[data-open-work]').click();
      const tabWidths = await page.locator('[data-explorer-tab]').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().width));
      assert.ok(tabWidths.every(value => value === tabWidths[0]));
      widths.push({ viewport: width, columns: tabWidths });
      await page.locator('[data-open-work]').click();
      await page.locator('[data-explorer]').waitFor({ state: 'hidden' });
      assert.equal(await page.locator('[data-view]').evaluate(node => node.scrollWidth > node.clientWidth), false);
    }
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await page.locator('[data-action="New Chat"]').click();
    assert.equal(await page.locator('[data-home-choice="chat:codex"]').isVisible(), true);
    await page.locator('[data-home-back]').click();
    assert.equal(await page.locator('[data-action="New Chat"]').isVisible(), true);
    assert.deepEqual(errors, []);
    const result = { passed: true, geometry, widths, pageErrors: errors, checks: ['Four Home actions', 'Inline replacement and Escape focus', 'Sample chat and terminal creation', 'Sample workspace creation and file ownership', 'Workspace restoration', 'Header Settings', 'Equal explorer columns', 'Reduced motion'] };
    fs.writeFileSync(path.join(output, 'home-four-actions-checks.json'), JSON.stringify(result, null, 2) + '\n');
    console.log(JSON.stringify(result));
  } finally {
    await browser.close();
  }
}
check().catch(error => { console.error(error); process.exitCode = 1; });
