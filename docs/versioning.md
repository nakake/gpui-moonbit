# バージョニング方針

本リポジトリには 3 つの独立したバージョン軸がある: C ABI 契約（`ABI_VERSION` / `BUFFER_VERSION`）、MoonBit モジュールの semver（`moon.mod`）、Rust クレートの semver（`Cargo.toml`）。この文書は 3 軸の関係・バンプ規則・changelog 方針・リリース手順を定める。

## 3 つのバージョン軸

| 軸 | 定義場所 | 現在値 | 意味 |
|---|---|---|---|
| `ABI_VERSION` | `gpui-sys/abi.toml` | `4` | dispatch envelope と共有 ABI 定数のワイヤ契約 |
| `BUFFER_VERSION` | `gpui-sys/abi.toml`（`[buffer]`） | `1` | コマンドバッファのワイヤ形式 |
| モジュール semver | `moonbit-bindings/moon.mod` | `0.1.0` | MoonBit モジュールの公開バージョン |
| クレート semver | `gpui-sys/Cargo.toml` | `0.1.0` | Rust staticlib（`gpui-sys`）のバージョン |

### `ABI_VERSION` — 境界のワイヤ契約

`ABI_VERSION` は Rust→MoonBit コールバック `app.dispatch(version, kind, view, data_a, data_b) -> Int` の slot 0 に常に載る。MoonBit 側は不一致時に `Unknown` を返して古い Rust バイナリを**ランタイムに拒否**する（[`architecture.md`](architecture.md) §5）。イベント種別・envelope 定数・コールバックのシグネチャはすべて `abi.toml` に由来し、build driver が両言語へ生成・検証する。

履歴（すべて `git log` で追跡可能）:

| 値 | 変更 | コミット / issue |
|---|---|---|
| 1 | 共有 ABI 定義の強制（`abi.toml` 導入） | 06a4818（#1） |
| 2 | property-per-call FFI をコマンドバッファへ置換 | 40f1f36（#5） |
| 3 | バージョン付きイベント envelope + `EVENT_TEXT`（token+copy） | 6847963（#6 / #36） |
| 4 | view id を slot 2 に載せた 5 スロット envelope（イベントの view ルーティング） | 24c3809（#49） |

**bump が必要（破壊的変更）**: envelope のスロット数・意味の変更、既存イベント種別の意味変更、コールバックの引数/戻り値の変更。

**bump 不要（後方互換な追加）**:

- 新しい opcode の追加 — 古い Rust バイナリは未知 opcode を `UNKNOWN_OPCODE`（`-7`）で拒否するだけで誤デコードしない（[`architecture.md`](architecture.md) §4、issue #42 の方針）。`OP_SET_PADDING` / `OP_SET_BORDER`（#44）はこの経路で `ABI_VERSION` 不変のまま追加された。
- 新しいイベント種別の追加 — 古い MoonBit は未知 kind を `Unknown` として `0` を返す（[`architecture.md`](architecture.md) §5）。`EVENT_NAMED_KEY`（#43）はこの経路で追加された。

### `BUFFER_VERSION` — コマンドバッファのワイヤ形式

`BUFFER_VERSION` はコマンドバッファの magic の後に続くヘッダ版本。issue #42 の方針により、**既存 opcode の意味が変わったときだけ bump** する。opcode の追加は後方互換なので bump しない（理由は上記と同じ）。

### モジュール / クレート semver

`moon.mod` と `Cargo.toml` のバージョンは**ロックステップ**で動かす（常に同じ値）。リリースタグは `v<version>`（例: `v0.2.0`）。

## バンプ規則

現在は pre-1.0（`0.1.0`）。semver 2.0 の pre-1.0 慣例に従い、破壊的変更は MINOR で示す。破壊性の実体は `ABI_VERSION` 自身が記録する。

| 変更の種類 | pre-1.0（現在） | post-1.0 |
|---|---|---|
| `ABI_VERSION` の bump（破壊的 ABI 変更） | **MINOR**（`0.1.0 → 0.2.0`） | **MAJOR**（`1.x → 2.0.0`） |
| 後方互換な機能追加（新 opcode・新イベント種別・新 API。`ABI_VERSION` 不変） | **MINOR** | **MINOR** |
| 後方互換な修正（実装・ビルド・ドキュメント） | **PATCH** | **PATCH** |
| `BUFFER_VERSION` の bump（既存 opcode の意味変更） | `ABI_VERSION` bump を伴うため上段に同じ | 同左 |

`ABI_VERSION` の bump とモジュール/クレートのバージョン bump は同じコミットで行う。

## Changelog 方針

- リポジトリルートの [`CHANGELOG.md`](../CHANGELOG.md) を [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) 1.1.0 形式で維持する。
- セクション見出しは標準の `Added` / `Changed` / `Deprecated` / `Removed` / `Fixed` / `Security` のみを使う。本文は日本語でよい。
- 各エントリは実際のコミット/PR に基づき、PR 番号（または issue 番号）とコミットハッシュを付す。捏造しない。
- 変更はまず `Unreleased` に追記する。リリース時に `Unreleased` を `[X.Y.Z] - YYYY-MM-DD` へ確定し、新しい空の `Unreleased` を残す。

## リリースチェックリスト

1. **CI 緑**: `main` の GitHub Actions が 3 OS（ubuntu / macos / windows）で成功していること。CI にはコールドビルド、Rust 単体テスト、`moon test`、Rust 単独変更後の再ビルドが含まれる。`abi.toml` 由来の定数が両言語で一致していること（drift guard、#8 で導入）は build driver の検証とテストが担保する。
2. **バージョン決定**: 上のバンプ規則に従い次のバージョンを決め、`moonbit-bindings/moon.mod` と `gpui-sys/Cargo.toml` を同時に更新する。
3. **ABI 整合性**: ABI 変更がある場合、`abi.toml` の `ABI_VERSION` が bump 済みであること、build driver（`build.sh` / `build.ps1`）で定数を再生成済みであること、`architecture.md` の envelope 記述が一致していることを確認する。
4. **Changelog 確定**: `CHANGELOG.md` の `Unreleased` を `[X.Y.Z] - YYYY-MM-DD` に書き換え、エントリがコミットと突き合わせ可能であることを確認する。
5. **タグ**: `vX.Y.Z` を打って push する。
6. **配布**（将来）: mooncakes 公開は `--moonbit-unstable-prebuild` の API 安定性を見極めてから判断する（#93 で prebuild パイプラインは実装済みだが、実験的機能への依存を公開パッケージに固定するのは時期尚早と判断）。macOS 配布署名は `G5` 完了後。それまでは path/git 依存（prebuild 方式、[`spikes/2026-07-24-packaging-feasibility.md`](spikes/2026-07-24-packaging-feasibility.md) の方式 A）またはテンプレートリポジトリ方式（`build.sh` / `build.ps1` を含むリポジトリの fork/clone、方式 B）で配布する。
