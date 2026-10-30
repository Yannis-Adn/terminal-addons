import { expect, test } from 'claude-code/testing'

const BAND = {
  plugin: 'pinned-prompt',
  component: 'AbovePrompt',
  props: {
    hasSurvey: false,
    isWorking: false,
    maxRows: 12,
    bodyColumns: 60,
    scroll: { offset: 0, bodyRows: 11 },
    view: {},
  },
} as const

const TYPED = { wait: false, origin: { kind: 'composer' } } as const

test('the band pins the last message and unfolds from the pin', async ($, on) => {
  // Nothing sits beneath the plugin: these hooks stand for the engine.
  on('prompt.submit', (_, e) => ({ text: e.text, origin: { kind: 'composer' } }))
  on('settings.read', () => ({ value: { language: 'French' } }))

  await $.prompt.submit({ text: 'Premier sujet', ...TYPED })
  await $.prompt.submit({ text: 'Corrige la page Identité\net relance les tests', ...TYPED })

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...BAND, surface })

    expect((await ui.find({ type: 'Text', text: /Identité/ }))?.text).toBe('Corrige la page Identité')
    expect((await ui.find({ type: 'Text', text: /ligne/ }))?.text).toBe(' +1 ligne')
    expect(await ui.find({ type: 'Text', text: /📌 Toi ▸/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Premier sujet/ })).toBeUndefined()

    await ui.press({ key: 'toggle' })

    expect(await ui.find({ type: 'Text', text: /📌 Toi ▾/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Premier sujet/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /relance les tests/ })).toBeDefined()

    await ui.press({ key: 'toggle' })
    await ui.unmount()
  }
})

test('labels are English unless Claude Code speaks French', async ($, on) => {
  on('prompt.submit', (_, e) => ({ text: e.text, origin: { kind: 'composer' } }))
  on('settings.read', () => ({ value: {} }))

  await $.prompt.submit({ text: 'Fix the login page', ...TYPED })

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect(await ui.find({ type: 'Text', text: /📌 You ▸/ })).toBeDefined()
  await ui.unmount()
})

test('nothing is drawn before a message is typed', async ($, on) => {
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)

    return <Text>engine</Text>
  })

  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' })

  expect((await ui.find({ type: 'Text' }))?.text).toBe('engine')
  await ui.unmount()
})
