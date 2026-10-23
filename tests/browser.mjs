// The maintenance page in a real browser (Chromium, headless), run by tests/check.sh inside the
// Playwright image. The pages are the ones check.sh had the gateway render, mounted in /pages; every
// request is answered here (page.route), so nothing leaves the container. Prints `ok <what>` or
// `FAIL <what>` per check; with SHOTS set, also saves screenshots there.
import { readFileSync } from 'node:fs'
import { chromium } from 'playwright-core'

const page = (name) => readFileSync(`/pages/${name}.html`, 'utf8')
const URL_ = 'http://gateway.test/area/riservata?x=1'
// A stand-in logo for the screenshots: the real page loads whatever MAINTENANCE_LOGO_URL names.
const LOGO = `<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" viewBox="0 0 36 36"><rect width="36" height="36" rx="9" fill="#0b6e4f"/><path d="M10 25V11l8 9 8-9v14" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"/></svg>`

let failed = 0
function check(what, condition, detail = '') {
  if (condition) console.log(`ok ${what}`)
  else {
    failed++
    console.log(`FAIL ${what}${detail ? `: ${detail}` : ''}`)
  }
}

const browser = await chromium.launch()

/** A tab where gateway.test answers with `html` as the gateway would, until `state.back` is set. */
async function open(html, { width = 1280, height = 900, scheme = 'light', motion = 'no-preference', logo = 'abort', clock = false, hold = false, url = URL_ } = {}) {
  const context = await browser.newContext({
    viewport: { width, height },
    deviceScaleFactor: width < 600 ? 3 : 2,
    colorScheme: scheme,
    reducedMotion: motion,
  })
  const tab = await context.newPage()
  const state = { back: false, fetches: 0, foreign: [] }
  const held = hold ? new Promise((resolve) => (state.release = resolve)) : null
  await context.route('**/*', async (route) => {
    const request = route.request()
    const { host } = new URL(request.url())
    if (host === 'gateway.test') {
      if (request.resourceType() === 'fetch') {
        state.fetches++
        if (held) await held
      }
      if (state.back) return route.fulfill({ status: 200, contentType: 'text/html', body: '<!doctype html><p id="app">app</p>' })
      return route.fulfill({ status: 503, contentType: 'text/html; charset=utf-8', headers: { 'X-Gateway': 'maintenance', 'Cache-Control': 'no-store' }, body: html })
    }
    state.foreign.push(request.url())
    if (logo === 'serve') return route.fulfill({ status: 200, contentType: 'image/svg+xml', body: LOGO })
    return route.abort()
  })
  if (clock) await tab.clock.install()
  await tab.goto(url)
  return { context, tab, state }
}

/** Runs one block of checks; an exception (a timeout, a missing element) is one FAIL, not the end. */
async function block(what, fn) {
  try {
    await fn()
  } catch (error) {
    check(what, false, String(error.message).split('\n')[0])
  }
}

// --- The check that brings the visitor back by itself.
await block('the periodic check', async () => {
  const { context, tab, state } = await open(page('bare'), { clock: true })
  check('the script runs and shows the line about the page reloading by itself', await tab.isVisible('#gw-auto'))
  let fetched = tab.waitForRequest((r) => r.resourceType() === 'fetch')
  await tab.clock.runFor(10_500)
  await fetched
  await tab.waitForFunction(() => document.getElementById('gw-last').textContent !== '', null, { timeout: 5000 })
  check('after 10 s it asks again, and stays while the answer is still the gateway\'s',
    !(await tab.$('#app')) && /^Ultimo controllo alle \d\d:\d\d\.$/.test(await tab.textContent('#gw-last')),
    await tab.textContent('#gw-last'))
  state.back = true
  fetched = tab.waitForRequest((r) => r.resourceType() === 'fetch')
  await tab.clock.runFor(15_500)
  await fetched
  await tab.waitForSelector('#app', { timeout: 5000 }).catch(() => null)
  check('when the answer has no X-Gateway it reloads, and the app shows', !!(await tab.$('#app')))
  check('  the checks grow apart: one at 10 s, the next 15 s after it', state.fetches === 2, `${state.fetches} checks`)
  await context.close()
})

await block('a hidden tab', async () => {
  // The tab is hidden while a check is on its way: when the answer arrives, no next check is planned.
  const { context, tab, state } = await open(page('bare'), { clock: true, hold: true })
  const fetched = tab.waitForRequest((r) => r.resourceType() === 'fetch')
  await tab.clock.runFor(10_500)
  await fetched
  await tab.evaluate(() => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => true })
    document.dispatchEvent(new Event('visibilitychange'))
  })
  state.release()
  await tab.waitForFunction(() => document.getElementById('gw-last').textContent !== '', null, { timeout: 5000 })
  await tab.clock.runFor(300_000)
  await new Promise((resolve) => setTimeout(resolve, 1000)) // real time, for a request that did start to arrive
  check('a hidden tab asks nothing more, even when a check was on its way as it hid', state.fetches === 1, `${state.fetches} checks`)
  await context.close()
})

// --- What a visitor touches.
{
  const { context, tab } = await open(page('full'), { url: `${URL_}#sezione` })
  const href = await tab.evaluate(() => document.getElementById('gw-retry').href)
  check('«Riprova» is a link to the same address, without the fragment (a GET, even after a POST)', href === URL_, href)
  await tab.keyboard.press('Tab')
  const focused = await tab.evaluate(() => {
    const el = document.activeElement
    const s = getComputedStyle(el)
    return { href: el.getAttribute('href'), style: s.outlineStyle, width: s.outlineWidth }
  })
  check('the first Tab lands on the first link of the steps, with a visible 3 px focus ring',
    focused.href === 'mailto:assistenza@example.it' && focused.style === 'solid' && focused.width === '3px', JSON.stringify(focused))
  check('a logo that does not load is removed, not drawn broken', !(await tab.$('.brand img')))
  check('  and the name is still there', (await tab.textContent('.brand')) === 'Regione Esempio')
  const external = await tab.evaluate(() => performance.getEntriesByType('resource').map((e) => e.name))
  check('the page loads nothing from outside but the logo', external.every((u) => u.startsWith('https://cdn.example.it/')), external.join(' '))
  await context.close()
}

for (const name of ['bare', 'full', 'evil', 'english']) {
  const { context, tab } = await open(page(name), { width: 320, height: 640 })
  const fit = await tab.evaluate(() => ({
    scroll: document.documentElement.scrollWidth,
    width: innerWidth,
    short: [...document.querySelectorAll('.btn')].filter((b) => b.getBoundingClientRect().height < 44).length,
  }))
  check(`${name}, 320 px wide: no sideways scrolling, every button at least 44 px tall`,
    fit.scroll <= fit.width && fit.short === 0, JSON.stringify(fit))
  await context.close()
}

{
  const { context, tab } = await open(page('bare'))
  await tab.keyboard.press('Tab')
  const focused = await tab.evaluate(() => {
    const s = getComputedStyle(document.activeElement)
    return { id: document.activeElement.id, style: s.outlineStyle, width: s.outlineWidth }
  })
  check('with no contacts, the first Tab lands on «Riprova», with a visible 3 px focus ring',
    focused.id === 'gw-retry' && focused.style === 'solid' && focused.width === '3px', JSON.stringify(focused))
  await context.close()
}

// --- The layout of a public service's page: one column aligned on the left, under a band with a stripe.
for (const [name, width] of [['full', 1280], ['full', 390], ['unreachable', 1280]]) {
  const { context, tab } = await open(page(name), { width, logo: 'serve' })
  const shape = await tab.evaluate(() => {
    const left = (selector) => Math.round(document.querySelector(selector).getBoundingClientRect().left)
    const head = getComputedStyle(document.querySelector('.head'))
    return {
      lefts: ['.brand-name', '.status', 'h1', '.message p', 'h2', '#gw-retry'].map(left),
      bullets: getComputedStyle(document.querySelector('.next')).listStyleType,
      stripe: head.borderBottomWidth,
      align: getComputedStyle(document.querySelector('main')).textAlign,
    }
  })
  // The logo stands before the name: the band starts where the column starts, the name after the logo.
  const [brand, ...column] = shape.lefts
  check(`${name}, ${width} px: the column is aligned on the left, the steps are a bulleted list, the band has its 4 px stripe`,
    column.every((x) => x === column[0]) && brand > column[0] && shape.bullets === 'disc' && shape.stripe === '4px' &&
      ['start', 'left'].includes(shape.align), JSON.stringify(shape))
  await context.close()
}

{
  const colours = {}
  for (const scheme of ['light', 'dark']) {
    const { context, tab } = await open(page('bare'), { scheme })
    colours[scheme] = await tab.evaluate(() => [document.body, document.getElementById('gw-retry')].map((el) => getComputedStyle(el).backgroundColor).join(' / '))
    await context.close()
  }
  // The frontend's neutral theme: background and primary, light then dark.
  check('the page follows the system theme, in the frontend\'s colours',
    colours.light === 'rgb(243, 246, 249) / rgb(80, 78, 198)' && colours.dark === 'rgb(2, 8, 23) / rgb(248, 250, 252)', JSON.stringify(colours))
}

// --- Screenshots, for a person to look at.
if (process.env.SHOTS) {
  const shots = [
    ['full', 'desktop', 1280, 900],
    ['full', 'phone', 390, 844],
    ['bare', 'desktop', 1280, 900],
    ['bare', 'phone', 390, 844],
    ['english', 'desktop', 1280, 900],
    ['colour-ffff00', 'desktop', 1280, 900],
    ['theme-pa', 'desktop', 1280, 900],
    ['theme-pa', 'phone', 390, 844],
    ['own', 'desktop', 1280, 900],
    ['own', 'phone', 390, 844],
    ['unreachable', 'desktop', 1280, 900],
    ['unreachable', 'phone', 390, 844],
    ['unreachable-bare', 'desktop', 1280, 900],
    ['unreachable-bare', 'phone', 390, 844],
  ]
  for (const [name, device, width, height] of shots) {
    for (const scheme of ['light', 'dark']) {
      const { context, tab } = await open(page(name), { width, height, scheme, motion: 'reduce', logo: 'serve' })
      const file = `${process.env.SHOTS}/${name}-${device}-${scheme}.png`
      await tab.screenshot({ path: file, fullPage: true })
      await context.close()
    }
  }
  console.log(`screenshots in ${process.env.SHOTS}`)
}

await browser.close()
process.exit(failed ? 1 : 0)
