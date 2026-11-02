# emacs_debug リファクタリング計画

作成日: 2026-07-09
対象ブランチ: `re-implementation-emacs` (7f7dd74 時点)

## 現状の構成

```
lib/emacs_debug.rb                       # 公開 API (debug / open_error / available?) + 設定 + Lisp 生成 + クライアント選択
lib/emacs_debug/socket_client.rb         # Unix ドメインソケット経由の Emacs server クライアント
lib/emacs_debug/tcp_client.rb            # TCP (server-use-tcp) 経由のクライアント + auth ハンドシェイク
lib/emacs_debug/emacs_server_protocol.rb # 共有ワイヤプロトコル (quote / read_reply / Error)
lib/emacs_debug/version.rb
bin/emacs-server-file-for-docker         # Docker 向け server file 書き換えスクリプト
docker/verify.rb, Dockerfile             # 手動検証用
```

コードベースは小さく（lib 配下 約 300 行）、直近のコミットで emacsclient 依存の除去まで
完了している。この計画は「機能追加なしで、安全性・重複・責務分離・検証体制を整える」
ことを目的とする。

## 課題一覧

### A. バグ・安全性（優先度: 高）

1. **Elisp 文字列へのエスケープ漏れ（実質バグ）**
   `lib/emacs_debug.rb` の `open_and_highlight` / `display_in_buffer` は
   `file` やバッファ名を Lisp 文字列リテラルにそのまま埋め込んでいる。
   `elisp_escape` が適用されるのは `text` のみ。
   ファイルパスに `"` や `\` が含まれると Lisp が壊れる（例: Windows パス、
   `"` を含むディレクトリ名）。攻撃というより誤動作の問題だが、修正必須。

2. **`debug` と `open_error` の実行モデルが非対称**
   `debug` は `Thread.new` で fire-and-forget（例外はスレッド内で握り潰される）、
   `open_error` は同期実行。意図的なら理由をコメント/README に明記し、
   そうでなければどちらかに揃える。少なくともスレッド内の例外が
   `Thread.report_on_exception` 経由で警告を吐かないよう明示的に処理する。

3. **`eval_lisp` の全クライアント失敗が無音**
   両クライアントが `EmacsServerProtocol::Error` を投げた場合、何も起きずに終わる。
   デバッグツールとしては「届いたつもりが届いていない」が一番困るので、
   `warn` 一行程度のフォールバック通知を入れる（設定でオフにできる形でも良い）。

### B. 重複の解消（優先度: 中）

4. **SocketClient / TcpClient の構造重複**
   両者は以下をコピーしている:
   - `Error = EmacsServerProtocol::Error` のエイリアス
   - ENV 変数の解決規則（「`/` を含めば絶対パス、含まなければデフォルトディレクトリ配下の名前」
     — `EMACS_SOCKET_NAME` / `EMACS_SERVER_FILE` で同一ロジック）
   - `available?` → `eval(lisp, timeout: 10)` という同一インターフェイス
   - `timeout: 10` のマジックナンバー

   対応: モジュールシングルトンをやめてクラス化し、共通部を基底クラス
   （または `EmacsServerProtocol` への吸い上げ）に寄せる。
   クライアントが 2 つしかないので抽象化はしすぎない — 「ENV 名前解決」と
   「デフォルトタイムアウト定数」の共有までに留めるのが現実的。

5. **クライアント一覧の重複**
   `EmacsDebug.available?` と `eval_lisp` がそれぞれ
   `SocketClient` / `TcpClient` を列挙している。優先順位という暗黙の仕様
   （Unix ソケット優先）もここに埋まっている。
   `CLIENTS = [SocketClient, TcpClient].freeze` のような定数に一本化する。

### C. 責務分離（優先度: 中）

6. **`lib/emacs_debug.rb` に責務が集中**
   トップレベルモジュールが「公開 API」「設定 (app_root 等)」「Lisp コード生成」
   「クライアント選択・フォールバック」の 4 役を担っている。分割案:

   - `EmacsDebug::Lisp` — `quote`(escape) / `open_and_highlight` /
     `display_in_buffer` などの Lisp スニペット生成を集約。
     エスケープを生成側で強制できるので課題 1 の再発防止にもなる。
   - `EmacsDebug::Configuration` — `app_root` / `container_root` / `host_root` と
     パス変換 (`resolve_path`)。`EmacsDebug.configure { |c| ... }` 形式は
     やりすぎなので、単純な設定オブジェクト + 委譲で十分。
   - トップレベルは `debug` / `open_error` / `available?` と
     クライアントへのディスパッチだけを残す。

### D. 検証体制・ツーリング（優先度: 高、ただし前提作業）

7. **テストが存在しない**
   Gemfile は gemspec を読むだけで、テストフレームワークも Rakefile もない。
   上記のリファクタリングを安全に進める前提として最初に整備する。
   テストしやすい箇所から:
   - `EmacsServerProtocol.quote` / `read_reply`（`UNIXSocket.pair` でソケットを模擬、
     タイムアウト・EOF・分割到着をカバー）
   - `TcpClient` の server file パース（正常系 / 欠損 / 不正フォーマット）
   - パス解決（ENV による `socket_path` / `server_file_path` の分岐）
   - `resolve_path` の container→host 変換
   - Lisp 生成のエスケープ（課題 1 の回帰テスト）

   フレームワークは minitest を推奨（依存最小、gem の規模に見合う）。

8. **スタイル不統一**
   `lib/emacs_debug.rb` はダブルクォート、クライアント 2 ファイルはシングルクォート。
   RuboCop（または standard gem）を入れて CI 相当（`rake test` + lint）を
   ローカルタスクとして揃える。gemspec に `spec.homepage` / `spec.license` が
   ないのもこのタイミングで直す。

### E. 対象外（やらないこと）

- `read_reply` の `-print ` / `-error ` 部分一致による早期 return の厳密化
  （コメントにある通り `&-` エスケープにより誤検知しないことが保証済み。触らない）
- クライアントのプラガブル化・第三のトランスポート対応（需要が出てから）
- `bin/emacs-server-file-for-docker` の Ruby 化（独立した bash スクリプトとして
  完結しており、リファクタリング対象の Ruby コードと結合していない）

## 実施フェーズ

依存関係順。各フェーズは独立してコミット・レビュー可能な粒度にする。

### Phase 0: テスト基盤（課題 7）
1. minitest + Rakefile を追加、`bundle exec rake test` を通す
2. 現状の挙動を固定する特性テストを書く（protocol / パース / パス解決）

**完了条件**: 既存挙動がテストで固定され、以降のフェーズで回帰を検知できる。

### Phase 1: 安全性修正（課題 1–3）
1. `Lisp` モジュールを新設し、すべての埋め込み値（file, line, バッファ名, text）を
   エスケープ経由に統一（課題 6 の一部を前倒し）
2. `debug` / `open_error` の同期・非同期方針を決めて統一、スレッド内例外を処理
3. 全クライアント失敗時の `warn` を追加

**完了条件**: `"` や `\` を含むパスでも Lisp が壊れないテストが通る。

### Phase 2: 重複解消（課題 4–5）
1. `CLIENTS` 定数へ一本化（優先順位のコメント付き）
2. クライアントのクラス化 + ENV 名前解決とデフォルトタイムアウトの共通化

**完了条件**: SocketClient / TcpClient の diff が「トランスポート固有部分」だけになる。

### Phase 3: 責務分離の仕上げ（課題 6 残り）
1. `Configuration` 抽出、`resolve_path` を移動
2. トップレベル `emacs_debug.rb` を API + ディスパッチのみに縮小

**完了条件**: `lib/emacs_debug.rb` が 60 行程度に収まり、各ファイルの責務が 1 つになる。

### Phase 4: ツーリング（課題 8）
1. RuboCop/standard 導入、クォートスタイル統一
2. gemspec のメタデータ補完（homepage / license / metadata）

## リスクと検証

- 変更はすべて内部構造で、公開 API（`debug` / `open_error` / `available?` /
  3 つの設定アクセサ、ENV 変数の意味）は変えない。
- ワイヤプロトコル層（`quote` / `read_reply` / auth ハンドシェイク）は
  Phase 0 のテストで挙動を固定してからのみ触る。
- 各フェーズ完了時に `docker/verify.rb` の手動検証（サーバなし / TCP サーバあり）を
  README の手順どおり実行して実機確認する。
