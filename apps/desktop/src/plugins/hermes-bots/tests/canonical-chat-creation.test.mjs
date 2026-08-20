import assert from 'node:assert/strict'
import test from 'node:test'

import { botMode, resetBotModeTestState } from './plugin-test-runtime.mjs'

test('regression: navigation retries after the kickoff persists a new canonical chat', async () => {
  const events = []
  let attempts = 0
  resetBotModeTestState({
    openSession: async id => {
      events.push(`open:${id}`)
      attempts += 1
      if (attempts === 1) throw new Error('stored row not persisted yet')
    },
    request: async method => {
      if (method === 'profiles.ensure_bot_chat') throw new Error('method not found')
      if (method === 'session.create') return { stored_session_id: 'stored-1', session_id: 'runtime-1' }
      if (method === 'profiles.configure') return { applied: { ui_meta: true } }
      if (method === 'prompt.submit') events.push('kickoff:persisted')
      return {}
    }
  })

  assert.equal(await botMode.createCanonicalChat('ops'), 'stored-1')
  assert.deepEqual(events, ['open:stored-1', 'kickoff:persisted', 'open:stored-1'])
})

test('regression: a failed intro keeps the pin', async () => {
  resetBotModeTestState({
    openSession: async () => undefined,
    request: async method => {
      if (method === 'profiles.ensure_bot_chat') throw new Error('method not found')
      if (method === 'session.create') return { stored_session_id: 'new-bot-chat', session_id: 'rt-1' }
      if (method === 'profiles.configure') return { applied: { ui_meta: true } }
      if (method === 'prompt.submit') throw new Error('gateway timeout')
      return {}
    }
  })

  assert.equal(await botMode.createCanonicalChat('newbie'), 'new-bot-chat')
  assert.deepEqual(botMode.state.$botMeta.get(), {
    newbie: { chat: 'new-bot-chat' }
  })
})

test('canonical authority creates and opens without legacy create or kickoff', async () => {
  const calls = []
  const opens = []
  resetBotModeTestState({
    openSession: async (id, params) => opens.push({ id, params }),
    request: async (method, params) => {
      calls.push({ method, params })
      if (method === 'profiles.ensure_bot_chat') {
        return { session_id: 'durable-1', profile: 'ops', created: true }
      }
      if (method === 'profiles.configure') return { applied: { ui_meta: true } }
      throw new Error(`unexpected ${method}`)
    }
  })

  assert.equal(await botMode.createCanonicalChat('ops'), 'durable-1')
  assert.deepEqual(botMode.state.$botMeta.get(), {
    ops: { chat: 'durable-1' }
  })
  assert.deepEqual(calls.map(call => call.method), [
    'profiles.ensure_bot_chat',
    'profiles.configure'
  ])
  assert.equal(calls.some(call => call.method === 'session.create'), false)
  assert.equal(calls.some(call => call.method === 'prompt.submit'), false)
  assert.deepEqual(opens, [
    {
      id: 'durable-1',
      params: {
        profile: 'ops',
        intent: 'main',
        awaitHydration: true,
        expectHistory: false,
        keepAllProfilesScope: true,
        retryHydrationTimeoutOnce: true
      }
    }
  ])
})

test('an explicit missing-method envelope is the only compatibility fallback', async () => {
  const calls = []
  resetBotModeTestState({
    openSession: async () => undefined,
    request: async method => {
      calls.push(method)
      if (method === 'profiles.ensure_bot_chat') {
        return { error: { code: -32601, message: 'method not found' } }
      }
      if (method === 'session.create') return { stored_session_id: 'legacy-1', session_id: null }
      if (method === 'profiles.configure') return { applied: { ui_meta: true } }
      throw new Error(`unexpected ${method}`)
    }
  })

  assert.equal(await botMode.createCanonicalChat('ops'), 'legacy-1')
  assert.deepEqual(calls, [
    'profiles.ensure_bot_chat',
    'session.create',
    'profiles.configure'
  ])
})

test('transient ensure failure does not fall back to visible legacy creation', async () => {
  const methods = []
  resetBotModeTestState({
    openSession: async () => undefined,
    request: async method => {
      methods.push(method)
      if (method === 'profiles.ensure_bot_chat') throw new Error('gateway timeout')
      throw new Error(`unexpected ${method}`)
    }
  })

  await assert.rejects(() => botMode.createCanonicalChat('ops'), /gateway timeout/)
  assert.deepEqual(methods, ['profiles.ensure_bot_chat'])
})
