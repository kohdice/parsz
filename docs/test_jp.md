# parsz テスト計画

この文書は `test.md` の日本語版です。

このファイルは `parsz` のフェーズ指向テスト計画です。
同時に、現在のロードマップに対する正式な upstream 移植監査でもあります。
フェーズごとのチェックリストと監査理由をこの 1 ファイルにまとめることで、
古い調査メモを削除しても実装計画が自己完結したままになるようにします。

## スコープ

この計画は次の文書に従います。

- `plan_jp.md`
- `todo_jp.md`

この計画では、upstream のテストスイートを API 契約としてではなく、参照材料として使います。

- `clap-rs/clap` at `70f3bb31874ff24233f18c394982407ca90d0dcc`
- `alecthomas/kong` at `258b13ac944d17b24a683ff23200933c89555fb7`

## 移植ルール

- 移植するのは振る舞いであって、upstream API ではない。
- テストは `parsz.parse`、`parsz.deinit`、`parsz.Parsed` に対して書き直す。
- upstream の API モデルが異なる場合は、1 対 1 の直訳よりも、小さく Zig らしいフィクスチャを優先する。
- compile-fail バリデーションのカバレッジは独立フィクスチャで保つ。
- 明示的な非目標については upstream カバレッジを移植しない:
  - env
  - config
  - completion
  - clap derive / proc-macro behavior
  - user-defined non-null defaults
  - repeated option values
  - repeated short-count flags
  - aliases
  - conflicts / groups / xor / and
  - custom decoders and custom mapper plumbing

## Phase 1 / PR 1

Phase goal:

- 公開ラッパー型とライブラリ骨格を立ち上げる

Primary local tests:

- 代表的なルートスキーマに対する compile-only smoke test
- 代表的なサブコマンドスキーマに対する compile-only smoke test
- スキーマ抽出に必要な内部 comptime 契約をラッパーコンストラクタが公開していることを確認する compile-only smoke test

Upstream reference value:

- この段階では upstream テストを直接移植しない
- このフェーズの対象は `parsz` の表面形状であり、パーサー挙動ではない
- このフェーズは local-first で進める

Exit expectation:

- ユーザーがパーサー実装詳細に依存せず、安定したコマンドスキーマを宣言できる

## Phase 2 / PR 2

Phase goal:

- `Parsed(Schema)` 型生成を実装する

Primary local tests:

- スキーマ struct -> 素直な parsed struct 変換
- `Flag(...) -> bool`
- `Option(T, ...) -> T`
- `Positional(T, ...) -> T`
- `Subcommand(union(enum))` -> 再帰変換されたタグ付き union
- optional ペイロードの保持
- 繰り返し位置引数スライスの保持

Upstream reference value:

- このフェーズでは upstream スイートを構造上の参考としてのみ使う
- 1 対 1 の upstream 移植を無理に要求しない
- 特に比較価値が高いのは次の点:
  - `kong/model_test.go` にあるネストしたコマンドツリー構造
  - `clap/tests/builder/subcommands.rs` から読み取れるサブコマンド結果形状の期待

Exit expectation:

- `parsz.Parsed(Schema)` が、後続フェーズのパーサーとクリーンアップのテストを支えるだけの安定性を持つ

## Phase 3 / PR 3

Phase goal:

- スキーマ抽出とコンパイル時バリデーション

Must-have local coverage:

- non-struct root を拒否する
- tuple struct を拒否する
- ラッパーでないフィールドを拒否する
- サポート対象外ペイロード型を拒否する
- 重複する long name を拒否する
- 重複する short name を拒否する
- optional positional の後の required positional を拒否する
- 可変長 positional の後の positional を拒否する
- 複数の `Subcommand(...)` フィールドを拒否する
- タグ付き union でない `Subcommand(T)` ペイロードを拒否する
- スキーマでない subcommand ペイロードを拒否する
- 重複する subcommand 名を拒否する
- `help` や `version` のような予約名を拒否する
- long name、subcommand 名、value name を正規化する

Port these upstream seeds:

- `clap/tests/builder/unique_args.rs`
  - duplicate short name
  - duplicate long name
- `clap/tests/builder/positionals.rs`
  - required positional after optional positional
  - positional field must not also claim short / long names
- `clap/tests/builder/subcommands.rs`
  - duplicate subcommand definitions
- `kong/kong_test.go`
  - `TestUnsupportedFieldErrors`
  - `TestInvalidRequiredAfterOptional`
  - `TestDuplicateFlag`
  - `TestDuplicateFlagOnPeerCommandIsOkay`
  - `TestDuplicateShortflags`
  - `TestDuplicateNestedShortFlags`
  - `TestDuplicateName`
  - `TestDuplicateChildName`
  - `TestChildNameCanBeDuplicated`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`
- `kong/tag_test.go`
  - invalid short-flag name as a validation idea only

Implementation note:

- 上の不正ケースは、失敗が comptime のスキーマ解析中に起きる場合、インライン unit test ではなく独立した compile-fail フィクスチャへ変換する

## Phase 4 / PR 4

Phase goal:

- 単一コマンドスコープ向けのスカラー変換と基本実行時パーサー

Must-have local coverage:

- `argv[0]` を飛ばす
- フラグを解析する
- 分離値を取る短いオプションを解析する
- `--name value` 形式の long option を解析する
- `--name=value` 形式の long option を解析する
- 宣言順で positional を消費する
- optional option の省略 -> `null`
- optional positional の省略 -> `null`
- `--` 終端子
- unknown option
- missing option value
- missing required positional
- unexpected argument
- duplicate single-use option
- invalid scalar value
- ゼロコピーの借用文字列結果

Port these upstream seeds:

- `clap/tests/builder/flags.rs`
  - `flag_using_short`
  - `flag_using_long`
  - `flag_using_mixed`
  - `multiple_flags_in_single`
  - `flag_using_long_with_literals`
- `clap/tests/builder/opts.rs`
  - `opts_using_short`
  - `opts_using_long_space`
  - `opts_using_long_equals`
  - `opts_using_mixed`
  - `opts_using_mixed2`
  - `stdin_char`
  - `double_hyphen_as_value`
  - `leading_hyphen_fail`
- `clap/tests/builder/empty_values.rs`
  - empty string with separate value
  - empty string with `--name=`
  - empty string with `-o=`
- `clap/tests/builder/positionals.rs`
  - `only_pos_follow`
  - `positional`
  - `positional_multiple_2`
  - `missing_required_2`
- `clap/tests/builder/error.rs`
  - `kind_formats_validation_error`
  - `rich_formats_validation_error`
  - `unknown_argument_option`
  - `unknown_argument_flag`
- `clap/tests/builder/possible_values.rs`
  - valid enum value
  - invalid enum value
- `clap_lex/tests/testsuite/lexer.rs`
  - `zero_copy_parsing`
- `clap_lex/tests/testsuite/parsed.rs`
  - `to_long_no_value`
  - `to_long_with_empty_value`
  - `to_long_with_value`
  - `to_short`
  - `is_negative_number`
  - `is_escape`
  - `is_stdio`
- `clap_lex/tests/testsuite/shorts.rs`
  - `next_flag`
  - `next_flag_with_value`
  - `next_flag_with_no_value`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestRequiredFlag`
  - `TestOptionalArg`
  - `TestRequiredArg`
  - `TestShort`
  - `TestEnum`
  - `TestEnumMeaningfulOrder`
  - `TestLoneHpyhen`
- `kong/mapper_test.go`
  - `TestSliceConsumesRemainingPositionalArgs`
  - `TestNumbers`
  - `TestValuesThatLookLikeFlags`
- `kong/scanner_test.go`
  - `TestScannerTake`
  - `TestScannerPeek`

Do not port from upstream in this phase:

- clap `posix_compatible.rs` の last-one-wins 上書き挙動
- kong の negatable flag
- kong の alias
- kong の passthrough mode
- kong の map / file mapper

## Phase 5 / PR 5

Phase goal:

- 繰り返し位置引数、所有権、クリーンアップ

Must-have local coverage:

- 繰り返しスカラー位置引数
- 繰り返し文字列位置引数
- 空の繰り返し位置引数
- パーサー所有スライス確保
- 再帰的 `deinit`
- 呼び出し側所有 `argv` から借用した文字列ストレージを解放しない

Port these upstream seeds:

- `clap/tests/builder/positionals.rs`
  - `lots_o_vals`
  - `positional_multiple`
  - `positional_multiple_3`
  - `last_positional`
  - `last_positional_no_double_dash`
  - `last_positional_second_to_last_mult`
- `clap/tests/builder/multiple_values.rs`
  - 繰り返し positional と trailing-value の形だけを使う
  - repeated-option 挙動は移植しない
- `kong/kong_test.go`
  - `TestArgSlice`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`

Implementation note:

- このフェーズでは所有権アサーションが最重要になるため、振る舞いアサーションだけに頼らず、allocator の明示的な会計テストを追加する

## Phase 6 / PR 6

Phase goal:

- 再帰的サブコマンド解析

Must-have local coverage:

- 1 段のサブコマンド
- ネストしたサブコマンド
- unknown subcommand
- ルートオプションとサブコマンドローカル引数の組み合わせ
- オプション値であるべきものが、誤って subcommand として分類されないこと

Port these upstream seeds:

- `clap/tests/builder/subcommands.rs`
  - `subcommand`
  - `subcommand_none_given`
  - `subcommand_multiple`
  - `issue_1031_args_with_same_name`
  - `issue_1031_args_with_same_name_no_more_vals`
  - `issue_1722_not_emit_error_when_arg_follows_similar_to_a_subcommand`
  - `subcommand_after_argument`
  - `issue_2494_subcommand_is_present`
  - `subcommand_not_recognized`
  - `duplicate_subcommand`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestBranchingArgument` は構造上の参考としてのみ使う
  - `TestDuplicateFlagOnPeerCommandIsOkay`

Do not port from upstream in this phase:

- clap alias subcommands
- clap multicall
- clap external subcommands
- kong default commands
- kong dynamic commands

## Phase 7 / PR 7

Phase goal:

- compile-fail フィクスチャと診断改善

Must-have local coverage:

- ラッパーでないフィールド型
- 名前重複
- サポート対象外ペイロード型
- 不正なサブコマンド定義
- 不正な位置引数順序
- 明確な実行時エラーメッセージ
- 再利用可能な argv テストヘルパー

Port these upstream seeds:

- `clap/tests/builder/unique_args.rs`
- `clap/tests/builder/positionals.rs`
- `clap/tests/builder/subcommands.rs`
- `clap/tests/builder/error.rs`
- `kong/kong_test.go`
- `kong/tag_test.go`

Implementation note:

- upstream の文言はカバレッジ形状の参考に使い、完全一致させるべき文字列としては扱わない
- `parsz` は clap や kong の文言をなぞるよりも、実用的な Zig の field-path 診断を優先する

## Phase 8 / PR 8

Phase goal:

- コアパーサー安定後の help / version 出力

Must-have local coverage:

- ルート help 出力
- サブコマンド help 出力
- version 出力
- snapshot 形式の回帰テスト
- `help` と `version` の予約名挙動

Port these upstream seeds:

- `clap/tests/builder/help.rs`
- `clap/tests/builder/version.rs`
- `clap/tests/builder/template_help.rs`
- `clap/tests/builder/hidden_args.rs` where relevant
- `kong/help_test.go`
- `kong/model_test.go`
- `kong/util_test.go` for version-flag shape only

Do not port from upstream in this phase:

- clap の env-aware help
- clap の shell completion snapshot
- clap の man-page snapshot
- `parsz` が明示的に望まない限り、ランタイム version 固有な kong の help wrapping 差分

## 推奨実行順

1. Phase 3 のバリデーションフィクスチャ
2. Phase 4 の基本パーサー実行時テスト
3. Phase 5 の所有権と繰り返し位置引数テスト
4. Phase 6 のサブコマンドテスト
5. Phase 7 の診断と compile-fail ハーネスの強化
6. Phase 8 の help / version snapshot

## 詳細 PR チェックリスト

以下のチェックリストは、意図的に実行順序中心で書かれています。

- 各 PR のチェックリストは、後続 PR に依存せず完了できるべき
- 後続 PR が先行テストを洗練することはあってよいが、先行 PR を成立させるために必須であってはならない

### PR 3 Checklist

Goal:

- 実行時パーサー実装が正規化済みスキーマメタデータを信頼できるだけの local coverage を持った状態で、スキーマ抽出とコンパイル時バリデーションを着地させる

Preparation:

- [x] スキーマ抽出が返す内部の正規化済みスキーマ表現を決める。
- [x] 次の内部表現を決める:
  - [x] command metadata
  - [x] field metadata
  - [x] positional ordering
  - [x] subcommand tables
- [x] `@compileError` メッセージで使う field-path の形式を決める。
- [x] PR 7 の専用 compile-fail ハーネスが入る前に、一時的な不正スキーマフィクスチャをどこへ置くか決める。

Implementation:

- [x] フィールド名推測ではなく、内部 comptime 契約を通じたラッパー型検出を実装する。
- [x] ルートコマンドスキーマのバリデーションを実装する。
- [x] 次の field-kind 抽出を実装する:
  - [x] `Flag`
  - [x] `Option`
  - [x] `Positional`
  - [x] `Subcommand`
- [x] サポート対象 `Option` / `Positional` ペイロードの型検証を実装する。
- [x] `pub const meta` から command metadata 抽出を実装する。
- [x] フィールド名からの long-name 正規化を実装する。
- [x] union フィールド名からの subcommand-name 正規化を実装する。
- [x] フィールド名を大文字化した value-name 正規化を実装する。
- [x] 1 つのコマンドスコープ内での重複 long-name 検証を実装する。
- [x] 1 つのコマンドスコープ内での重複 short-name 検証を実装する。
- [x] 位置引数順序検証を実装する:
  - [x] 可変長 positional の後に positional を置かない
  - [x] optional positional の後に required positional を置かない
- [x] `Subcommand(T)` の検証を実装する:
  - [x] タグ付き union 必須
  - [x] ペイロードはスキーマ struct でなければならない
  - [x] 各 command scope につき subcommand フィールドは 1 つだけ
  - [x] 重複 subcommand 名を拒否する
- [x] `help` と `version` の予約名検証を実装する。
- [x] `parse` が comptime で `validateSchema(Schema)` を起動するようにする。

Tests to add in this PR:

- [x] 正規化既定値に対する正常系 unit test:
  - [x] 推論された long name
  - [x] 推論された value name
  - [x] 推論された subcommand name
- [x] 妥当な positional レイアウトに対する正常系 unit test。
- [ ] 次の異常系バリデーションテスト:
  - [x] non-struct root
  - [x] tuple struct
  - [x] non-wrapper field
  - [x] unsupported payload type
  - [x] duplicate long name
  - [x] duplicate short name
  - [x] positional after variadic positional
  - [x] required positional after optional positional
  - [x] multiple subcommand fields
  - [x] invalid `Subcommand(T)` argument
  - [ ] duplicate subcommand name
  - [x] reserved `help` / `version` names

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/unique_args.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/tag_test.go`

Done when:

- [x] 正規化済みスキーマ抽出がパーサーコードから再利用可能である
- [x] 不正スキーマが、実用的な field-qualified 診断付きで comptime 中に失敗する
- [x] バリデーションカバレッジが実行時パーサー挙動に依存していない

### PR 4 Checklist

Goal:

- スカラー変換と、単一コマンド向けの完全な実行時パーサーを着地させる

Preparation:

- [x] 実行時パーサーの状態構造を決める。
- [x] long option 参照表レイアウトを決める。
- [x] short option 検索戦略を決める。
- [x] 実行時エラーペイロード形状と error set を決める。
- [x] ゼロコピー借用文字列出力をテストでどう主張するか決める。

Implementation:

- [x] 次に対するスカラー変換ヘルパーを実装する:
  - [x] 符号付き整数
  - [x] 符号なし整数
  - [x] 浮動小数点
  - [x] enum
  - [x] bool
  - [x] 借用 `[]const u8`
  - [x] 借用 `[:0]const u8`
- [x] `argv[0]` を飛ばすパーサー起動を実装する。
- [x] `--` 前のトークン処理を実装する。
- [x] `--name=value` を実装する。
- [x] `--name value` を実装する。
- [x] 短いフラグを実装する。
- [x] 分離値を取る短いオプションを実装する。
- [x] 結合された短いフラグクラスタを実装する。
- [x] 宣言順の positional 消費を実装する。
- [x] `--` 終端子処理を実装する。
- [x] 省略時挙動を実装する:
  - [x] flags -> `false`
  - [x] `Option(?T)` -> `null`
  - [x] `Positional(?T)` -> `null`
- [x] 次の実行時失敗を実装する:
  - [x] unknown option
  - [x] missing option value
  - [x] missing required positional
  - [x] unexpected argument
  - [x] duplicate single-use option
  - [x] invalid scalar value
- [x] 文字列値を呼び出し側所有 `argv` から借用したまま保つ。

Tests to add in this PR:

- [x] フラグ解析テスト:
  - [x] short flag
  - [x] long flag
  - [x] short / long 混在フラグ
  - [x] 結合 short flag
  - [x] plain flag に対する明示値を拒否する
- [ ] オプション解析テスト:
  - [x] 分離値を取る short option
  - [x] 分離値を取る long option
  - [x] `=` 付き long option
  - [ ] 値としての `-`
  - [x] 空文字列値
  - [ ] サポートしない場合の leading-hyphen 値拒否
- [x] Positional テスト:
  - [x] 宣言順消費
  - [x] optional positional の省略
  - [x] 非 variadic スキーマで余分な positional はエラーになる
  - [x] 必須 positional 欠落はエラーになる
- [x] 終端子テスト:
  - [x] `--` の後続トークンは positional になる
  - [x] 構文がそう要求しない限り、`--` 自体は値として消費されない
- [ ] スカラー変換テスト:
  - [ ] integer 境界
  - [x] float 解析
  - [x] enum 成功
  - [x] enum 失敗
  - [x] bool option / bool positional の文字列表現
- [x] 借用テスト:
  - [x] パース済み文字列が呼び出し側所有 `argv` を指す
  - [x] 非 slice スカラー出力では確保が不要

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/flags.rs`
- [ ] `clap/tests/builder/opts.rs`
- [ ] `clap/tests/builder/empty_values.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/error.rs`
- [ ] `clap/tests/builder/possible_values.rs`
- [ ] `clap_lex/tests/testsuite/lexer.rs`
- [ ] `clap_lex/tests/testsuite/parsed.rs`
- [ ] `clap_lex/tests/testsuite/shorts.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/mapper_test.go`
- [ ] `kong/scanner_test.go`

Done when:

- [x] サブコマンドや繰り返し位置引数なしで、1 つの command scope を端から端まで解析できる
- [x] 実行時失敗が型付けされ、テストでカバーされている
- [x] スカラー文字列値のゼロコピー挙動がテストで明示されている

### PR 5 Checklist

Goal:

- 繰り返し位置引数、パーサー所有スライスストレージ、クリーンアップを着地させる

Preparation:

- [ ] 繰り返し位置引数の内部蓄積戦略を決める。
- [ ] 確保 bookkeeping の置き場所を決める。
- [ ] `deinit` がどのフィールドがヒープストレージを所有しているかをどう見つけるか決める。
- [ ] リークに敏感なカバレッジ向け allocator-test helper を決める。

Implementation:

- [ ] スカラー payload に対する繰り返し positional 解析を実装する。
- [ ] 借用文字列 payload に対する繰り返し positional 解析を実装する。
- [ ] 繰り返しフィールドには結果 slice ストレージだけを確保する。
- [ ] 繰り返し文字列 slice 内でも、ゼロコピーの文字列要素借用を維持する。
- [ ] 省略された繰り返し positional では空スライスを生成する。
- [ ] 次に対する再帰的 `deinit` を実装する:
  - [ ] parsed struct
  - [ ] parsed tagged union
  - [ ] 繰り返し positional の slice ストレージ
- [ ] `deinit` がパーサー所有確保だけを解放することを保証する。

Tests to add in this PR:

- [ ] 繰り返しスカラー positional テスト:
  - [ ] 多数の値
  - [ ] 0 個の値
  - [ ] 妥当な場合のルートフラグとの混在
- [ ] 繰り返し文字列 positional テスト:
  - [ ] 多数の値
  - [ ] `--` の後の値
  - [ ] trailing-last positional の挙動
- [ ] 所有権テスト:
  - [ ] 繰り返し結果ストレージが確保される
  - [ ] 要素文字列は依然として `argv` を借用する
  - [ ] `deinit` が所有 slice ストレージを解放する
  - [ ] `deinit` が借用 `argv` メモリを解放しない
- [ ] バリデーション相互作用テスト:
  - [ ] 繰り返し positional は最後の positional でなければならない
  - [ ] required-after-optional 規則が引き続き成立する

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/multiple_values.rs` から選んだ繰り返し positional 形状ケース
- [ ] `kong/kong_test.go`

Done when:

- [ ] サポート対象 payload で繰り返し positional が機能する
- [ ] 所有権境界が明示され、回帰テストで守られている
- [ ] `parsz.deinit` が、パーサー所有ストレージに対して必要十分である

### PR 6 Checklist

Goal:

- 共通スキーマモデルの上に、再帰的サブコマンド解析を着地させる

Preparation:

- [ ] コンパイル時 subcommand lookup 表現を決める。
- [ ] 再帰的 parse state を子 command scope へどう渡すか決める。
- [ ] unknown-subcommand 診断文脈形式を決める。

Implementation:

- [ ] 正規化済みスキーマデータから subcommand lookup table を構築する。
- [ ] 次のトークンを subcommand と解釈すべきか検出する。
- [ ] 選ばれたペイロードスキーマへ再帰する。
- [ ] `Parsed(Schema)` で定義される parsed tagged-union 形状を返す。
- [ ] subcommand dispatch 前のルートスコープ option 解析を維持する。
- [ ] dispatch 後の subcommand ローカル option / positional 解析を維持する。
- [ ] command-scope 文脈付きで unknown subcommand エラーを報告する。

Tests to add in this PR:

- [ ] 1 段 subcommand テスト:
  - [ ] 最初の subcommand を選ぶ
  - [ ] 同階層の中から選ぶ
  - [ ] スキーマ形状上 optional な場合に subcommand が未選択でいられる
- [ ] ネスト subcommand テスト:
  - [ ] さらに 1 段再帰する
  - [ ] ネストスコープでローカル引数を解析する
- [ ] 曖昧さ / 分類テスト:
  - [ ] option value は subcommand ではなく option value のままであるべき
  - [ ] スキーマが許す場合、positional value は positional のままであるべき
  - [ ] スキーマが許すなら、先行 positional の後でも subcommand を扱える
- [ ] エラーテスト:
  - [ ] unknown subcommand
  - [ ] 重複 subcommand 定義は引き続き compile-time failure であるべき

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `kong/kong_test.go`

Done when:

- [ ] ルートスコープと subcommand スコープが 1 つのパーサーモデルを共有する
- [ ] パース済み subcommand 結果が `Parsed(Schema)` に一致する
- [ ] エラーカバレッジに command 境界での誤分類が含まれる

### PR 7 Checklist

Goal:

- バリデーション回帰を防げるだけの堅牢な compile-fail ハーネスと、十分に改善された診断を着地させる

Preparation:

- [x] フィクスチャディレクトリ構成を決める。
- [x] compile-fail ケースの命名規則を決める。
- [x] 期待失敗を CI でどう照合するか決める。
- [ ] 実行時テスト向け共有 argv helper API を決める。

Implementation:

- [x] build または test パイプラインに compile-fail ハーネスを実装する。
- [x] 一時的な invalid-schema ケースを専用フィクスチャへ移動する。
- [ ] 再利用可能な argv フィクスチャビルダーを `src/testing.zig` に追加する。
- [ ] 実行時診断ペイロードの整形ヘルパーを追加する。
- [ ] 次に対するエラー文言を正規化する:
  - [ ] compile-time の field-path 診断
  - [ ] runtime parse failure

Fixtures and tests to add in this PR:

- [ ] Compile-fail フィクスチャ:
  - [x] non-wrapper field
  - [x] duplicate long name
  - [x] duplicate short name
  - [x] unsupported payload type
  - [x] invalid subcommand union
  - [x] subcommand payload not a schema struct
  - [ ] duplicate subcommand name
  - [x] required positional after optional positional
  - [x] positional after variadic positional
  - [x] reserved `help`
  - [x] reserved `version`
- [ ] 実行時診断テスト:
  - [ ] unknown option message shape
  - [ ] missing option value message shape
  - [ ] missing required positional message shape
  - [ ] invalid scalar value message shape
  - [ ] unknown subcommand message shape

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/unique_args.rs`
- [ ] `clap/tests/builder/positionals.rs`
- [ ] `clap/tests/builder/subcommands.rs`
- [ ] `clap/tests/builder/error.rs`
- [ ] `kong/kong_test.go`
- [ ] `kong/tag_test.go`

Done when:

- [x] invalid schema 回帰がフィクスチャコンパイルで捕捉される
- [ ] runtime 診断が一貫しており、対処しやすい
- [ ] テストヘルパーが後続 PR の重複を減らす

### PR 8 Checklist

Goal:

- 安定したスキーマとパーサーコアの上に、help と version 出力を着地させる

Preparation:

- [ ] help レンダリングに必要な正規化メタデータ形状を決める。
- [ ] help / version テスト用 snapshot 形式を決める。
- [ ] help レンダリングテストを完全一致文字列で比較するか、正規化済み snapshot で比較するか決める。

Implementation:

- [ ] `name`、`version`、`about` のメタデータ配線を最終化する。
- [ ] ルート help 生成を実装する。
- [ ] subcommand help 生成を実装する。
- [ ] version 出力生成を実装する。
- [ ] `help` と `version` の予約名挙動を維持する。
- [ ] ユーザー向け help / version UX を示す README 例を更新する。

Tests to add in this PR:

- [ ] ルート help snapshot。
- [ ] subcommand help snapshot。
- [ ] ネストした subcommand help snapshot。
- [ ] version output snapshot。
- [ ] help / version 機能を有効にしても予約名バリデーションが維持される。
- [ ] help 出力が、解析と検証と同じ正規化済みスキーマの唯一の真実の源を使う。

Upstream seeds to port in this PR:

- [ ] `clap/tests/builder/help.rs`
- [ ] `clap/tests/builder/version.rs`
- [ ] `clap/tests/builder/template_help.rs`
- [ ] `clap/tests/builder/hidden_args.rs` where relevant
- [ ] `kong/help_test.go`
- [ ] `kong/model_test.go`
- [ ] `kong/util_test.go`

Done when:

- [ ] help / version 挙動が snapshot 回帰テストに十分安定している
- [ ] メタデータが 1 つのスキーマ上の唯一の真実の源から描画される
- [ ] 公開ドキュメントが実際のパーサー挙動と一致している

## 付随文書

- `todo_jp.md`

## Upstream 監査付録

この付録は、upstream 監査の完全な材料をメインのテスト計画の中に保持します。

この付録の目的は、上の PR チェックリストとは異なります。

- PR チェックリストは「次に何を実装するか」を示す
- この付録は、ある upstream 領域が現在スコープ内か、後回しか、対象外かの理由を記録する
- この付録は、採用 / 非採用の判断を正当化できるよう、完全な移植レビューを保存する

### 調査基準

- Local plan: `plan_jp.md`
- Local task breakdown: `todo_jp.md`
- `clap-rs/clap` inspected at `70f3bb31874ff24233f18c394982407ca90d0dcc` (`2026-03-12`, `chore: Release`)
- `alecthomas/kong` inspected at `258b13ac944d17b24a683ff23200933c89555fb7` (`2026-02-07`, `fix: Do not open the default file that might be non existent if the value was already set (#580)`)

### 判定凡例

- `Adopt now`: 現在の `plan_jp.md` / `todo_jp.md` にそのまま移植できる
- `Later`: 後続の計画作業が進んでから有用になる
- `Skip`: スコープ不一致、API 不一致、または MVP での明示的除外により `parsz` には適合しない

### parsz のスコープ基準

現在の計画でいう MVP は次のとおりです。

- Zig 標準ライブラリのみ
- POSIX に着想を得た規則を持つ GNU スタイル解析
- 宣言的ラッパー型: `Flag`、`Option`、`Positional`、`Subcommand`
- コンパイル時スキーマバリデーション
- 呼び出し側所有 `argv` からのゼロコピー借用文字列
- bool / ints / floats / enums / strings に対するスカラー変換
- 繰り返し位置引数スライス
- 再帰的サブコマンド

現在の計画で明示的に除外しているもの:

- 環境変数統合
- 設定読み込み
- シェル補完生成
- カスタムデコーダー / カスタムパーサー
- map
- 繰り返しオプション値
- `-vvv` のような繰り返し短縮カウントフラグ
- conflicts / groups / xor / and のような豊富な関係ロジック
- 狭い MVP 既定値を超える、ユーザー定義 non-null デフォルト値

### 価値の高い移植候補

ここでは、早い段階での取り込み候補として特に価値が高い upstream テストを示します。

#### Phase 3: スキーマ抽出とコンパイル時バリデーション

- `clap/tests/builder/unique_args.rs`
  - duplicate long names
  - duplicate short names
- `clap/tests/builder/subcommands.rs`
  - duplicate subcommand names
- `clap/tests/builder/positionals.rs`
  - required positional after optional positional should fail
  - positional fields must not also have short / long names
- `kong/kong_test.go`
  - `TestUnsupportedFieldErrors`
  - `TestInvalidRequiredAfterOptional`
  - `TestDuplicateFlag`
  - `TestDuplicateFlagOnPeerCommandIsOkay`
  - `TestDuplicateShortflags`
  - `TestDuplicateNestedShortFlags`
  - `TestDuplicateName`
  - `TestDuplicateChildName`
  - `TestChildNameCanBeDuplicated`
  - `TestCumulativeArgumentLast`
  - `TestCumulativeArgumentNotLast`

#### Phase 4: 基本実行時パーサー

- `clap/tests/builder/flags.rs`
  - `flag_using_short`
  - `flag_using_long`
  - `flag_using_mixed`
  - `multiple_flags_in_single`
  - `flag_using_long_with_literals`
- `clap/tests/builder/opts.rs`
  - `opts_using_short`
  - `opts_using_long_space`
  - `opts_using_long_equals`
  - `opts_using_mixed`
  - `opts_using_mixed2`
  - `stdin_char`
  - `double_hyphen_as_value`
  - `leading_hyphen_fail`
- `clap/tests/builder/positionals.rs`
  - `only_pos_follow`
  - `positional`
  - `positional_multiple_2`
  - `missing_required_2`
- `clap/tests/builder/error.rs`
  - `kind_formats_validation_error`
  - `rich_formats_validation_error`
  - `unknown_argument_option`
  - `unknown_argument_flag`
- `clap_lex/tests/testsuite/parsed.rs`
  - `to_long_no_value`
  - `to_long_with_empty_value`
  - `to_long_with_value`
  - `to_short`
  - `is_negative_number`
  - `is_escape`
- `clap_lex/tests/testsuite/shorts.rs`
  - `next_flag`
  - `next_flag_with_value`
  - `next_flag_with_no_value`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestRequiredFlag`
  - `TestOptionalArg`
  - `TestRequiredArg`
  - `TestShort`
  - `TestEnum`
  - `TestEnumMeaningfulOrder`
  - `TestLoneHpyhen`
- `kong/mapper_test.go`
  - `TestSliceConsumesRemainingPositionalArgs`
  - `TestNumbers`
  - `TestValuesThatLookLikeFlags`
- `kong/scanner_test.go`
  - `TestScannerTake`
  - `TestScannerPeek`

#### Phase 5: 繰り返し位置引数と所有権

- `clap/tests/builder/positionals.rs`
  - `lots_o_vals`
  - `positional_multiple`
  - `positional_multiple_3`
  - `last_positional`
  - `last_positional_no_double_dash`
- `clap/tests/builder/multiple_values.rs`
  - repeated-positional / `--` / trailing-value の部分だけを残す
  - repeated-option テストはコピーしない
- `kong/kong_test.go`
  - `TestArgSlice`
  - `TestArgSliceWithSeparator` は、`parsz` が区切り文字で positional 文字列を分割しないことを示す負の参照としてのみ使う

#### Phase 6: サブコマンド

- `clap/tests/builder/subcommands.rs`
  - `subcommand`
  - `subcommand_none_given`
  - `subcommand_multiple`
  - `issue_1031_args_with_same_name`
  - `issue_1031_args_with_same_name_no_more_vals`
  - `subcommand_after_argument`
  - `issue_2494_subcommand_is_present`
  - `subcommand_not_recognized`
  - `duplicate_subcommand`
- `kong/kong_test.go`
  - `TestPositionalArguments`
  - `TestBranchingArgument` は構造参照としてのみ使う
  - `TestDuplicateFlagOnPeerCommandIsOkay`

### Full clap audit

#### リポジトリ全体の判定

- `tests/builder/*`: mixed。再利用しやすい runtime / parser ケースの主な供給源
- `tests/derive/*`: 直接移植としては `Skip`。これらは Rust の derive / proc-macro 挙動に強く結び付いている
- `tests/derive_ui/*` and `tests/derive_ui.rs`: `Skip`。ここでの compile-fail カバレッジは proc-macro 診断の話であり、`@compileError` ベースの Zig スキーマ表面とは異なる
- `tests/ui/*` and `tests/ui.rs`: `Later`。help / version snapshot 挙動に関してのみ後で有用
- `clap_lex/tests/testsuite/*`: `Adopt now`。トークン化とゼロコピー借用の考え方において最も価値が高い upstream ソース
- `clap_complete/tests/*`, `clap_complete_nushell/tests/*`, `clap_mangen/tests/*`: `Skip`。シェル補完と man-page 生成は現在の `parsz` スコープ外

#### `tests/builder/*`

| File                                    | Verdict             | Notes                                                                                                                                    |
| --------------------------------------- | ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `tests/builder/action.rs`               | Skip                | Clap の `ArgAction` API は `parsz` API ではない。中核の bool / set 意味論は他でよりよくカバーできる。                                    |
| `tests/builder/app_settings.rs`         | Later (partial)     | subcommand 必須化と一部の hyphen 処理の考え方だけを残す。推論、external subcommand、global color、その他の clap 固有スイッチは除外する。 |
| `tests/builder/arg_aliases.rs`          | Skip                | alias は現在の計画にない。                                                                                                               |
| `tests/builder/arg_aliases_short.rs`    | Skip                | short alias は現在の計画にない。                                                                                                         |
| `tests/builder/arg_matches.rs`          | Skip                | これは `parsz` の実行時挙動ではなく `clap::ArgMatches` API 形状の話。                                                                    |
| `tests/builder/borrowed.rs`             | Skip                | これは clap builder オブジェクトの再利用を検証しており、ゼロコピーのパース済み値は対象ではない。                                         |
| `tests/builder/cargo.rs`                | Skip                | Cargo メタデータ補助は無関係。                                                                                                           |
| `tests/builder/command.rs`              | Skip                | builder の smoke test であり、`parsz` への価値は低い。                                                                                   |
| `tests/builder/conflicts.rs`            | Skip                | conflicts / exclusivity / groups は MVP 外。                                                                                             |
| `tests/builder/default_missing_vals.rs` | Skip                | missing-value default は MVP 外。                                                                                                        |
| `tests/builder/default_vals.rs`         | Skip                | ユーザー定義 default は MVP 外。                                                                                                         |
| `tests/builder/delimiters.rs`           | Skip                | 主に repeated-option delimiter 挙動であり、`parsz` はこれを除外している。                                                                |
| `tests/builder/derive_order.rs`         | Later               | help / display-order 挙動のみ。                                                                                                          |
| `tests/builder/display_order.rs`        | Later               | help / display-order 挙動のみ。                                                                                                          |
| `tests/builder/double_require.rs`       | Skip                | 複雑な required 条件合成は MVP 外。                                                                                                      |
| `tests/builder/empty_values.rs`         | Adopt now (partial) | 空文字列 option 値と、missing-value エラー優先順位の良い参照元。                                                                         |
| `tests/builder/env.rs`                  | Skip                | 環境変数統合は MVP で明示的に除外。                                                                                                      |
| `tests/builder/error.rs`                | Adopt now (partial) | unknown-argument と missing-value エラー種別の良い参照元。rich formatting は後で役立つ。                                                 |
| `tests/builder/flag_subcommands.rs`     | Skip                | flag subcommand は計画にない。                                                                                                           |
| `tests/builder/flags.rs`                | Adopt now (partial) | short / long / clustered flag 解析の中核。counted / repeated flag 挙動と optional value 付き flag ケースは除外する。                     |
| `tests/builder/global_args.rs`          | Skip                | global-argument 伝播は計画していない。                                                                                                   |
| `tests/builder/groups.rs`               | Skip                | argument group は MVP 外。                                                                                                               |
| `tests/builder/help.rs`                 | Later               | MVP 後の help 生成と整形。                                                                                                               |
| `tests/builder/help_env.rs`             | Skip                | help と env 統合の組み合わせで、どちらも現スコープ外。                                                                                   |
| `tests/builder/hidden_args.rs`          | Later               | help 表示制御のみ。                                                                                                                      |
| `tests/builder/ignore_errors.rs`        | Skip                | error を無視するモードは計画にない。                                                                                                     |
| `tests/builder/indices.rs`              | Skip                | 引数 index bookkeeping は公開 `parsz` 契約の一部ではない。                                                                               |
| `tests/builder/macros.rs`               | Skip                | clap の macro API カバレッジであり、`parsz` の挙動ではない。                                                                             |
| `tests/builder/main.rs`                 | Skip                | テストハーネスのエントリポイントにすぎない。                                                                                             |
| `tests/builder/multiple_occurrences.rs` | Skip                | 繰り返し flag 出現回数カウントは MVP 外。                                                                                                |
| `tests/builder/multiple_values.rs`      | Adopt now (partial) | 繰り返し positional と `--` / trailing parsing ケースを残す。repeated-option や delimiter 依存が強いケースは除外する。                   |
| `tests/builder/occurrences.rs`          | Skip                | grouped occurrences / repeated option grouping は MVP 外。                                                                               |
| `tests/builder/opts.rs`                 | Adopt now (partial) | short / long option、`--name=value`、`--name value`、hyphen に見える値、空 / equals 端ケースの最良の参照元。defaults と推論は除外する。  |
| `tests/builder/positionals.rs`          | Adopt now (partial) | 宣言順消費、`--` 終端子、繰り返し positional、positional バリデーションエラーの最良の参照元。                                            |
| `tests/builder/posix_compatible.rs`     | Skip                | `parsz` は現在、last-one-wins 上書きではなく duplicate single-use option error を望んでいる。                                            |
| `tests/builder/possible_values.rs`      | Adopt now (partial) | enum / allowed-value カバレッジに有用。alias、大文字小文字非区別一致、help レンダリングは除外する。                                      |
| `tests/builder/propagate_globals.rs`    | Skip                | global propagation は計画していない。                                                                                                    |
| `tests/builder/require.rs`              | Later (partial)     | 最も単純な missing-required positional / option カバレッジだけを残す。条件付き required ロジックの大半は MVP 外。                        |
| `tests/builder/subcommands.rs`          | Adopt now (partial) | 再帰 subcommand dispatch、unknown subcommand、重複 subcommand バリデーションの主要参照元。aliases、suggestions、multicall は除外する。   |
| `tests/builder/template_help.rs`        | Later               | help template のみ。                                                                                                                     |
| `tests/builder/tests.rs`                | Adopt now (partial) | コアパーサー成立後のコンパクトな統合組み合わせとして有用。clap 固有の出力配線は除外する。                                                |
| `tests/builder/unicode.rs`              | Skip                | 大文字小文字非区別の possible-values 挙動は明示的に除外している。                                                                        |
| `tests/builder/unique_args.rs`          | Adopt now           | 1 つのコマンドスコープ内の long / short 重複検証に対する直接的な類比。                                                                   |
| `tests/builder/utf16.rs`                | Skip                | OS 固有の UTF-16 / `OsString` 挙動であり、現在の `[]const u8` `parsz` API とは直接対応しない。                                           |
| `tests/builder/utf8.rs`                 | Skip                | 主に invalid-UTF8 / external-subcommand 挙動。現在の `parsz` API は byte-slice ベースで、clap の `OsStr` 行列は対象にしていない。        |
| `tests/builder/utils.rs`                | Skip                | テストヘルパーのみ。                                                                                                                     |
| `tests/builder/version.rs`              | Later               | MVP 後の version flag 挙動。                                                                                                             |

#### `clap_lex/tests/testsuite/*`

| File                                 | Verdict   | Notes                                                                           |
| ------------------------------------ | --------- | ------------------------------------------------------------------------------- |
| `clap_lex/tests/testsuite/lexer.rs`  | Adopt now | `zero_copy_parsing` は `parsz` の借用文字列設計に直結する。                     |
| `clap_lex/tests/testsuite/main.rs`   | Skip      | ハーネスファイルのみ。                                                          |
| `clap_lex/tests/testsuite/parsed.rs` | Adopt now | `--`、`-`、`--name=`、short-cluster、負数トークン分類に対する非常に良い参照元。 |
| `clap_lex/tests/testsuite/shorts.rs` | Adopt now | short-cluster の反復と short-with-inline-value 処理に対する非常に良い参照元。   |

### Full kong audit

| File                     | Verdict                          | Notes                                                                                                                                                                                                                                       |
| ------------------------ | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `benchmark_test.go`      | Skip                             | 性能ベンチマークであり、正しさのカバレッジではない。                                                                                                                                                                                        |
| `config_test.go`         | Skip                             | 設定読み込みは MVP 外。                                                                                                                                                                                                                     |
| `defaults_test.go`       | Skip                             | 広範な default 適用は MVP 外。                                                                                                                                                                                                              |
| `global_test.go`         | Skip                             | 内部 bad-build 処理であり、直接的価値は低い。                                                                                                                                                                                               |
| `help_test.go`           | Later                            | MVP 後の help テキストと usage レンダリング。                                                                                                                                                                                               |
| `helpwrap1.18_test.go`   | Later                            | help wrapping のみ。                                                                                                                                                                                                                        |
| `helpwrap1.19_test.go`   | Later                            | help wrapping のみ。                                                                                                                                                                                                                        |
| `interpolate_test.go`    | Skip                             | 変数展開は計画にない。                                                                                                                                                                                                                      |
| `kong_test.go`           | Adopt now / later / skip (mixed) | スキーマ検証、required / optional args、short flag、enum 検証、重複名、単独 `-`、末尾累積 positional の主参照元。negatable flag、alias、xor / and、hook、plugin、provider、default command、passthrough command、pointer、callback は除外。 |
| `mapper_linux_test.go`   | Skip                             | OS の path mapper はスコープ外。                                                                                                                                                                                                            |
| `mapper_test.go`         | Adopt now (partial)              | `TestSliceConsumesRemainingPositionalArgs`、`TestNumbers`、`TestValuesThatLookLikeFlags` を参照として残す。map、file mapper、custom mapper plumbing、JSON resolver ケース、passthrough mode は除外。                                        |
| `mapper_windows_test.go` | Skip                             | OS の path / file mapper はスコープ外。                                                                                                                                                                                                     |
| `model_test.go`          | Later (partial)                  | `TestModelApplicationCommands` は command-tree の leaf path に対する穏当な参照元。残りは help 整形。                                                                                                                                        |
| `options_test.go`        | Skip                             | callback / provider / binding API は計画にない。                                                                                                                                                                                            |
| `resolver_test.go`       | Skip                             | env / JSON / resolver layering は MVP 外。                                                                                                                                                                                                  |
| `scanner_test.go`        | Adopt now                        | 単純だが有用な tokenizer 期待であり、特に単独 `-` が positional value として振る舞う点が重要。                                                                                                                                              |
| `signature_test.go`      | Skip                             | 関数シグネチャベースの command 生成は `parsz` と無関係。                                                                                                                                                                                    |
| `tag_test.go`            | Skip as direct ports             | これは Go の struct-tag 解析に関するもの。invalid short name と duplicate alias に関する概念だけを拾う。                                                                                                                                    |
| `util_test.go`           | Skip                             | config / version / chdir ヘルパー挙動は無関係。                                                                                                                                                                                             |

### 実用的な移植順

1. `clap_lex` のトークンテストと `kong/scanner_test.go` から始める。
2. 最も単純な `clap/tests/builder/flags.rs`、`opts.rs`、`positionals.rs` ケースを移植する。
3. 重複名と positional 順序に関する `kong/kong_test.go` バリデーションケースを追加する。
4. 再帰スキーマ抽出ができてから `clap/tests/builder/subcommands.rs` を追加する。
5. スカラー変換実装後に、`kong/mapper_test.go` の数値境界テストを選んで追加する。
6. help / version / env / config / alias / conflict / group / default-command 関連は、現在のロードマップがそこへ到達するまで後回しにする。

### ソースリンク

- Local scope documents:
  - `plan_jp.md`
  - `todo_jp.md`
- clap repository revision:
  - <https://github.com/clap-rs/clap/tree/70f3bb31874ff24233f18c394982407ca90d0dcc>
- Kong repository revision:
  - <https://github.com/alecthomas/kong/tree/258b13ac944d17b24a683ff23200933c89555fb7>
- Key clap files:
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/flags.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/opts.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/positionals.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/subcommands.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/tests/builder/unique_args.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/lexer.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/parsed.rs>
  - <https://github.com/clap-rs/clap/blob/70f3bb31874ff24233f18c394982407ca90d0dcc/clap_lex/tests/testsuite/shorts.rs>
- Key kong files:
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/kong_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/mapper_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/scanner_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/tag_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/help_test.go>
  - <https://github.com/alecthomas/kong/blob/258b13ac944d17b24a683ff23200933c89555fb7/resolver_test.go>
