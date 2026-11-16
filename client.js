/**
 * Browser half of the completion traffic light.
 *
 * The light sits in `conversation.composer.dock`, directly under the composer,
 * and reads the session's unified UI status through the standard
 * `useSessionStatus` seat:
 *
 *   red    — the agent is working on the current turn
 *   amber  — a turn finished but something still waits for the user
 *   green  — the turn is finished and nothing is pending
 *
 * A green light glows harder for a few seconds right after a turn ends, so the
 * completion is noticeable without watching the transcript.
 */
window.__ModuleLoader__.load({
  id: 'dsh-completion-traffic-light',
  factory(require) {
    const React = require('react')
    const h = React.createElement

    const NS = 'completion-traffic-light'
    const RED = '#ff4d4f'
    const AMBER = '#ffb020'
    const GREEN = '#22c55e'
    const GLOW_MS = 8000

    /** One lamp of the traffic light; inactive lamps stay visible but dim. */
    function lamp(color, active, bright) {
      return h('span', {
        'aria-hidden': true,
        style: {
          width: 8,
          height: 8,
          borderRadius: '50%',
          background: color,
          opacity: active ? 1 : 0.16,
          boxShadow: active
            ? (bright ? `0 0 9px 2px ${color}` : `0 0 4px 0 ${color}`)
            : 'none',
          transition: 'opacity 160ms ease, box-shadow 240ms ease',
        },
      })
    }

    /**
     * Build the slot component bound to one translate function.
     * @param t - namespace-bound translate function.
     * @returns the traffic light component.
     */
    function createTrafficLight(t) {
      return function TrafficLight(props) {
        const { sessionId, useSessionStatus } = props
        const status = useSessionStatus(snapshot => snapshot.get(sessionId))
        const running = status === undefined ? undefined : status.running
        // A question or approval prompt keeps the turn running, so the pending
        // interaction outranks the running lamp instead of waiting for it to end.
        const waiting = status !== undefined && status.pendingInteraction !== undefined
        const done = !waiting && running === false

        const [justCompleted, setJustCompleted] = React.useState(false)
        const previousRunning = React.useRef(running)
        React.useEffect(() => {
          const was = previousRunning.current
          previousRunning.current = running
          if (was !== true || running !== false) return undefined
          setJustCompleted(true)
          const timer = setTimeout(() => setJustCompleted(false), GLOW_MS)
          return () => clearTimeout(timer)
        }, [running])

        const state = waiting ? 'waiting' : running === true ? 'running' : done ? 'done' : 'idle'
        const label = t(state)
        const description = t('aria', { state: label })

        return h('div', {
          role: 'status',
          'aria-label': description,
          title: description,
          style: {
            display: 'inline-flex',
            alignItems: 'center',
            gap: 6,
            padding: '3px 9px 3px 8px',
            borderRadius: 999,
            background: 'var(--dsw-alias-bg-layer-2)',
            border: '1px solid var(--dsw-alias-border-l1)',
            color: 'var(--dsw-alias-label-secondary)',
            fontSize: 11,
            lineHeight: '14px',
            userSelect: 'none',
          },
        },
          h('span', { 'aria-hidden': true, style: { display: 'inline-flex', gap: 3 } },
            lamp(RED, state === 'running', false),
            lamp(AMBER, state === 'waiting', false),
            lamp(GREEN, state === 'done', justCompleted),
          ),
          h('span', { style: { whiteSpace: 'nowrap' } }, label),
        )
      }
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        const t = ctx.locale.bind(NS)
        ctx.effect(() => ctx.locale.register(NS, {
          zh: {
            running: '运行中',
            waiting: '等待你处理',
            done: '已完成',
            idle: '待命',
            aria: '任务状态：{state}',
          },
          en: {
            running: 'Working',
            waiting: 'Needs you',
            done: 'Done',
            idle: 'Idle',
            aria: 'Task status: {state}',
          },
        }), 'completion-traffic-light: dictionaries')
        const TrafficLight = createTrafficLight(t)
        ctx.slots.inject('conversation.composer.dock', () => ctx.slots.register({
          name: 'conversation.composer.dock',
          id: 'completion-traffic-light',
          order: 5,
        }, TrafficLight))
      },
    }
  },
})
