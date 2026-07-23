# panepilot.nvim

[English](README.md)

`panepilot.nvim` は、[editprompt](https://github.com/eetann/editprompt) でAIコーディングエージェント宛のプロンプトを書くときに、続きを補完するNeovimプラグインです。
送信先のtmuxまたは[Herdr](https://herdr.dev/)ペインを取得し、既知のAPIキー形式と機密情報を示すキー名に対応する値をマスキングしてから、ターミナルの文脈と入力中のプロンプトを基に最大3件の候補を生成します。
選択中の候補は複数行のghost textとして表示し、OpenAIとClaudeのAPIバックエンドでは同じ候補群をnvim-cmpにも提供できます。

`EDITPROMPT=1` かつfiletypeが `markdown.editprompt` の場合にだけ動作します。
既定のキーマップは設定しません。

## 必要環境

- Neovim 0.11以降
- tmuxまたはHerdr
- OpenAIバックエンド：curl 8.3以降と `PANEPILOT_API_KEY`
- Claudeバックエンド：curl 8.3以降と `PANEPILOT_API_KEY`
- Codexバックエンド：`codex` コマンド
- 任意の補完フロントエンド：[nvim-cmp](https://github.com/hrsh7th/nvim-cmp)

## インストール

lazy.nvimでは次のように設定します。

```lua
{
  'yuki-yano/panepilot.nvim',
  dependencies = { 'hrsh7th/nvim-cmp' },
  config = function()
    require('panepilot').setup()
  end,
}
```

ghost textだけを使う場合はnvim-cmpの依存を省き、`cmp.enabled = false` を設定します。

## 設定

次の値が既定値です。

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

`n_candidates` には1から3までの整数を指定します。
`max_candidate_lines` と `max_candidate_chars` はすべてのバックエンドに適用し、任意の正の整数へ変更できます。
モデルには両方の上限内で自然に完結するよう指示し、超過した応答は表示またはnvim-cmpへの受け渡し前に切り詰めます。

`system_prompt` を省略すると組み込みpromptを使います。
空でない文字列を指定するとその内容へ差し替え、関数を指定すると解決済みの生成設定を基に動的なpromptを返せます。

```lua
require('panepilot').setup({
  system_prompt = function(ctx)
    return ctx.default_prompt .. '\n現在の文を簡潔に続けることを優先してください。'
  end,
})
```

関数には `backend`、`n_candidates`、`max_candidate_lines`、`max_candidate_chars`、`default_prompt` を渡します。
関数は補完リクエストごとに同期的に1回実行し、Codexバックエンドでは `n_candidates` が `1` になります。
関数は空でない文字列を返す必要があり、エラーまたは不正な戻り値があるとその補完を中止して `:PanepilotLog` に記録します。
解決したpromptはOpenAI、Claude、Codexのすべてに適用し、補完キャッシュの識別にも含めます。

`context.mask_patterns` にはLuaパターンのルールと変換関数を指定できます。
これらのルールは組み込みのマスキング後に実行します。

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

`PanepilotGhost` は既定で `Comment` に、`PanepilotSpinner` は `Special` にリンクします。

`cmp.dismiss_ghost_on_menu_open` は既定で2つの補完UIを排他表示にします。
`false` にするとnvim-cmpメニューの表示中や新しい候補の要求中もPanepilotのghost textを保持し、後述のキーマップ例ではnvim-cmpの選択項目よりghost textを先に確定します。

## バックエンド

### OpenAI

OpenAIは既定のバックエンドで、手動補完、自動補完、nvim-cmpに対応します。
curlからResponses APIを呼び出し、`n_candidates` 件の候補を生成します。

APIキーは `openai.api_key_env` で指定した環境変数からだけ読み取ります。
`OPENAI_API_KEY` へのフォールバックはありません。

```sh
export PANEPILOT_API_KEY='...'
```

### Claude

ClaudeバックエンドはMessages APIを使い、手動補完、自動補完、nvim-cmpに対応します。
既定モデルは現行のClaude Haiku 4.5エイリアスで、`n_candidates` 件の候補を生成します。

```sh
export PANEPILOT_API_KEY='...'
```

```lua
require('panepilot').setup({ backend = 'claude' })
```

APIキーは `claude.api_key_env` で指定した環境変数からだけ読み取り、ほかの環境変数へのフォールバックは行いません。
OpenAIとClaudeを切り替えるときは、選択したサービスが発行したキーを `PANEPILOT_API_KEY` に設定します。

### Codex

Codexバックエンドは手動補完だけに対応し、候補を1件返します。

```lua
require('panepilot').setup({ backend = 'codex' })
```

`codex exec` を読み取り専用サンドボックスで実行し、プロンプト全体をstdinから渡します。

## キーマップ

次の例は、editpromptバッファ専用のnvim-cmp設定とbuffer-localキーマップを作成します。
Tabチェーンはghost textの確定、nvim-cmpの確定、手動補完の順に処理します。

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
        -- <Cmd> を返し、expr評価後にtextlockの外でacceptを実行します。
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

この設定では、空のeditpromptバッファの行頭でもTabに3つの役割を持たせます。
タブ文字を入力する場合は `<C-v><Tab>` を使います。

## 動作

- Panepilotは `HERDR_ENV=1` または `HERDR_ACTIVE_PANE_ID` からHerdrを判定し、それ以外では `TMUX_PANE` からtmuxを判定します。両方の環境が検出された場合はHerdrを優先します。
- tmuxでは、tmux option `@editprompt_target_panes` の先頭に登録されたペインを送信先として使います。
- Herdrでは、`EDITPROMPT_TARGET_PANE` を送信先として使います。editpromptはこの環境変数をエディタプロセスへ渡す必要があり、PanepilotはHerdrのactive paneやeditor paneから送信先を推測しません。
- Herdrの文脈は `herdr pane read <pane> --source recent-unwrapped --lines <context.lines>` で取得します。
- 自動補完はOpenAIまたはClaudeのAPIバックエンドで動作し、`auto_trigger.debounce_ms` の経過後、ペインの内容が `auto_trigger.pane_quiet_sec` の間変化していないことを確認して実行します。
- 空のdraftを含む各行の行頭では、自動ghost textとnvim-cmpからの自動リクエストを開始せず、`trigger()` またはnvim-cmpの手動補完を実行した場合だけ候補を取得します。
- nvim-cmpのメニュー表示中またはskkeletonの有効中は、自動ghost textを抑制します。
- skkeletonの有効中は、panepilotのnvim-cmpソースから自動バックエンドリクエストを開始しません。`<C-Space>` などによる手動nvim-cmp補完は実行します。
- HTTP 429を受けると、新しい自動ghost textと自動nvim-cmpリクエストを停止し、`resume_auto()` が呼ばれるまで再開しません。手動補完は停止しません。
- 手動補完が200 msを超えると、カーソルの右側に1セル幅のspinnerを表示します。
- 自動補完とnvim-cmpからのリクエストではspinnerを表示しません。
- ghost textとspinnerはバッファ本文を変更しない仮想装飾であり、ghost textの先頭行とspinnerを `overlay` で描画するため、表示しても実カーソルは移動しません。
- カーソル移動、テキスト変更、挿入モードの終了、バッファ移動、`dismiss()` の呼び出しは、実行中のリクエストをキャンセルして表示を消します。
- nvim-cmpのメニューを開くと既定では補完UIの重複を避けるためghost textを消し、`cmp.dismiss_ghost_on_menu_open = false` を指定すると保持します。

## プライバシー

各リクエストには、マスキング済みの送信先ペインの文脈と、カーソル位置を示すマーカーを加えたeditpromptの全文を含めます。
`context.mask_patterns` を含むマスキングは取得したペイン文脈だけに適用し、editpromptの本文はマスキングせずに送信します。
組み込みルールは長い `sk-...` トークンと、名前が `key`、`token`、`secret`、`password`、`passwd`、`credential` で終わるキーに対応する値をマスキングします。
マスキングはすべての機密情報の除去を保証しません。
機密情報を扱う環境では `:PanepilotDebugContext` で送信予定のペイン文脈を確認し、必要な `context.mask_patterns` を追加してください。

OpenAIとClaudeのリクエストでは、curlが環境変数からAPIキーを展開し、JSONリクエスト本体をstdinから読み取ります。
APIキーとJSONリクエスト本体はcurlのプロセス引数に含めません。
Codexにもstdinからプロンプトを渡します。

## コマンドとLua API

| コマンド | 説明 |
| --- | --- |
| `:PanepilotDebugContext` | バックエンドへ送るマスキング済みのペイン文脈を開きます。 |
| `:PanepilotLog` | メモリ上の診断ログを開きます。ログファイルは作成しません。 |
| `:checkhealth panepilot` | `EDITPROMPT`、選択中のmultiplexer、送信先ペイン、すべてのバックエンドの依存、設定を確認します。 |

| 関数 | 説明 |
| --- | --- |
| `setup(opts)` | プラグインを設定して有効化します。 |
| `trigger()` | 手動補完を開始します。 |
| `visible()` | カーソル位置にghost textが表示されているか返します。 |
| `accept()` | 選択中の候補を確定します。 |
| `accept_word()` | 次の文字クラス単位を確定します。 |
| `accept_line()` | 次の行単位を確定します。 |
| `dismiss()` | 実行中のリクエストをキャンセルし、ghost textまたはspinnerを消します。 |
| `next_candidate()` | 次の候補を選択します。 |
| `prev_candidate()` | 前の候補を選択します。 |
| `resume_auto()` | HTTP 429による停止後に自動ghost textとnvim-cmpを再開します。 |

各関数は `require('panepilot')` から呼び出します。
ヘルプ全体は `:help panepilot` で参照できます。

## ライセンス

MIT
