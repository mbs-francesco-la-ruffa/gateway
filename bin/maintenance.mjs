#!/usr/bin/env node
/*
 * The maintenance switch, for any Railway project with a gateway in front (README.md, «Accendere e
 * spegnere»):
 *
 *   gateway-maintenance status
 *   gateway-maintenance on  [--project <id or name>] [--environment <name>] [--service <name>] [--no-wait]
 *   gateway-maintenance off
 *
 * It sets MAINTENANCE on the gateway service with the Railway CLI, which redeploys the gateway: an image,
 * so no build and no build queue. Then it waits for that deployment and asks every host the gateway
 * routes what it answers now. `status` only reads.
 *
 * Without --project and --environment it works on the project and environment the current folder is
 * linked to (`railway link`); with them, from any folder. The service is `gateway` unless --service
 * says otherwise. No dependencies: it drives the Railway CLI, `railway` on the PATH (RAILWAY_CLI
 * names another one).
 *
 * Away from Railway (README.md, «Fuori da Railway») it creates or removes the switch file instead, at
 * once and with no restart:
 *
 *   gateway-maintenance on  --docker <container> [--ssh <user@host>] [--path /data/maintenance.on]
 *   gateway-maintenance off --ssh <user@host> --path /srv/gateway/data/maintenance.on
 *
 * --docker runs it inside the gateway's container (`docker exec`, on this machine or, with --ssh, on the
 * server); --ssh alone runs it on the server, where --path is the file as the server sees it (inside
 * the volume). DOCKER_CLI and SSH_CLI name other commands for docker and ssh.
 */
import { spawnSync } from 'node:child_process'

const USAGE =
  `usage: gateway-maintenance on|off|status [--project <id or name>] [--environment <name>] [--service <name>] [--no-wait]\n` +
  `       gateway-maintenance on|off|status --docker <container> [--ssh <user@host>] [--path <file>]\n` +
  `       gateway-maintenance on|off|status --ssh <user@host> --path <file>`
const SWITCH_FILE = '/data/maintenance.on'
const WAIT_SECONDS = 240
const CLI = process.env.RAILWAY_CLI || 'railway'

function fail(message) {
  console.error(`maintenance: ${message}`)
  process.exit(1)
}

const args = process.argv.slice(2)
const command = args.shift()
if (['-h', '--help', 'help'].includes(command)) {
  console.log(USAGE)
  process.exit(0)
}
if (!['on', 'off', 'status'].includes(command)) fail(USAGE)

let service = 'gateway'
let wait = true
const scope = [] // --environment and --project, passed as given to every railway call
const server = { docker: null, ssh: null, path: null }
while (args.length) {
  const arg = args.shift()
  if (arg === '--no-wait') wait = false
  else if (['--service', '--environment', '--project', '--docker', '--ssh', '--path'].includes(arg)) {
    const value = args.shift()
    if (!value || value.startsWith('--')) fail(`${arg} needs a value.\n${USAGE}`)
    if (arg === '--service') service = value
    else if (['--docker', '--ssh', '--path'].includes(arg)) server[arg.slice(2)] = value
    else scope.push(arg, value)
  } else fail(`unknown option ${arg}.\n${USAGE}`)
}

if (server.docker || server.ssh || server.path) {
  await switchFile()
  process.exit(0)
}

/** Runs the Railway CLI; returns its stdout, or stops with its own error. Never prints a value. */
function railway(argv, { quiet = false } = {}) {
  if (!quiet) console.log(`$ railway ${argv.join(' ')}`)
  const result = spawnSync(CLI, argv, { encoding: 'utf8' })
  if (result.error) {
    fail(
      `could not run the Railway CLI «${CLI}» (${result.error.message}). Install it (npm i -g @railway/cli), ` +
        `or run this from a project that has it (pnpm exec, npx), and \`railway login\`.`,
    )
  }
  if (result.status !== 0) {
    const said = (result.stderr || result.stdout).trim()
    if (/not found/i.test(said) && /service/i.test(said)) {
      fail(
        `there is no service «${service}» in this project and environment (Railway: ${said}).\n` +
          `Another name: --service. No gateway yet: the gateway's README says how to add one.`,
      )
    }
    if (/no linked project/i.test(said)) {
      fail(`this folder is linked to no Railway project: pass --project and --environment, or \`railway link\`.`)
    }
    fail(`railway ${argv[0]} ${argv[1] ?? ''} failed: ${said}`)
  }
  return result.stdout
}

const target = ['--service', service, ...scope]

/** Single quotes for a POSIX shell: the only way a value reaches a remote shell. */
function quote(value) {
  return `'${value.replaceAll("'", `'\\''`)}'`
}

/** Away from Railway: the switch file, through docker exec, ssh, or both. */
async function switchFile() {
  if (scope.length || service !== 'gateway' || !wait) {
    fail(`--project, --environment, --service and --no-wait are for Railway; with --docker or --ssh they mean nothing.`)
  }
  if (!server.docker && !server.ssh) fail(`--path needs --docker or --ssh.\n${USAGE}`)
  if (server.ssh && !server.docker && !server.path) {
    fail(`with --ssh alone, --path says where the switch file is on the server (inside the gateway's volume).`)
  }
  if (server.docker && !/^[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(server.docker)) fail(`--docker is [${server.docker}]: a container name or id.`)
  if (server.ssh && !/^[A-Za-z0-9][A-Za-z0-9_.@:-]*$/.test(server.ssh)) fail(`--ssh is [${server.ssh}]: user@host, or a host from ~/.ssh/config.`)
  const path = server.path ?? SWITCH_FILE
  if (!/^(\/[A-Za-z0-9._-]+)+$/.test(path)) fail(`--path is [${path}]: an absolute path, letters, digits, . _ - only.`)
  const dir = path.slice(0, path.lastIndexOf('/')) || '/'
  const where = server.docker ? `the container «${server.docker}»${server.ssh ? ` on ${server.ssh}` : ''}` : server.ssh

  /** Runs one shell script where the switch lives; returns its stdout, or stops with its error. */
  function run(script) {
    let command
    let argv
    if (server.docker) {
      const inner = ['exec', server.docker, 'sh', '-c', script]
      if (server.ssh) {
        command = process.env.SSH_CLI || 'ssh'
        argv = [server.ssh, [process.env.DOCKER_CLI || 'docker', ...inner].map(quote).join(' ')]
      } else {
        command = process.env.DOCKER_CLI || 'docker'
        argv = inner
      }
    } else {
      command = process.env.SSH_CLI || 'ssh'
      argv = [server.ssh, `sh -c ${quote(script)}`]
    }
    const result = spawnSync(command, argv, { encoding: 'utf8' })
    if (result.error) fail(`could not run ${command} (${result.error.message}).`)
    if (result.status !== 0) fail(`${command} failed on ${where}: ${(result.stderr || result.stdout).trim()}`)
    return result.stdout
  }

  const read = () => {
    // The file, and (in a container) MAINTENANCE and ROUTES from its environment.
    const out = run(
      `if [ -e ${quote(path)} ]; then echo file=on; else echo file=off; fi; ` +
        (server.docker ? `echo "env=\${MAINTENANCE:-off}"; echo "routes=\${ROUTES:-}"` : 'true'),
    )
    const field = (name) => out.match(new RegExp(`^${name}=(.*)$`, 'm'))?.[1] ?? null
    return { file: field('file'), env: field('env'), routes: field('routes') }
  }

  async function show(state) {
    const on = state.file === 'on' || state.env === 'on'
    console.log(`gateway on ${where}: maintenance ${on ? 'on' : 'off'}`)
    console.log(`  switch file ${path}: ${state.file === 'on' ? 'present' : 'absent'}`)
    if (state.env) console.log(`  MAINTENANCE=${state.env} in the container's environment`)
    if (state.routes) for (const host of hosts({ ROUTES: state.routes })) console.log(`  https://${host}/ → ${await probe(host)}`)
  }

  const before = read()
  if (command === 'status') return show(before)
  const want = command === 'on' ? 'on' : 'off'
  if (before.file === want) console.log(`The switch file is already ${want === 'on' ? 'there' : 'absent'}: nothing to change.`)
  else {
    console.log(`${want === 'on' ? 'Creating' : 'Removing'} ${path} on ${where}: live at the next request, no restart.`)
    run(want === 'on' ? `mkdir -p ${quote(dir)} && touch ${quote(path)}` : `rm -f ${quote(path)}`)
  }
  const after = read()
  if (want === 'off' && after.env === 'on') {
    console.log(`  MAINTENANCE=on in the container's environment wins over the file: maintenance stays on until that variable is removed and the container recreated.`)
  }
  await show(after)
}

function variables() {
  const vars = JSON.parse(railway(['variable', 'list', '--json', ...target], { quiet: true }))
  if (!('ROUTES' in vars)) {
    fail(`the service «${service}» has no ROUTES variable: it is not a gateway (README.md).`)
  }
  return vars
}

/** The host names ROUTES sends somewhere, `*` left out: there is no address to ask for it. */
function hosts(vars) {
  return vars.ROUTES.split(/[\s,]+/)
    .filter(Boolean)
    .map((pair) => pair.split('=')[0].toLowerCase())
    .filter((host) => host && host !== '*')
}

function latestDeployment() {
  const list = JSON.parse(railway(['deployment', 'list', '--json', '--limit', '1', ...target], { quiet: true }))
  return list[0] ?? null
}

/** What one host answers now: the app, the maintenance page, or nothing. */
async function probe(host) {
  try {
    const response = await fetch(`https://${host}/`, {
      redirect: 'manual',
      signal: AbortSignal.timeout(10_000),
      headers: { 'Cache-Control': 'no-cache' },
    })
    await response.body?.cancel()
    const page = response.headers.get('x-gateway') === 'maintenance'
    return `${response.status} ${page ? 'maintenance page' : 'the app'}`
  } catch (error) {
    return `no answer (${error.cause?.code ?? error.name})`
  }
}

async function report(vars) {
  const mode = vars.MAINTENANCE || 'off'
  const deployment = latestDeployment()
  console.log(`gateway «${service}»: MAINTENANCE=${mode}` + (vars.MAINTENANCE ? '' : ' (unset, which is off)'))
  if (vars.MAINTENANCE_UNTIL) console.log(`  expected back: ${vars.MAINTENANCE_UNTIL}`)
  if (vars.MAINTENANCE_PASSTHROUGH) console.log(`  still forwarded during maintenance: ${vars.MAINTENANCE_PASSTHROUGH}`)
  if (deployment) console.log(`  latest deployment: ${deployment.status}, ${deployment.createdAt}`)
  const names = hosts(vars)
  if (!names.length) console.log('  ROUTES names no host but *: nothing to ask.')
  for (const host of names) console.log(`  https://${host}/ → ${await probe(host)}`)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

/** Waits for a deployment newer than `since` to finish, and says how it ended. */
async function waitForDeployment(since) {
  const deadline = Date.now() + WAIT_SECONDS * 1000
  // Setting a variable deploys by itself; if after half a minute nothing started, ask once.
  const askAt = Date.now() + 30_000
  let redeployed = false
  let last = ''
  while (Date.now() < deadline) {
    const deployment = latestDeployment()
    const fresh = deployment && deployment.id !== since
    if (fresh && deployment.status !== last) {
      last = deployment.status
      console.log(`  deployment ${deployment.id.slice(0, 8)}: ${last}`)
    }
    if (fresh && ['SUCCESS', 'FAILED', 'CRASHED', 'REMOVED', 'SKIPPED'].includes(deployment.status)) {
      return deployment.status
    }
    if (!fresh && !redeployed && Date.now() > askAt) {
      redeployed = true
      railway(['redeploy', '--yes', ...target])
    }
    await sleep(3000)
  }
  return null
}

const vars = variables()

if (command === 'status') {
  await report(vars)
  process.exit(0)
}

const current = vars.MAINTENANCE || 'off'
if (current === command) {
  console.log(`The gateway «${service}» already has MAINTENANCE=${command}: nothing to change.`)
  await report(vars)
  process.exit(0)
}

const before = latestDeployment()?.id ?? null
console.log(`Setting MAINTENANCE=${command} on the gateway «${service}» (was ${current}). Railway redeploys it: an image, no build.`)
railway(['variable', 'set', `MAINTENANCE=${command}`, ...target])

if (!wait) {
  console.log(`Not waiting (--no-wait). \`gateway-maintenance status\` says when it is live.`)
  process.exit(0)
}

const outcome = await waitForDeployment(before)
if (outcome === null) fail(`no finished deployment after ${WAIT_SECONDS} s: \`gateway-maintenance status\`, and the dashboard.`)
if (outcome !== 'SUCCESS') {
  fail(
    `the deployment ended ${outcome}: the one before it keeps the traffic. ` +
      `\`railway logs --service ${service}\` says why (a line starting with «gateway:»).`,
  )
}
await report(variables())
