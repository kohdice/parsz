# parsz 実装 TODO

この文書は `todo.md` の日本語版です。

## 作業ルール

- [ ] 各フェーズは 1 本の PR として出せる大きさに保つ。
- [ ] この TODO は、`plan_jp.md` にある 4 つのデリバリーフェーズをレビューしやすい PR 単位へ分解したものとして保つ。
- [ ] 以下の番号付きフェーズは PR フェーズであり、`plan_jp.md` にあるデリバリーフェーズ番号の 1 対 1 の言い換えではないことを明示する。
- [ ] フェーズごとの詳細なテスト移植計画は `test_jp.md` に保つ。
- [ ] Zig 標準ライブラリのみを使う。
- [ ] CLI 定義における唯一の真実の源として、スキーマフィールドのラッパー型を保つ。
- [ ] 呼び出し側が所有する `argv` から借用した文字列値のゼロコピー動作を維持する。
- [ ] 振る舞いを追加した PR には、同じ PR でテストも追加する。
- [ ] コードコメントとプロジェクト文書は英語のまま保つ。

## MVP の境界

- [ ] MVP では環境変数統合を追加しない。
- [ ] MVP では設定ファイル読み込みを追加しない。
- [ ] MVP ではシェル補完生成を追加しない。
- [ ] MVP では map を追加しない。
- [ ] MVP ではネストした埋め込みオプショングループを追加しない。
- [ ] MVP では豊富なバリデーションフックやカスタムデコーダーを追加しない。
- [ ] MVP では繰り返しオプション値を追加しない。
- [ ] MVP では `-vvv` のような繰り返し短縮カウントフラグを追加しない。
- [ ] MVP では大文字小文字を区別しない enum パースを追加しない。
- [ ] MVP では `Flag(false)`、`?T = null`、空の繰り返し位置引数スライスを超えるユーザー指定 non-null デフォルト値を追加しない。

## Phase 1 / PR 1: ライブラリ骨格と公開スキーマラッパーを立ち上げる

Goal

- [x] 初期ソース構成と公開スキーマ宣言 API を確立する。

Scope

- [x] 計画で示した初期モジュール構成を追加する:
  - [x] `src/parsz.zig`
  - [x] `src/field.zig`
  - [x] `src/schema.zig`
  - [x] `src/parsed.zig`
  - [x] `src/parse.zig`
  - [x] `src/convert.zig`
  - [x] `src/deinit.zig`
  - [x] `src/error.zig`
  - [x] `test/schema_declaration_test.zig`
- [x] ライブラリテストをコンパイル・実行するために必要な最小限の Zig エントリ / テスト配線を追加する。

Implementation TODO

- [x] 想定している公開 API 面を `src/parsz.zig` から export する。
- [x] 単一の公開パース API 契約を `src/parsz.zig` に固定する:
  - [x] `pub fn parse(comptime Schema: type, allocator: std.mem.Allocator, argv: []const []const u8) ParseError!Parsed(Schema)`
  - [x] `pub fn deinit(comptime Schema: type, allocator: std.mem.Allocator, value: *Parsed(Schema)) void`
- [x] ある解析で確保が不要でも、公開 API では allocator 受け取りを明示のまま維持する。
- [x] プロセス引数の取得はパース API に入れず、ライブラリは呼び出し側から渡された `argv` だけを解析するようにする。
- [x] 公開ラッパーコンストラクタを `src/field.zig` に定義する:
  - [x] `Flag(meta)`
  - [x] `Option(T, meta)`
  - [x] `Positional(T, meta)`
  - [x] `Subcommand(T)`
- [x] ラッパー型が公開する内部コンパイル時計約を定義する:
  - [x] field kind
  - [x] parsed value type
  - [x] field metadata
- [x] MVP に必要なメタデータ形状を定義する:
  - [x] field-level metadata
  - [x] command-level `meta`
  - [x] ルートコマンドの `meta` は `name`、`version`、`about` をサポートする
  - [x] サブコマンドペイロードの `meta` は `about` をサポートする
- [x] 代表的なルートコマンドスキーマとサブコマンドスキーマに対する compile-only smoke test を追加する。

Exit Criteria

- [x] ユーザーが公開ラッパー型を使って CLI スキーマを宣言できる。
- [x] 公開される型レベル契約が、後続 PR の土台として十分に安定している。

## Phase 2 / PR 2: `Parsed(Schema)` 型生成を実装する

Goal

- [x] 宣言的スキーマ型から、素直な実行時値型を生成する。

Implementation TODO

- [x] `src/parsed.zig` に `Parsed(Schema)` を実装する。
- [x] コマンドスキーマ struct を、素直なパース済み struct へ変換する。
- [x] `Flag(...)` を `bool` に変換する。
- [x] `Option(T, ...)` を `T` に変換する。
- [x] `Positional(T, ...)` を `T` に変換する。
- [x] `Subcommand(union(enum))` を、再帰変換されたパース済みタグ付き union に変換する。
- [x] スキーマペイロードで宣言された optional 型をそのまま維持する。
- [x] スキーマペイロードで宣言された繰り返し位置引数スライス形状をそのまま維持する。

Tests

- [x] 代表的なパース済み型形状に対する正常系テストを追加する。
- [x] ネストしたサブコマンド結果型のテストを追加する。
- [x] optional と繰り返し位置引数結果型のテストを追加する。

Exit Criteria

- [x] `parsz.Parsed(Schema)` が、後続の parser / cleanup work の土台として十分に安定している。

## Phase 3 / PR 3: スキーマ抽出とコンパイル時バリデーションを実装する

Goal

- [x] 正規化済みスキーマメタデータを抽出し、不正なスキーマ定義をコンパイル時に拒否する。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 3 Checklist` に従う。

Implementation TODO

- [x] リフレクションを使って `src/schema.zig` にスキーマ抽出を実装する。
- [x] `parse` から `validateSchema(Schema)` を実行する。
- [x] `Parsed(Schema)` が不完全な実行時型を作る前に、サポート対象外のスキーマ形状を拒否する唯一の経路としてバリデーション経路を確立する。
- [x] struct ではないルートスキーマを拒否する。
- [x] tuple struct を拒否する。
- [x] `parsz` スキーマフィールド型ではないフィールドを拒否する。
- [x] `Option` と `Positional` のサポート対象ペイロード型を検証する。
- [x] 1 つのコマンドスコープ内で重複する long name を検証する。
- [x] 1 つのコマンドスコープ内で重複する short name を検証する。
- [x] 位置引数の順序規則を検証する:
  - [x] 可変長位置引数の後に位置引数を置かない
  - [x] 任意位置引数の後に必須位置引数を置かない
- [x] 各コマンドスキーマが高々 1 つの `Subcommand(...)` フィールドしか持たないことを検証する。
- [x] `Subcommand(T)` がタグ付き union を受け取ることを検証する。
- [x] 各サブコマンドペイロードがコマンドスキーマ struct であることを検証する。
- [x] 同一スコープ内の重複サブコマンド名を検証する。
- [x] コマンドメタデータ規則を検証する:
  - [x] ルートコマンドスキーマは `name`、`version`、`about` を定義できる
  - [x] サブコマンドペイロードスキーマは `about` を定義できる
  - [x] サブコマンドペイロードスキーマは独立した `version` 値を定義しない
- [x] MVP では `help` と `version` のような予約名を拒否する。
- [x] 省略されたメタデータを正規化する:
  - [x] long name はフィールド名から補う
  - [x] subcommand name は union フィールド名から補う
  - [x] value name はフィールド名を大文字化して補う
- [x] 位置引数順序はフィールド宣言順から取り、公開の位置インデックスは別に持たない。
- [x] 失敗箇所が明確に分かる、フィールド修飾付き `@compileError` メッセージを生成する。

Tests

- [x] 正規化メタデータ既定値に対する正常系テストを追加する。
- [x] 妥当な位置引数順序に対する正常系テストを追加する。
- [x] サポート対象フィールド種別ごとに焦点を絞ったバリデーションテストを追加する。
- [x] 詳細な upstream バリデーション seed を `test_jp.md` で追跡する。

Exit Criteria

- [x] 不正スキーマが、実用的な診断とともにコンパイル時に即座に失敗する。
- [x] 後続の実行時パーサー実装が、正規化済み抽出スキーマデータに依存できる。

## Phase 4 / PR 4: スカラー変換と基本実行時パーサーを実装する

Goal

- [x] 単一コマンドスコープに対して、フラグ、オプション、位置引数を解析する。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 4 Checklist` に従う。

Implementation TODO

- [x] `src/error.zig` に実行時パースエラーを実装する。
- [x] `src/convert.zig` にスカラー変換ヘルパーを実装する:
  - [x] 整数は `std.fmt.parseInt`
  - [x] 浮動小数点は `std.fmt.parseFloat`
  - [x] enum は `std.meta.stringToEnum`
  - [x] bool は `true` / `false` から変換する
  - [x] 文字列風の値は `argv` から借用する
- [x] `src/parse.zig` にパーサー状態機械を実装する。
- [x] `argv[0]` を飛ばし、`argv[1..]` を解析する。
- [x] `--` 終端子を追跡する。
- [x] `std.StaticStringMap(...).initComptime(...)` でコンパイル時 long option 参照表を構築する。
- [x] long option をサポートする:
  - [x] `--name=value`
  - [x] `--name value`
- [x] 短いオプションとフラグをサポートする:
  - [x] `-v`
  - [x] `-o value`
- [x] 位置引数を宣言順に消費する。
- [x] 省略された `Option(?T, ...)` は `null` として扱う。
- [x] 省略された `Positional(?T, ...)` は `null` として扱う。
- [x] 次の実行時エラーを報告する:
  - [x] unknown option
  - [x] missing option value
  - [x] missing required positional
  - [x] unexpected argument
  - [x] duplicate single-use option
  - [x] invalid scalar value
- [x] `argv` から借用する文字列結果はゼロコピーのまま保つ。

Tests

- [x] 単純なフラグに対する実行時テストを追加する。
- [x] 必須および任意オプションに対する実行時テストを追加する。
- [x] 任意位置引数の省略に対する実行時テストを追加する。
- [x] 位置引数の解析順序に対する実行時テストを追加する。
- [x] `--` 処理に対する実行時テストを追加する。
- [x] enum パースに対する実行時テストを追加する。
- [x] 詳細な upstream 実行時 seed を `test_jp.md` で追跡する。

Exit Criteria

- [x] 繰り返し位置引数とサブコマンドを含まない単一コマンドスキーマを、端から端まで解析できる。

## Phase 5 / PR 5: 繰り返し位置引数、確保所有権、`deinit` を追加する

Goal

- [ ] 所有権モデルを壊さずに、動的な位置引数スライスをサポートする。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 5 Checklist` に従う。

Implementation TODO

- [ ] `[]const T` ペイロードに対する繰り返し位置引数パースを実装する。
- [ ] パーサーが所有するスライスストレージだけを確保する。
- [ ] 可能な限り、スカラー値と借用文字列値をゼロコピーのまま保つ。
- [ ] 採用した表現に応じて必要なら、パーサー所有確保の追跡を実装する。
- [ ] `src/deinit.zig` に再帰的クリーンアップを実装する。
- [ ] `deinit` がパーサー所有の確保だけを解放することを保証する。
- [ ] 空の繰り返し位置引数はエラーではなく空スライスになることを保証する。
- [ ] 任意位置引数と繰り返し位置引数の挙動が、バリデーションで強制される順序規則に違反しないことを確認する。

Tests

- [ ] 繰り返しスカラー位置引数に対する実行時テストを追加する。
- [ ] 繰り返し文字列位置引数に対する実行時テストを追加する。
- [ ] パーサー所有スライスに対する確保とクリーンアップのテストを追加する。
- [ ] 空の繰り返し位置引数結果のテストを追加する。
- [ ] 詳細な繰り返し位置引数 seed カバレッジを `test_jp.md` で追跡する。

Exit Criteria

- [ ] 動的スライスが正しく動作し、`parsz.deinit` で安全に後始末できる。

## Phase 6 / PR 6: サブコマンド解析と再帰的コマンドスコープを追加する

Goal

- [ ] ルートコマンドと同じスキーマ規則で、ネストしたコマンドツリーをサポートする。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 6 Checklist` に従う。

Implementation TODO

- [ ] コンパイル時サブコマンド参照表を構築する。
- [ ] サブコマンド名の検索には `std.StaticStringMap(...).initComptime(...)` を使う。
- [ ] subcommand フィールドに到達したら、選ばれたペイロードスキーマへ再帰する。
- [ ] スキーマ抽出で定義した正規化済みサブコマンド命名規則を維持する。
- [ ] `Parsed(Schema)` で定義された変換済みタグ付き union 形状を返す。
- [ ] unknown subcommand エラーを、正しいコマンドスコープ文脈付きで報告する。
- [ ] サブコマンドペイロード内部でも、オプション / 位置引数パース動作が正しいことを確認する。

Tests

- [ ] 1 段サブコマンドの実行時テストを追加する。
- [ ] ネストしたサブコマンドペイロード解析の実行時テストを追加する。
- [ ] unknown subcommand エラーの実行時テストを追加する。
- [ ] ルートオプションとサブコマンドローカル引数を組み合わせた実行時テストを追加する。
- [ ] 詳細なサブコマンド seed カバレッジを `test_jp.md` で追跡する。

Exit Criteria

- [ ] ルートコマンドとサブコマンドが、一貫した 1 つの解析 / 検証モデルを共有する。

## Phase 7 / PR 7: 診断を改善し、compile-fail フィクスチャを追加する

Goal

- [ ] スキーマ失敗と実行時失敗を、デバッグしやすく、退行しにくくする。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 7 Checklist` に従う。

Implementation TODO

- [x] フィクスチャベースの compile-fail テストハーネスを追加する。
- [x] 不正フィクスチャのカバレッジを追加する:
  - [x] ラッパーでないフィールド型
  - [x] 名前重複
  - [x] サポート対象外のペイロード型
  - [x] 不正なサブコマンド定義
  - [x] 不正な位置引数順序
- [ ] パース失敗に対する実行時診断ペイロードまたは整形ヘルパーを追加する。
- [ ] エラーメッセージのフィールドパス明確性と文言の一貫性を見直す。
- [ ] 再利用可能な `argv` テストヘルパーを `src/testing.zig` に追加する。
- [ ] `test_jp.md` で選定した upstream バリデーション seed を、個別の compile-fail フィクスチャへ変換する。

Exit Criteria

- [ ] コンパイル時失敗と実行時失敗の両方に対して、安定した回帰防止カバレッジがある。

## Phase 8 / PR 8: MVP 後の help/version サポート

Goal

- [ ] コアパーサーが安定した後に、ユーザー向け help と version 出力を追加する。
- [ ] 実装順序の作業分解は `test_jp.md` の `PR 8 Checklist` に従う。

Implementation TODO

- [ ] `name`、`version`、`about` のメタデータ配線を最終化する。
- [ ] 正規化済みスキーマメタデータから help テキスト生成を実装する。
- [ ] ルートコマンドメタデータから version 出力生成を実装する。
- [ ] `help` と `version` の MVP 予約名挙動を維持する。
- [ ] help / version 出力の snapshot 形式テストを追加する。
- [ ] 新しい UX を含むように README の使用例を更新する。
- [ ] コアパーサーが安定した後に、`test_jp.md` の詳細な help / version snapshot seed を見直す。

Exit Criteria

- [ ] help と version 出力が、同じスキーマ上の唯一の真実の源から生成される。

## フェーズ横断レビュー用チェックリスト

- [ ] PR の並びが `plan_jp.md` の 4 つのデリバリーフェーズへ追跡可能なままである。
- [ ] 各 PR が、それ単体で公開 API を一貫的かつレビュー可能に保っている。
- [ ] 各 PR に、新しく追加した振る舞いをカバーするテストが含まれている。
- [ ] ゼロコピー保証がコードとテストで明示されたままである。
- [ ] 確保の所有権がコードとテストで明示されたままである。
- [ ] 不正スキーマに対する第一防衛線として、コンパイル時バリデーションが維持されている。

## 参考資料

- [ ] `plan.md`
- [ ] `plan_jp.md`
- [ ] `README.md`
- [ ] `test.md`
- [ ] `test_jp.md`
