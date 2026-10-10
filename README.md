# hoverchain.nvim 🔎

**Go のホバーに出てきた型やメソッドを、その場で `K` で辿る。**

```text
srv.Files で K
  → ホバーを表示（カーソルはソースに残る）
  → もう一度 K でホバー内に入る
    → FilesService にカーソルを置いて K
      → List にカーソルを置いて K
        → FilesListCall にカーソルを置いて K
```

ホバー内でも gopls を使ってドキュメントと定義位置を取得します。同名の型を全文検索して選ぶ方式ではありません。標準ライブラリ、依存パッケージ、自分のパッケージの型・フィールド・メソッド、埋め込みから昇格したメソッドを辿れます。

## 使い方

Go ファイルで gopls が接続されると、バッファの `K` を置き換えます。最初の `K` はホバーの表示だけで、カーソルはソースに残ります。続けてコードを移動・編集するとホバーは閉じます。

もう一度 `K` を押すとホバー内に入ります。型名やメソッド名まで `hjkl`、`w`、`/` などで移動し、さらに `K` でドキュメントを辿ってください。読み込み中にもう一度 `K` を押した場合も、表示が完了するとホバー内に入ります。

| ホバー内のキー | 操作 |
| --- | --- |
| `K` / `Enter` | カーソル下の型・メソッド・フィールドのドキュメントへ進む |
| `gd` | カーソル下の識別子の実装・定義へ移動し、ホバーを閉じる |
| `Ctrl-o` | 前のドキュメントに戻る。最初のページなら閉じる |
| `q` / `Esc` | ホバーを閉じる |

`:Hoverchain` で開くこともできます。`:HoverchainClose` は処理中のリクエストも取り消して閉じます。元のソースファイルは編集しません。

## インストール

lazy.nvim:

```lua
{
  "wisteriahuman/hoverchain.nvim",
  ft = "go",
  cmd = { "Hoverchain", "HoverchainClose" },
  opts = {},
}
```

Go の `K` だけをプラグインが設定します。他の言語のホバーは変更しません。Noice が通常のホバーを担当する構成でも、Go のホバーには独立したウィンドウを使います。

Nix / Home Manager で Neovim の設定ファイルを管理している場合も、上の GitHub リポジトリ名をそのまま使えます。開発用ディレクトリを `dir` で指定する必要はありません。lazy.nvim の `lazy-lock.json` を保存すれば、取得するコミットも固定できます。Nix からプラグイン本体を取得する構成では、同じ公開リポジトリを `fetchFromGitHub` 等で固定してください。

## 設定

```lua
require("hoverchain").setup({
  keymap = "K", -- false にするとソースバッファのキー設定をしない
  border = "rounded",
  max_width = 100,
  max_height = 30,
})
```

| 設定 | 既定値 | 意味 |
| --- | --- | --- |
| `keymap` | `"K"` | gopls が接続された Go バッファで使うキー。`false` で無効 |
| `border` | `"rounded"` | `nvim_open_win` の枠線設定 |
| `max_width` | `100` | ホバーの最大幅 |
| `max_height` | `30` | ホバーの最大行数 |
| `mock` | `false` | gopls 不要の UI デモ |

自分でキーを割り当てる場合:

```lua
require("hoverchain").setup({ keymap = false })
vim.keymap.set("n", "<leader>gh", require("hoverchain").hover,
  { desc = "Go のドキュメントを辿る" })
```

## 必要なもの・対応範囲

- Neovim **0.11 以降**
- **gopls 0.21 以降**を、名前 `gopls` の LSP クライアントとして接続していること
- gopls が使える Go 環境
- gopls の通常の Markdown ホバー。`hoverKind = "FullDocumentation"` と pkg.go.dev のリンクを有効にする標準設定を想定

外部の Lua ライブラリや Go 用 Tree-sitter パーサーは不要です。Markdown の Tree-sitter パーサーがあれば、ホバーのハイライトにも使います。

名前のある Go ソースファイルから使ってください。Go のシグネチャ中の型・メソッド・フィールドと、gopls が生成したソースへのドキュメントリンクを対象にしています。シグネチャの引数名、型パラメーター、任意の文章に書かれた名前を、元のローカルスコープで解決する機能はありません。cgo の `C` 識別子や、アクセスできない依存パッケージの非公開シンボルも対象外です。

解決できない場合は通知を出し、現在のページを維持します。プロジェクト全体の曖昧な名前検索へはフォールバックしません。

## 仕組み

gopls は Go ドキュメント参照（`[http.Client.Do]` など）に対する Hover / Definition を提供します。hoverchain は接続中の gopls のワークスペース内に **メモリ上だけの Go ファイル**を開き、表示中の定義のパッケージと import を使って参照を問い合わせます。ファイルをディスクへ作ったり、元のソースにコメントを追記したりはしません。ホバーを閉じると、問い合わせ用ファイルも gopls へ `didClose` します。

`gd` でモジュールキャッシュや標準ライブラリのソースへ移動した後も、問い合わせ用ファイルはプロジェクト側に置きます。同じ gopls で最後に使ったワークスペース内の Go ファイル、または接続中のワークスペース内の Go バッファを使います。利用できるファイルがない場合は、その旨を通知します。

問い合わせ用ファイルの unused import などの診断は表示しません。元のソースファイルの診断はそのまま扱います。gopls 0.21 以降のドキュメント内ソースリンクは、リンク先の正確な位置へ直接問い合わせます。

## 開発・検証

```sh
make test
```

単体テストと実際の gopls を使った結合テストを実行します。結合テストの Go モジュールは標準ライブラリとリポジトリ内の fixture だけを使います。

主な検証対象: 最初の `K` でフォーカスを維持、二度目の `K` で移動、プレビューの自動終了、import alias、別パッケージの同名型、メソッドと戻り値の型、昇格したメソッド、ドキュメントリンク、履歴、`gd` 後の依存パッケージ内でのホバー、閉じる途中の非同期処理、未保存バッファの import、元ファイルの未変更。

gopls なしの UI デモ:

```sh
nvim -u NONE --cmd 'set rtp+=.' \
  '+lua require("hoverchain").setup({ mock = true })' '+Hoverchain'
```

## ライセンス

MIT

参考: [Go のドキュメント参照](https://go.dev/doc/comment#doclinks)、[gopls 0.21 のホバー内リンク対応](https://github.com/golang/tools/blob/master/gopls/doc/release/v0.21.0.md)。
