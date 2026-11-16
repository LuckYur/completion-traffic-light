/**
 * Host half of the completion traffic light.
 *
 * On the Desktop build it owns a small always-on-top window that sits outside
 * the application window and mirrors the aggregate turn state:
 *
 *   red    — at least one Session is running a turn
 *   green  — every turn finished (the light glows for a few seconds on the transition)
 *   idle   — nothing has run in this process yet
 *
 * The window is a PowerShell WinForms process; this plugin only publishes the
 * state to a file it polls, and kills it when the plugin is disposed or the
 * Host exits.
 */
import { spawn } from 'node:child_process'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const WINDOW_SCRIPT = fileURLToPath(new URL('./float-window.ps1', import.meta.url))

/** Electron's Node mode marks the Desktop host; other profiles render in-page only. */
function isDesktopHost() {
  return process.platform === 'win32' && process.env.ELECTRON_RUN_AS_NODE === '1'
}

/**
 * Start the floating window and keep its state file in step with live turns.
 * @param ctx - the plugin context owning the window lifetime.
 * @param config - optional row config; `window: false` disables the floating window.
 */
export function apply(ctx, config) {
  if (!isDesktopHost()) return
  if (config !== undefined && config !== null && config.window === false) return

  const stateFile = join(mkdtempSync(join(tmpdir(), 'dsh-traffic-light-')), 'state.txt')
  let last = 'idle'
  let ready = true
  function publish(state) {
    if (state === last || !ready) return
    last = state
    try {
      writeFileSync(stateFile, state === 'done' ? `done:${Date.now()}` : state)
    } catch (error) {
      console.warn('completion-traffic-light: could not publish state', error)
    }
  }
  writeFileSync(stateFile, 'idle')

  let child
  let disposed = false
  let restarts = 0
  let restartTimer
  function startWindow() {
    ready = true
    try {
      child = spawn('powershell.exe', [
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', WINDOW_SCRIPT,
        '-StateFile', stateFile,
        '-ParentPid', String(process.pid),
      ], { windowsHide: true, stdio: 'ignore' })
    } catch (error) {
      console.warn('completion-traffic-light: could not open the floating window', error)
      ready = false
      return
    }
    child.on('error', error => {
      console.warn('completion-traffic-light: floating window failed', error)
      ready = false
    })
    child.on('exit', code => {
      if (disposed) return
      // The "关闭红绿灯" menu exits cleanly; a crash or an outside kill is
      // retried so the indicator cannot disappear without a way back.
      if (code === 0) return
      if (restarts >= 5) {
        console.warn('completion-traffic-light: floating window keeps exiting; giving up')
        return
      }
      restarts += 1
      restartTimer = setTimeout(startWindow, 3000)
    })
  }
  startWindow()
  ctx.effect(() => () => {
    disposed = true
    clearTimeout(restartTimer)
    try { child?.kill() } catch { /* the window already exited */ }
  })

  const active = new Set()
  let started = false
  /**
   * Whether any client still waits for an answer (AskUserQuestion or approval).
   * The turn keeps running meanwhile, so this outranks the running state.
   * @returns true while a pending remote request is unanswered.
   */
  function hasPending() {
    const gateway = ctx.get('typertGateway')
    if (gateway === undefined || typeof gateway.getPendingRemoteEvents !== 'function') return false
    try {
      // Only a Session whose turn is still live can be waiting for the user; a
      // request left over from a closed or idle Session must not keep the light amber.
      return gateway.getPendingRemoteEvents().some(entry =>
        (entry.event === 'user-questions/request' || entry.event === 'approval/request') &&
        active.has(entry.agentId))
    } catch (error) {
      console.warn('completion-traffic-light: could not read pending requests', error)
      return false
    }
  }
  function sync() {
    publish(hasPending() ? 'waiting' : active.size > 0 ? 'running' : (started ? 'done' : 'idle'))
  }
  const pendingTimer = setInterval(sync, 300)
  ctx.effect(() => () => clearInterval(pendingTimer))

  ctx.on('api-session/status', (sessionId, running) => {
    if (running) {
      active.add(sessionId)
      started = true
    } else {
      active.delete(sessionId)
    }
    sync()
  })

  const agents = ctx.get('agents')
  if (agents !== undefined) {
    for (const agent of agents.list()) {
      if (agent.status !== 'running') continue
      active.add(agent.session.id)
      started = true
    }
    sync()
  }
}
