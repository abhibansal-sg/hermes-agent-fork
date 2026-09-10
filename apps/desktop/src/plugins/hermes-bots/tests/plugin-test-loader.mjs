const componentNames = [
  'Button',
  'Checkbox',
  'Codicon',
  'ContextMenu',
  'ContextMenuContent',
  'ContextMenuItem',
  'ContextMenuSeparator',
  'ContextMenuTrigger',
  'ConfirmDialog',
  'CopyButton',
  'Dialog',
  'DialogContent',
  'DialogDescription',
  'DialogFooter',
  'DialogHeader',
  'DialogTitle',
  'DropdownMenu',
  'DropdownMenuContent',
  'DropdownMenuItem',
  'DropdownMenuTrigger',
  'EmptyState',
  'GlyphSpinner',
  'Input',
  'ScrollArea',
  'SearchField',
  'Select',
  'SelectContent',
  'SelectItem',
  'SelectTrigger',
  'SelectValue',
  'Switch',
  'Textarea',
  'Tip',
  'McpTab',
  'ToolsetConfigPanel',
  'SkillsView',
  'Streamdown'
]

const sdkSource = `
export function atom(initial) {
  let value = initial
  const listeners = new Set()
  return {
    get: () => value,
    set: next => {
      value = next
      for (const listener of listeners) listener(next)
    },
    listen: listener => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}
export const host = {
  state: {
    profile: atom('default'),
    connectionId: atom('local'),
    activeSessionId: atom(null),
    focusedSessionId: atom(null),
    focusedStoredSessionId: atom(null),
    focusedSessionProfile: atom('default')
  }
}
export const cn = (...values) => values.filter(Boolean).join(' ')
export const COMPOSER_AREAS = { atCompletions: 'atCompletions', middleware: 'middleware' }
export const PALETTE_AREA = 'palette'
export const profileColor = () => '#000'
export const relativeTime = () => ''
export const haptic = () => undefined
export const queryClient = { getQueryData: () => undefined, setQueryData: () => undefined }
export const useQuery = () => ({})
export const useValue = value => value?.get?.()
export const blobatarSvg = undefined
export const createBudgetedLoop = undefined
${componentNames.map(name => `export const ${name} = () => null`).join('\n')}
`

const reactSource = `
export const useEffect = () => undefined
export const useRef = value => ({ current: value })
export const useState = value => [value, () => undefined]
`

const jsxSource = `
export const jsx = (type, props, key) => ({ type, props, key })
export const jsxs = jsx
`

const modules = {
  '@hermes/plugin-sdk': sdkSource,
  react: reactSource,
  'react/jsx-runtime': jsxSource
}

const dataUrl = source => `data:text/javascript,${encodeURIComponent(source)}`

export async function resolve(specifier, context, nextResolve) {
  const source = modules[specifier]
  if (source) {
    return { url: dataUrl(source), shortCircuit: true }
  }

  return nextResolve(specifier, context)
}
