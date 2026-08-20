import assert from 'node:assert/strict'
import test from 'node:test'

import { botMode, resetBotModeTestState } from './plugin-test-runtime.mjs'

test('legacy canonical creation is born hidden with no preference gate', async () => {
  const created = []
  resetBotModeTestState({
    openSession: async () => undefined,
    request: async (method, params) => {
      if (method === 'profiles.ensure_bot_chat') throw new Error('method not found')
      if (method === 'session.create') {
        created.push(params)
        return { stored_session_id: 'sid-1', session_id: null }
      }
      if (method === 'profiles.configure') return { applied: { ui_meta: true } }
      return {}
    }
  })

  await botMode.createCanonicalChat('alpha')
  assert.deepEqual(created, [{ profile: 'alpha', title: 'Bot Chat', hidden: true }])
})

test('group member session creation is also born hidden', async () => {
  const requests = []
  resetBotModeTestState({
    request: async (method, params) => {
      requests.push({ method, params })
      if (method === 'session.resume') throw new Error('not found')
      if (method === 'session.create') return { stored_session_id: 'group-1', session_id: 'runtime-1' }
      throw new Error(`unexpected ${method}`)
    }
  })

  assert.deepEqual(
    await botMode.ensureGroupChatSession('Core', { name: 'alpha' }),
    { runtime: 'runtime-1', stored: 'group-1' }
  )
  assert.deepEqual(requests.at(-1), {
    method: 'session.create',
    params: { profile: 'alpha', title: 'Group: Core', hidden: true }
  })
  assert.equal(botMode.state.$groupChats.get().Core.sessions.alpha, 'group-1')
})

test('known canonical and room sessions are hidden only after canonical verification', async () => {
  const calls = []
  resetBotModeTestState({
    request: async (method, params) => {
      calls.push({ method, params })
      if (method === 'profiles.list') {
        return {
          profiles: [
            { name: 'alpha', preferred_session: { id: 'chat-a', title: 'Bot Chat' } },
            { name: 'beta', preferred_session: { id: 'chat-b', title: 'Bot Chat' } }
          ]
        }
      }
      if (method === 'session.list') return { sessions: [] }
      return {}
    }
  })
  botMode.state.$botMeta.set({ alpha: { chat: 'chat-a' }, beta: { chat: 'chat-b' }, gamma: {} })
  botMode.state.$groupChats.set({
    Core: { sessions: { alpha: 'room-core-a', beta: 'room-core-b' } },
    Quiet: { sessions: { alpha: 'chat-a' } }
  })

  await botMode.hideOwnedBotSessions()

  const hidden = calls
    .filter(call => call.method === 'session.set_hidden')
    .map(call => call.params.session_id)
    .sort()
  assert.deepEqual(hidden, ['chat-a', 'chat-b', 'room-core-a', 'room-core-b'])
  assert.ok(
    calls
      .filter(call => call.method === 'session.set_hidden')
      .every(call => call.params.hidden === true)
  )
})

test('a stale canonical pointer to an ordinary session is never hidden', async () => {
  const calls = []
  resetBotModeTestState({
    request: async (method, params) => {
      calls.push({ method, params })
      if (method === 'profiles.list') {
        return {
          profiles: [
            { name: 'default', preferred_session: { id: 'ordinary-1', title: 'production planning' } }
          ]
        }
      }
      if (method === 'session.list') return { sessions: [] }
      return {}
    }
  })
  botMode.state.$botMeta.set({ default: { chat: 'ordinary-1' } })

  await botMode.hideOwnedBotSessions()

  assert.equal(calls.some(call => call.method === 'session.set_hidden'), false)
})

test('profile sweep hides Bot Mode plumbing and preserves user-titled rows on each source', async () => {
  const calls = []
  const rowsByProfile = {
    alpha: [
      { id: 'a-1', title: 'Bot Chat' },
      { id: 'a-2', title: 'Agent Inbox' },
      { id: 'a-3', title: 'Group: Core' },
      { id: 'a-4', title: 'My real conversation' },
      { id: 'a-5', title: 'Bot Chat notes' }
    ],
    remy: [{ id: 'r-1', title: 'Agent Inbox' }]
  }
  resetBotModeTestState({
    request: async (method, params) => {
      calls.push({ source: 'local', method, params })
      if (method === 'session.list') return { sessions: rowsByProfile[params.profile] || [] }
      return {}
    },
    requestProfile: async (route, method, params) => {
      calls.push({ source: route.connectionId, method, params })
      if (method === 'session.list') return { sessions: rowsByProfile[params.profile] || [] }
      return {}
    }
  })
  botMode.state.$lastRoster.set([
    { name: 'alpha' },
    { name: 'remy', remoteSource: true, connectionId: 'mini' }
  ])

  await botMode.sweepBotProfileSessions()

  const lists = calls.filter(call => call.method === 'session.list')
  assert.deepEqual(lists.map(call => call.params.profile).sort(), ['alpha', 'remy'])
  assert.ok(lists.every(call => !('include_hidden' in call.params)))

  const hidden = calls.filter(call => call.method === 'session.set_hidden')
  assert.deepEqual(
    hidden.map(call => call.params.session_id).sort(),
    ['a-1', 'a-2', 'a-3', 'r-1']
  )
  assert.ok(hidden.every(call => call.params.hidden === true))
  assert.equal(hidden.find(call => call.params.session_id === 'r-1').source, 'mini')
})

test('the load sweep runs both known-id and profile-ownership recovery paths', async () => {
  const calls = []
  resetBotModeTestState({
    request: async (method, params) => {
      calls.push({ method, params })
      if (method === 'profiles.list') {
        return {
          profiles: [
            { name: 'alpha', preferred_session: { id: 'chat-a', title: 'Bot Chat' } }
          ]
        }
      }
      if (method === 'session.list') return { sessions: [{ id: 'inbox-a', title: 'Agent Inbox' }] }
      return {}
    }
  })
  botMode.state.$botMeta.set({ alpha: { chat: 'chat-a' } })

  await botMode.hideOwnedBotSessions()

  assert.deepEqual(
    calls
      .filter(call => call.method === 'session.set_hidden')
      .map(call => call.params.session_id)
      .sort(),
    ['chat-a', 'inbox-a']
  )
})
