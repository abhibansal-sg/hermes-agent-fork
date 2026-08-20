import { register } from 'node:module'

register(new URL('./plugin-test-loader.mjs', import.meta.url), import.meta.url)

export const sdk = await import('@hermes/plugin-sdk')
const plugin = await import(new URL('../plugin.js', import.meta.url))

export const botMode = plugin.__test

export function resetBotModeTestState({ openSession, request, requestProfile } = {}) {
  botMode.state.$botMeta.set({})
  botMode.state.$groupChats.set({})
  botMode.state.$lastRoster.set([])
  sdk.host.request = request || (async () => ({}))
  sdk.host.openSession = openSession
  sdk.host.requestProfile = requestProfile
  sdk.host.notify = () => undefined
  globalThis.window = { setTimeout: callback => callback() }
}
