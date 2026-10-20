# emacs_debug

*[English](README.md) · 日本語*

Emacs と連携して Ruby アプリケーションをデバッグするライブラリ。Ruby プロセス内で注目すべきイベントが起きたとき、実行中の Emacs で該当ソースファイルを開き、発火箇所の行をハイライトし、専用バッファにデバッグ出力や例外メッセージを表示する。`binding.pry` や `byebug` で対話セッションを張る必要はない。

Emacs とは直接通信する。Emacs が同一マシン上にあれば Unix ドメインソケット経由、別環境にあれば（たとえば Docker コンテナ内からホスト側の Emacs へ接続する場合）TCP サーバ経由で、Emacs 自身のサーバプロトコルを純粋な Ruby 実装で話す。どちらの経路でも `emacsclient` バイナリは不要で使われない。

## 動作要件

- Ruby >= 3.1
- サーバを起動した状態の Emacs（`M-x server-start`、または初期設定ファイルに `(server-start)` を記述）

## インストール

Gemfile に追加する:

```ruby
gem "emacs_debug"
```

または、このリポジトリから直接インストールする（RubyGems.org には未公開）:

```ruby
gem "emacs_debug", git: "https://github.com/phigasui/emacs_debug"
```

## 使い方

```ruby
require "emacs_debug"

EmacsDebug.debug("hello from Ruby") # 呼び出し元の箇所を Emacs で開き、テキストを *Debug* バッファに表示する
```

```ruby
begin
  raise "boom"
rescue => e
  EmacsDebug.open_error(e) # アプリ内の最初のバックトレースフレームを開き、メッセージを *Error* バッファに表示する
end
```

`EmacsDebug.available?` は現在 Emacs に接続可能かどうか（ローカルソケットまたは TCP サーバファイルが存在するか）を返す。Emacs に到達できない場合、`debug` / `open_error` は何もしない（no-op）ため、条件分岐なしでそのまま呼び出して問題ない。

### 設定

| 設定項目 | デフォルト値 | 用途 |
| --- | --- | --- |
| `EmacsDebug.app_root=` | Rails 定義時は `Rails.root/app/` | `open_error` で開くバックトレースフレームをこのパス配下に限定する |
| `EmacsDebug.container_root=` | Rails 定義時は `Rails.root/` | **このプロセス**から見たチェックアウトのルート（例: コンテナ内の `/app/`） |
| `EmacsDebug.host_root=` | `ENV["EMACS_DEBUG_HOST_ROOT"]` | Emacs プロセスから見た同じチェックアウトのルート。コンテナ内パスをホスト側パスへ変換するために使う |

`container_root` と `host_root` は、Ruby と Emacs が別々の環境で動いている場合（典型的には Ruby が Docker 内、Emacs がホスト上）にのみ設定すればよい。

### Emacs 側でのカスタマイズ (`init.el`)

`emacs_debug` は Emacs 側の設定が一切なくてもそのまま動作するが、ダークテーマ向けにハイライト色を変えたい場合や、ファイルの開き方・バッファの表示方法を変更したい場合は、`init.el` で以下の変数を設定できる:

| Emacs 変数 | デフォルト値 | 用途 |
| --- | --- | --- |
| `emacs-debug-highlight-face` | `'(:background "#ffff00")` | ハイライト行のオーバーレイに適用する face シンボルまたは属性リスト（新しいハイライトを作成する際、バッファ内の前回の `emacs-debug` オーバーレイは自動的に消去される） |
| `emacs-debug-open-file-function` | `nil`（`find-file` + オーバーレイ） | `(funcall emacs-debug-open-file-function file line)` として呼び出されるカスタム関数 |
| `emacs-debug-buffer-mode` | `#'special-mode` | `*Debug*` / `*Error*` バッファで有効化するメジャーモード関数 |
| `emacs-debug-display-buffer-function` | `nil`（`get-buffer-create` + `display-buffer`） | `(funcall emacs-debug-display-buffer-function buf-name file line text)` として呼び出されるカスタム表示関数 |

`init.el` での設定例:

```elisp
;; テーマ標準の `highlight' フェイスを使う（またはダークテーマ向けの属性リストを指定）
(setq emacs-debug-highlight-face 'highlight)

;; ファイルの開き方をカスタマイズする例（別ウィンドウで開いて pulse.el で一時ハイライト）
(setq emacs-debug-open-file-function
      (lambda (file line)
        (find-file-other-window file)
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter)
        (pulse-momentary-highlight-one-line (point))))
```

## Rails 連携

Rails の例外ページは通常の `raise` / `rescue` の経路を通らないため、代わりに `ActionDispatch::DebugExceptions` にフックする。`config/initializers/emacs_debug.rb` を追加する:

```ruby
if defined?(EmacsDebug)
  ActionDispatch::DebugExceptions.register_interceptor do |_request, exception|
    EmacsDebug.open_error(exception)
  end
end
```

これにより、development 環境でリクエスト処理中に例外が発生するたび、Emacs で例外発生箇所のファイルが開き、エラーメッセージが表示される。

## Docker 内で Ruby、ホスト上で Emacs を動かす場合

Rails アプリが Docker 内で動き、Emacs がホストマシン上で動いている場合、Unix ドメインソケットはコンテナ境界を越えられない。代わりに `emacs_debug` を TCP サーバへ向ける:

1. ホスト側で Emacs を起動する前に以下を設定する:

   ```elisp
   (setq server-use-tcp t)
   (setq server-host "0.0.0.0") ; またはより限定したバインドアドレス
   (server-start)
   ```

2. コンテナから `host.docker.internal` 経由でホストへ到達できるよう、サーバファイルを書き換える:

   ```sh
   bin/emacs-server-file-for-docker
   ```

   これで本来のサーバファイルの隣に `~/.emacs.d/server/docker` が生成される（デフォルト値を上書きするには引数に `HOST`、`SOURCE`、`DEST` を渡す。詳細はスクリプト先頭のコメントを参照）。

3. 生成したファイルをコンテナにマウントし、`EMACS_SERVER_FILE` で指定する:

   ```sh
   docker run --rm \
     -v ~/.emacs.d/server/docker:/server/docker:ro \
     -e EMACS_SERVER_FILE=/server/docker \
     -e EMACS_DEBUG_HOST_ROOT=/Users/me/myapp/ \
     your-app-image
   ```

   `EMACS_DEBUG_HOST_ROOT`（`EmacsDebug.host_root=` 参照）を指定すると、`emacs_debug` はコンテナ内のパス（例: `/app/models/user.rb`）をホストファイルシステム上の対応するパスへ変換するため、Emacs が実際にファイルを見つけて開けるようになる。

コンテナイメージ内に `emacsclient` バイナリは不要。`emacs_debug` が直接 TCP サーバプロトコルを話す。

## Docker 構成の動作確認

`docker/verify.rb` と同梱の `Dockerfile`（`emacsclient` は一切インストールしない）で、両方のシナリオを確認できる:

```sh
# 接続先サーバなし（no-op の確認）
docker build -t emacs_debug_verify .
docker run --rm emacs_debug_verify

# ホストの TCP サーバを指定
docker run --rm -e EMACS_SERVER_FILE=/server/docker \
  -v ~/.emacs.d/server/docker:/server/docker:ro \
  emacs_debug_verify
```
