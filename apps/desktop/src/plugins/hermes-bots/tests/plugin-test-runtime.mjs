import { register } from 'node:module'

register(new URL('./plugin-test-loader.mjs', import.meta.url), import.meta.url)

export const sdk = await import('@hermes/plugin-sdk')
const plugin = await import(new URL('../plugin.js', import.meta.url))

export const botMode = plugin.default.__test

export function resetBotModeTestState({ openSession, request, requestProfile } = {}) {
  botMode.state.$botMeta.set({})
  botMode.state.$groupChats.set({})
  botMode.state.$lastRoster.set([])
  sdk.host.request = request || (async () => ({}))
  sdk.host.openSession = openSession
  sdk.host.requestProfile = requestProfile || (async (_route, method, params) => sdk.host.request(method, params))
  sdk.host.state.connectionId.set('local')
  sdk.host.state.activeSessionId.set(null)
  sdk.host.state.focusedSessionId.set(null)
  sdk.host.state.focusedStoredSessionId.set(null)
  sdk.host.state.focusedSessionProfile.set('default')
  sdk.host.notify = () => undefined
  globalThis.window = { setTimeout: callback => callback() }
}
