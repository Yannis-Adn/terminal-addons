import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { PinnedPromptList } from '../types'

const prompts = atom({ plugin: 'pinned-prompt', key: 'prompts' } as const, [] as PinnedPromptList)
const isOpen = atom({ plugin: 'pinned-prompt', key: 'isOpen' } as const, false)

// How many messages the unfolded band lists, and how much of each is kept.
const KEPT = 5
const MAX_CHARS = 4000

const ACCENT = 'suggestion'

// What the engine adds to a user message that the person did not type.
const INJECTED = /<(system-reminder|command-[\w-]+|local-command-[\w-]+)>[\s\S]*?<\/\1>/g
const NOT_TYPED = ['Base directory for this skill', '[Request interrupted', 'Caveat:']

const LABELS = {
  en: {
    you: 'You',
    more: (n: number) => ` +${n} line${n > 1 ? 's' : ''}`,
    title: (n: number) => (n > 1 ? `your last ${n} messages, newest at the bottom` : 'your last message'),
  },
  fr: {
    you: 'Toi',
    more: (n: number) => ` +${n} ligne${n > 1 ? 's' : ''}`,
    title: (n: number) => (n > 1 ? `tes ${n} derniers messages, le plus récent en bas` : 'ton dernier message'),
  },
}

const clean = (text: string) => text.replace(INJECTED, '').trim()

const isTyped = (text: string) => text !== '' && !NOT_TYPED.some(start => text.startsWith(start))

const cut = (text: string, width: number) =>
  text.length <= width ? text : `${text.slice(0, Math.max(0, width - 1))}…`

const firstLine = (text: string) => text.split('\n').find(line => line.trim() !== '')?.trim() ?? ''

// Follows Claude Code's `language` setting: French for French, English otherwise.
const labelsFor = async ($: EngineInterface) => {
  const language = await $.settings.read({ key: 'language' }).catch(() => undefined)

  return typeof language === 'string' && /^(fr|french|fran[cç]ais)/i.test(language) ? LABELS.fr : LABELS.en
}

const remember = ($: EngineInterface, text: string) => {
  const kept = clean(text).slice(0, MAX_CHARS)

  if (!isTyped(kept)) {
    return
  }

  return update($, prompts, list => [...list, kept].slice(-KEPT))
}

export const register: Register = on => {
  on('prompt.submit', async ($, e, next) => {
    if (!e.isMeta && !e.command) {
      await remember($, e.text)
    }

    return next(e)
  }).catch(($, e, next) => next(e))

  // A resumed session (or a reload of the plugin) fills the band from the transcript.
  on('session.start', async ($, e, next) => {
    const result = await next(e)

    if ((await read($, prompts)).length === 0) {
      const typed = (await $.session.messages())
        .filter(message => message.role === 'user' && !message.toolResults?.length)
        .map(message => clean(message.text).slice(0, MAX_CHARS))
        .filter(isTyped)
        .slice(-KEPT)

      if (typed.length > 0) {
        await update($, prompts, () => typed)
      }
    }

    return result
  })

  on('session.end', async ($, e, next) => {
    if (e.reason === 'clear') {
      await update($, prompts, () => [])
      await update($, isOpen, () => false)
    }

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const list = await read($, prompts)
    const last = list.at(-1)

    if (e.props.hasSurvey || last === undefined) {
      return next(e)
    }

    const open = await read($, isOpen)
    const labels = await labelsFor($)
    const { Box, Button, Text } = $.ui.resolve(e)

    // Inside the frame: two border cells and one cell of padding on each side.
    const inner = e.props.bodyColumns - 4
    const pin = `📌 ${labels.you} ${open ? '▾' : '▸'}`

    const toggle = (
      <Button key="toggle" plain onPress={() => update($, isOpen, value => !value)}>
        <Text color={ACCENT} weight="bold">{pin}</Text>
      </Button>
    )

    if (!open) {
      const lineCount = last.split('\n').filter(line => line.trim() !== '').length
      const more = lineCount > 1 ? labels.more(lineCount - 1) : ''
      // The pin is one cell wider than its length: the emoji takes two.
      const room = inner - (pin.length + 1) - 1 - more.length

      return (
        <Box borderStyle="round" borderColor={ACCENT} paddingX={1} flexDirection="row">
          {toggle}
          <Text> </Text>
          <Text wrap="truncate-end">{cut(firstLine(last), room)}</Text>
          <Text dimColor>{more}</Text>
        </Box>
      )
    }

    const earlier = list.slice(0, -1)

    return (
      <Box borderStyle="round" borderColor={ACCENT} paddingX={1} flexDirection="column">
        <Box flexDirection="row">
          {toggle}
          <Text dimColor> {labels.title(list.length)}</Text>
        </Box>
        {earlier.map((text, index) => (
          <Text key={`earlier-${index}`} dimColor wrap="truncate-end">
            {cut(`  · ${firstLine(text)}`, inner)}
          </Text>
        ))}
        <Box flexDirection="row">
          <Text color={ACCENT}>❯ </Text>
          <Text wrap="wrap">{last}</Text>
        </Box>
      </Box>
    )
  })
}
