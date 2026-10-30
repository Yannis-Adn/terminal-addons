// The messages the person typed in this session, newest last.
export type PinnedPromptList = readonly string[]

declare module 'claude-code' {
  interface PluginState {
    'pinned-prompt': { prompts: PinnedPromptList; isOpen: boolean }
  }
}
