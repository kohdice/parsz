# parsz MVP 実装計画

この文書は `plan.md` の日本語版です。

## 目標

- Zig 標準ライブラリのみを使う。
- POSIX に着想を得た基本ルールを持つ GNU スタイルの CLI パーサーにする。
- 公開される `parsz` のスキーマ用フィールド型を唯一の真実の源として、宣言的に CLI を定義できるようにする。
- `@typeInfo` と `@compileError` を使ってコンパイル時に検証する。
- 呼び出し側が `argv` を所有している場合は、ゼロコピー動作で高速に解析できるようにする。
- 自動ヘルプ生成とバージョン出力は後回しにするが、それを支えられるスキーマモデルは最初から持たせる。

## MVP の非目標

- ヘルプとバージョン出力の自動生成。
- 環境変数との統合。
- 設定ファイルの読み込み。
- シェル補完の生成。
- 狭い組み込み型セットを超える、豊富な検証フックやカスタムデコーダー。
- `Flag(false)`、`?T = null`、空の可変長位置引数スライスを超える、ユーザー指定の non-null デフォルト値。

## 主要な設計判断

### 1. 公開する parse 入口は 1 つにする

ライブラリは、公開パース API を 1 つだけ公開するべきです。

```zig
pub fn parse(
    comptime Schema: type,
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) ParseError!Parsed(Schema)

pub fn deinit(
    comptime Schema: type,
    allocator: std.mem.Allocator,
    value: *Parsed(Schema),
) void
```

`parse` が中核 API です。

- テストしやすい。
- 呼び出し側が所有する `argv` から文字列をゼロコピーで借用できる。
- 所有権を明示できる。
- 引数の取得と引数の解析を混ぜずに済む。

ある解析で実際には確保が発生しなくても、`allocator` は常に受け取ります。そうしておくと API が安定し、必要になったときに動的コレクションを導入できます。

### 2. すべてのコマンドスコープを同じスキーマ struct ルールで表す

ルート CLI と各サブコマンドのペイロードは、同じコマンドスキーマ規則に従うべきです。

コマンドスキーマとは、次の条件を満たす非 tuple の `struct` です。

- `pub const meta` を宣言してよい
- `parsz` のスキーマフィールド型を含む
- `parsz.Subcommand(...)` フィールドを高々 1 つだけ持てる

これにより、ライブラリはコマンドスコープ用のスキーマ抽出器とバリデータを 1 つずつ持てば十分になります。ルート CLI は単に最上位のコマンドスキーマであり、各サブコマンドのペイロードも、サブコマンド union を再帰的にたどって到達する別のコマンドスキーマです。

例:

```zig
const Cli = struct {
    pub const meta = .{
        .name = "demo",
        .version = "0.1.0",
        .about = "Demo application",
    };

    verbose: parsz.Flag(.{
        .short = 'v',
        .help = "Enable verbose output",
    }),

    output: parsz.Option(?[]const u8, .{
        .long = "output",
        .value_name = "PATH",
    }),

    input: parsz.Positional([]const u8, .{
        .help = "Input file",
    }),

    command: parsz.Subcommand(Command),
};

const Command = union(enum) {
    init: struct {
        pub const meta = .{
            .about = "Create a new project",
        };

        bare: parsz.Flag(.{}),
    },
    fmt: struct {
        pub const meta = .{
            .about = "Format input paths",
        };

        check: parsz.Flag(.{}),
        paths: parsz.Positional([]const []const u8, .{}),
    },
};
```

これは次の意味です。

- `Cli` はルートのコマンドスキーマ
- 各サブコマンドのペイロード struct もコマンドスキーマ
- `Command` は 1 つのコマンドスキーマのペイロードを選ぶサブコマンド union
- フィールド単位のスキーマは `Flag`、`Option`、`Positional`、`Subcommand` に置く
- コマンド単位のメタデータは `pub const meta` に置く

このプロジェクトでスキーマ宣言にラッパー型を使うべき主な理由はここにあります。ラッパーは公開 API ですが、実装自体は Zig 標準ライブラリだけに依存したままにできます。

### 3. スキーマ型とパース後の値型を分離する

スキーマ型は実行時の結果型ではありません。これは `parse` が comptime で読む宣言的な説明です。

`Parsed(Schema)` は、スキーマから実行時の値型を導出するべきです。

```zig
const ParsedCli = parsz.Parsed(Cli);
```

概念的には次のようになります。

```zig
const ParsedCli = struct {
    verbose: bool,
    output: ?[]const u8,
    input: []const u8,
    command: union(enum) {
        init: struct {
            bare: bool,
        },
        fmt: struct {
            check: bool,
            paths: []const []const u8,
        },
    },
};
```

この分離により、両方の利点を取れます。

- スキーマは完全に宣言的で、唯一の情報源のままになる
- パース結果は使いやすい素直なデータになる
- ユーザーはパース後にラッパーの実体を扱わなくてよい

実際には、多くの呼び出し側は型推論に頼ることになります。

```zig
const cli = try parsz.parse(Cli, allocator, argv);
```

それでも `Parsed(Schema)` は重要です。これは `parse`、`deinit`、テスト、診断の公開契約を定義するためです。

### 4. コマンドスキーマ struct とサブコマンド union を組み合わせる

各コマンドスコープはコマンドスキーマ struct で表現するべきです。サブコマンドの選択は、`parsz.Subcommand(...)` で包まれた `union(enum)` で表現するべきです。

これにより、コマンドツリーが明示的になります。

- コマンドスキーマは struct
- サブコマンド選択はタグ付き union
- 各サブコマンドのペイロードは別のコマンドスキーマ

したがって `command: parsz.Subcommand(Command)` は、「このコマンドスキーマは `Command` サブコマンド union からちょうど 1 つのペイロードを選ぶ」という意味になります。

## コマンドメタデータ規則

`pub const meta` は、コマンドスキーマに対するコンテナ単位のメタデータです。

MVP では次のようにします。

- ルートのコマンドスキーマは `name`、`version`、`about` を定義できる
- サブコマンドのコマンドスキーマは `about` を定義できる
- サブコマンド名は union のフィールド名から既定化する
- サブコマンドごとに独立した `version` は持たない

## 内部スキーマ契約

公開スキーマフィールドの各コンストラクタは、小さなコンパイル時計約を宣言経由で公開する型を生成するべきです。宣言名そのものは実装時に最終決定してかまいませんが、スキーマ抽出器は少なくとも次を読める必要があります。

- フィールド種別
- パース後の値型
- フィールドメタデータ

例えば、生成されるラッパー型は、概念的には次に相当する宣言を公開できます。

- `pub const parsz_kind = .flag`
- `pub const Value = bool`
- `pub const meta = ...`

こうしておくと、`schema.zig` 側で脆い名前ベース判定を避けられ、検証を完全にリフレクション経由で行えます。

## MVP で対応するフィールド種別

MVP では次のスキーマフィールドコンストラクタをサポートするべきです。

- `Flag(meta)`
  - パース後の値型: `bool`
  - フラグが省略された場合の値は `false`
- `Option(T, meta)`
  - パース後の値型: `T`
  - `T` に指定できるもの:
    - `bool`
    - 整数型
    - 浮動小数点型
    - enum
    - `[]const u8`
    - `[:0]const u8`
    - `?U`。ここで `U` はサポート対象のスカラー型または文字列型のいずれか
- `Positional(T, meta)`
  - パース後の値型: `T`
  - `T` に指定できるもの:
    - `Option` と同じスカラー型または文字列型
    - `[]const U`。ここで `U` はサポート対象のスカラー型または文字列型で、繰り返し位置引数を表す
- `Subcommand(T)`
  - `T` は、各ペイロードがスキーマ struct であるタグ付き union でなければならない
  - パース後の値型: 再帰変換されたタグ付き union

文字列スライスは、引き続きスカラーの文字列値として扱います。例えば次のとおりです。

- `Positional([]const u8, ...)` は 1 つの文字列位置引数を意味する
- `Positional([]const []const u8, ...)` は繰り返し可能な文字列位置引数を意味する

MVP で除外を推奨するもの:

- map
- ネストした埋め込みオプショングループ
- カスタムパーサー
- 繰り返しオプション値
- `-vvv` のような短いカウントフラグの繰り返し
- 大文字小文字を区別しない enum

これらは基礎アーキテクチャが安定してから追加できます。

## Optionality 規則

オプショナル性は、スキーマフィールド型そのもので表現するべきです。

- `Flag(...)` は常に省略可能で、既定値は `false`
- `Option(?T, ...)` は省略可能で、省略時は `null` になる
- `Positional(?T, ...)` は省略可能で、省略時は `null` になる
- 繰り返し位置引数は `[]const u32` や `[]const []const u8` のようなスライスペイロードを使い、0 個以上の値を消費する
- それ以外の `Option(T, ...)` と `Positional(T, ...)` は必須

これにより、必須かどうかの情報を 1 か所に集約でき、第二の optionality 機構を避けられます。

## コンパイル時バリデーション規則

`parse` は `comptime validateSchema(Schema)` を起動するべきです。

バリデータは次を拒否するべきです。

- struct ではない CLI ルート
- tuple struct
- 型が `parsz` スキーマフィールド型ではないフィールド
- サポート対象外の `Option` / `Positional` ペイロード型
- 同じコマンドスコープ内での long name 重複
- 同じコマンドスコープ内での short name 重複
- 可変長位置引数の後に位置引数が続くこと
- 任意位置引数の後に必須位置引数が続くこと
- 同じコマンド struct 内に複数の subcommand フィールドがあること
- 不正な `Subcommand(T)` 引数
- スキーマ struct ではないサブコマンドペイロード
- 同じコマンドスコープ内でのサブコマンド名の重複
- MVP における `help` や `version` のような予約名

バリデータは次の正規化も行うべきです。

- 省略された long name をフィールド名から補う
- サブコマンド名を union フィールド名から補う
- value name をフィールド名を大文字化したものから補う

位置引数の順序はフィールド宣言順から決めるべきです。公開スキーマに別個の位置インデックス表は持たせるべきではありません。

すべてのバリデーション失敗は、ユーザーが素早く定義を直せるように、フィールド修飾付きメッセージを含む `@compileError` を使うべきです。

## 実行時パースモデル

実行時パーサーは、`argv[1..]` を走査する小さな状態機械にするべきです。

1. `argv[0]` を飛ばす。
2. `--` を見たかどうかを追跡する。
3. `--` より前では次を扱う。
   - `--name=value`
   - `--name value`
   - `-v` / `-o value` のような短いフラグと短いオプション
4. `--` より後はすべて位置引数として扱う。
5. 位置引数フィールドはスキーマ宣言順に消費する。
6. subcommand フィールドに到達したら、次のトークンをコンパイル時サブコマンド表と照合し、選ばれたペイロードスキーマへ再帰する。

検索方法について:

- long name と subcommand 名には `std.StaticStringMap(...).initComptime(...)` を使うべき
- short name は、コンパイル時に組み立てたコンパクトな検索表か、小さな線形走査で十分

これにより検索オーバーヘッドを小さく保ち、大半の仕事をコンパイル時へ押し込めます。

## 変換規則

スカラー変換は、可能な限り標準ライブラリに頼るべきです。

- 整数: `std.fmt.parseInt`
- 浮動小数点: `std.fmt.parseFloat`
- enum: `std.meta.stringToEnum`
- 真偽値:
  - `Flag` フィールドは存在したときに `true` になる
  - `Option(bool, ...)` と `Positional(bool, ...)` は `true` / `false` を受け付けられる

文字列風の値は、`parse` に渡された `argv` から借用するべきです。

繰り返し値では次の方針にします。

- 固定サイズのスカラーフィールドには確保を行わない
- 送信先フィールドが `[]const T` のような動的スライスのときだけ確保する

## 所有権とライフタイムモデル

これは最も重要な設計制約です。

- `[]const u8` と `[:0]const u8` の結果は呼び出し側が渡した `argv` を借用する
- 繰り返しの動的値では、結果スライスのストレージだけを確保する
- `deinit` はパーサー自身が確保したストレージだけを解放する
- 呼び出し側は、パース結果より長く `argv` が生存することを保証する責任を持つ

アプリケーションがプロセス引数を解析したい場合は、まず `std.process` でそれらを取得し、その後で `parse` に渡すべきです。そうすることで、パースライブラリはプロセスレベルの引数所有権ではなく、スキーマ検証、トークン化、型変換に集中できます。

## 内部モジュール構成

初期ファイル構成の推奨:

```text
src/parsz.zig          // public exports
src/field.zig          // Flag/Option/Positional/Subcommand type constructors
src/schema.zig         // comptime schema extraction and validation
src/parsed.zig         // Parsed(Schema) type generation
src/parse.zig          // runtime token parser
src/convert.zig        // token-to-type conversion
src/deinit.zig         // generic cleanup for dynamically allocated fields
src/error.zig          // parse errors and formatting helpers
test/schema_declaration_test.zig  // schema declaration contract tests
```

## エラーモデル

定義時エラーと実行時パースエラーは分離します。

定義時エラー:

- `@compileError` で報告する
- フィールドパスと、どの規則に違反したかを含める

実行時エラー:

- unknown option
- missing option value
- missing required positional
- unexpected argument
- duplicate single-use option
- invalid scalar value
- unknown subcommand

書式化には、小さく型付けされた error set と診断用ペイロード struct の組み合わせを優先します。

## テスト計画

### 実行時テスト

- 単純なフラグ
- 必須および任意のオプション
- 宣言順の位置引数
- 繰り返し位置引数
- サブコマンド
- enum パース
- 代表的なスキーマに対する `Parsed(Schema)` の形
- `--` 終端子の動作

### Compile-fail テスト

標準のテスト API は、型定義全体に対するインライン `expectCompileError` チェックを前提にしていないため、無効なフィクスチャを個別にコンパイルする形式をテストハーネスか build script で使います。

フィクスチャがカバーするべき内容:

- ラッパーでないフィールド型
- 名前重複
- サポート対象外のペイロード型
- 不正なサブコマンド定義
- 不正な位置引数順序

## リリース順序

### Phase 1

- プロジェクトの骨組み
- 公開スキーマフィールド型
- `Parsed(Schema)`
- スキーマ抽出
- コンパイル時バリデーション

### Phase 2

- スカラー解析
- オプションと位置引数の解析
- 繰り返し値
- `deinit` 対応

### Phase 3

- サブコマンド
- より良い診断
- compile-fail フィクスチャテスト

### Phase 4

- help/version 用メタデータ配線
- help/version 生成

## 推奨まとめ

着手点としては次を優先します。

- 公開スキーマフィールド型を唯一の真実の源にする
- `Parsed(Schema)` を実行時値型ジェネレーターにする
- `parse` を唯一の公開パース API にする
- サブコマンドにはタグ付き union を使う
- バリデーションには `@typeInfo` と `@compileError` を使う

こうすると、MVP を小さく、テストしやすく、正しく保ちながら、公開 CLI 定義におけるスキーマ重複を排除できます。
