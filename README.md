# panepilot.nvim

[日本語](README.ja.md)

`panepilot.nvim` completes prompts written for AI coding agents in [editprompt](https://github.com/eetann/editprompt).
It captures the destination tmux pane, masks likely secrets, and generates up to three continuations from the terminal context and the current draft.
The selected candidate is shown as multiline ghost text, and the OpenAI and Claude API backends can expose the same candidate set through nvim-cmp.

The plugin is active only when `EDITPROMPT=1` and the current filetype is `markdown.editprompt`.
It does not install keymaps.

## Requirements

- Neovim 0.11+
- tmux
- OpenAI backend: curl 8.3+ and `PANEPILOT_API_KEY`
- Claude backend: curl 8.3+ and `PANEPILOT_API_KEY`
- Codex backend: the `codex` executable
- Optional completion frontend: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)

## Installation

With lazy.nvim:

```lua
{
  'yuki-yano/panepilot.nvim',
  dependencies = { 'hrsh7th/nvim-cmp' },
  config = function()
    require('panepilot').setup()
  end,
}
```

Omit the nvim-cmp dependency and set `cmp.enabled = false` if only ghost text is needed.

## Configuration

The following values are the defaults:

```lua
require('panepilot').setup({
  backend = 'openai',
  openai = {
    model = 'gpt-5.6-luna',
    reasoning_effort = 'none',
    max_output_tokens = 400,
    api_key_env = 'PANEPILOT_API_KEY',
    timeout_ms = 10000,
  },
  claude = {
    model = 'claude-haiku-4-5',
    max_tokens = 400,
    api_key_env = 'PANEPILOT_API_KEY',
    timeout_ms = 10000,
  },
  codex = {
    model = 'gpt-5.3-codex-spark',
    reasoning_effort = 'low',
    timeout_ms = 30000,
  },
  context = {
    lines = 300,
    mask_patterns = {},
  },
  auto_trigger = {
    enabled = true,
    debounce_ms = 800,
    pane_quiet_sec = 3,
  },
  n_candidates = 3,
  max_candidate_lines = 2,
  max_candidate_chars = 80,
  system_prompt = nil,
  cmp = {
    enabled = true,
    dismiss_ghost_on_menu_open = true,
  },
})
```

`n_candidates` must be an integer from 1 to 3.
`max_candidate_lines` and `max_candidate_chars` apply to every backend and may be set to any positive integer.
The prompt asks the model to finish naturally within both limits; overlong responses are truncated before display or nvim-cmp delivery.

`system_prompt` uses the built-in prompt when omitted.
A non-empty string replaces it directly, while a function receives the resolved generation settings and may return a dynamic replacement:

```lua
require('panepilot').setup({
  system_prompt = function(ctx)
    return ctx.default_prompt .. '\nPrefer a concise answer that continues the current sentence.'
  end,
})
```

The function receives `backend`, `n_candidates`, `max_candidate_lines`, `max_candidate_chars`, and `default_prompt`.
It runs synchronously once per completion request, and `n_candidates` is `1` for the Codex backend.
It must return a non-empty string; an error or invalid return value cancels that completion and is recorded by `:PanepilotLog`.
The resolved prompt applies to OpenAI, Claude, and Codex and is included in the completion cache identity.

`context.mask_patterns` accepts Lua pattern rules and transformation functions.
They run after the built-in masking rules:

```lua
require('panepilot').setup({
  context = {
    mask_patterns = {
      { pattern = 'private%-%d+', replace = '<masked-id>' },
      function(text)
        return text:gsub('internal.example.com', '<masked-host>')
      end,
    },
  },
})
```

`PanepilotGhost` links to `Comment` by default, and `PanepilotSpinner` links to `Special`.

`cmp.dismiss_ghost_on_menu_open` keeps the two completion UIs mutually exclusive by default.
Set it to `false` to retain Panepilot ghost text while the nvim-cmp menu is visible or requests new candidates; the keymap example below accepts ghost text before the selected nvim-cmp item.

## Backends

### OpenAI

OpenAI is the default backend and supports manual completion, automatic completion, and nvim-cmp.
It calls the Responses API through curl and generates `n_candidates` candidates.

The API key is read only from `openai.api_key_env`; there is no fallback to `OPENAI_API_KEY`.

```sh
export PANEPILOT_API_KEY='...'
```

### Claude

The Claude backend supports manual completion, automatic completion, and nvim-cmp through the Messages API.
Its default model is the current Claude Haiku 4.5 alias, and it generates `n_candidates` candidates.

```sh
export PANEPILOT_API_KEY='...'
```

```lua
require('panepilot').setup({ backend = 'claude' })
```

The API key is read only from `claude.api_key_env`; no other environment variable is used as a fallback.
When switching between OpenAI and Claude, set `PANEPILOT_API_KEY` to the key issued by the selected service.

### Codex

The Codex backend supports manual completion only and returns one candidate.

```lua
require('panepilot').setup({ backend = 'codex' })
```

It runs `codex exec` in a read-only sandbox and passes the complete prompt over stdin.

## Keymaps

The following example configures nvim-cmp and buffer-local keymaps only for editprompt buffers.
The Tab chain accepts ghost text, confirms nvim-cmp, or triggers manual completion:

```lua
local cmp = require('cmp')

cmp.setup.filetype('markdown.editprompt', {
  sources = cmp.config.sources({
    { name = 'panepilot' },
  }),
})

vim.api.nvim_create_autocmd('FileType', {
  pattern = 'markdown.editprompt',
  callback = function(event)
    local panepilot = require('panepilot')
    local buffer = event.buf

    vim.keymap.set('i', '<C-]>', panepilot.dismiss, { buffer = buffer, desc = 'Panepilot: dismiss' })
    vim.keymap.set('i', '<M-w>', panepilot.accept_word, { buffer = buffer, desc = 'Panepilot: accept word' })
    vim.keymap.set('i', '<M-l>', panepilot.accept_line, { buffer = buffer, desc = 'Panepilot: accept line' })
    vim.keymap.set('i', '<M-n>', panepilot.next_candidate, { buffer = buffer, desc = 'Panepilot: next candidate' })
    vim.keymap.set('i', '<M-p>', panepilot.prev_candidate, { buffer = buffer, desc = 'Panepilot: previous candidate' })

    vim.keymap.set('i', '<Tab>', function()
      if panepilot.visible() then
        -- <Cmd> runs accept after expression evaluation, outside textlock.
        return '<Cmd>lua require("panepilot").accept()<CR>'
      end
      if cmp.visible() then
        return '<Cmd>lua require("cmp").confirm({ select = true })<CR>'
      end
      return '<Cmd>lua require("panepilot").trigger()<CR>'
    end, { buffer = buffer, expr = true, silent = true, desc = 'Panepilot: accept or trigger' })
  end,
})
```

This mapping gives Tab three roles, including at the start of an empty editprompt buffer.
Use `<C-v><Tab>` to insert a literal tab.

## Behavior

- The first pane in tmux option `@editprompt_target_panes` is used as the destination pane.
- Automatic completion uses the OpenAI or Claude API backend after `auto_trigger.debounce_ms` and waits until the pane has been unchanged for `auto_trigger.pane_quiet_sec`.
- At the start of any line, including an empty draft, automatic ghost completion and automatically triggered nvim-cmp requests stay idle; `trigger()` and manually invoked nvim-cmp completion remain available.
- Automatic ghost text is suppressed while the nvim-cmp menu is visible or skkeleton is enabled.
- Automatic backend requests from panepilot's nvim-cmp source are suppressed while skkeleton is enabled. Manual nvim-cmp completion such as `<C-Space>` remains available.
- HTTP 429 pauses new automatic ghost text and automatic nvim-cmp requests until `resume_auto()` is called; manual completion remains available.
- Manual completion shows a one-cell spinner one cell to the right of the cursor after 200 ms. Automatic and nvim-cmp requests do not show it.
- Ghost text and the spinner are virtual decorations that do not change buffer text or move the real cursor; the first ghost line and spinner use overlays.
- Moving the cursor, changing text, leaving insert mode, leaving the buffer, or calling `dismiss()` cancels the current request and removes its UI.
- Opening the nvim-cmp menu removes ghost text by default to avoid overlapping completion UIs; set `cmp.dismiss_ghost_on_menu_open = false` to retain it.

## Privacy

Each request includes the masked tmux context and the complete editprompt draft with a cursor marker.
Masking, including `context.mask_patterns`, applies only to the captured tmux context; the editprompt draft is sent without masking.
Built-in masking covers long `sk-...` tokens and key/value fields whose names end in `key`, `token`, `secret`, `password`, `passwd`, or `credential`.
Masking is best-effort; use `:PanepilotDebugContext` and custom `context.mask_patterns` to verify sensitive environments.

For OpenAI and Claude requests, curl expands the API key from the environment and reads the JSON body from stdin, so neither value is placed in curl's process arguments.
Codex also receives its prompt through stdin.

## Commands and Lua API

| Command | Description |
| --- | --- |
| `:PanepilotDebugContext` | Open the masked tmux context that would be sent to the backend. |
| `:PanepilotLog` | Open the in-memory diagnostic ring. No log file is written. |
| `:checkhealth panepilot` | Check `EDITPROMPT`, tmux, the target pane, dependencies for all backends, and configuration. |

| Function | Description |
| --- | --- |
| `setup(opts)` | Configure and activate the plugin. |
| `trigger()` | Trigger manual completion. |
| `visible()` | Return whether ghost text is visible at the cursor. |
| `accept()` | Accept the selected candidate. |
| `accept_word()` | Accept the next character-class unit. |
| `accept_line()` | Accept the next line unit. |
| `dismiss()` | Cancel the current request and remove ghost text or the spinner. |
| `next_candidate()` | Select the next candidate. |
| `prev_candidate()` | Select the previous candidate. |
| `resume_auto()` | Resume automatic ghost text and nvim-cmp after an HTTP 429 pause. |

Call these functions through `require('panepilot')`.
See `:help panepilot` for the help reference.

## License

MIT
