# RFC 0002: 非同期イベント注入(バックグラウンド → UI 更新経路)

| 項目 | 内容 |
|---|---|
| ステータス | 実装済み(#84)。現行実装の権威は [`architecture.md`](../architecture.md)であり、本 RFC は設計判断とその根拠の記録である |
| 作成日 | 2026-08-01 |
| 対象 | 公開注入 ABI(`framework-gaps.md` G1〜G29 の射程外。#92 M1) |
| 関連 issue | #83(本 RFC)、#84(実装)、#70(EVENT_QUEUE リーク — 教訓を §3.4 に反映)、#85(ハーネス側 process runner、消費者例)、#10(`gpui_update_text`) |
| 前提ドキュメント | [`architecture.md`](../architecture.md)(現行実装の権威)、[`0001-component-model.md`](0001-component-model.md) §2(native 実行時制約) |

本 RFC は、**外部 native コードが任意スレッドから UI へイベントを push できる公開 C ABI** を定める。GUI Agent ハーネス(別リポジトリ)の「エージェント出力のストリーミング表示」が最初の消費者である。実装は #84 の管轄であり、すべてのコード片はスケッチである。

---

## 1. 背景と動機

現行のイベントは UI → MoonBit の `dispatch` 一方向のみで、バックグラウンド → UI の更新経路が存在しない。gpui-sys には timer / spawn / スレッド起点の更新経路が一切ない。

方針(2026-07-31、#92): 本リポジトリはライブラリに徹し、ハーネスは別プロジェクトとして消費する。したがって注入 API は**ライブラリ内部の便宜機構ではなく公開 C ABI** として設計する。プロセス runner・ネットワーク受信などの producer 自体は消費側(ハーネス)の責務であり、本 ABI は「任意スレッドから安全に push できる境界」だけを提供する。

```
[消費側 native producer スレッド]                [メインスレッド (GPUI ループ)]
  gpui_post_event(view, bytes)                       drain task (foreground)
    │ ① Mutex 付き注入キューへ copy                       │ ③ キューを drain
    │ ② チャネル送信でメインループを wake ──────────────▶│ ④ mb_dispatch(EVENT_ASYNC, …)
    └ 即座に return (non-blocking)                        │ ⑤ changed==1 なら cx.notify()
```

## 2. 制約(動かせない前提)

RFC 0001 §2 の native 実行時制約がすべて適用される。本 RFC に効くのは次の 4 点:

1. **`mb_dispatch` はメインスレッド限定**(非アトミック RC)。バックグラウンドスレッドから直接呼ぶ実装は不可能。よって「スレッドセーフキュー → メインスレッドへ載せ替え → dispatch」の構成が強制される。
2. **envelope はスカラのみ**(5×i32)。ペイロードは Rust 所有バッファ + token+copy 方式(`gpui_event_copy_text`、`lib.rs:122`)を踏襲する。
3. **dispatch は total に保つ**。注入経路の失敗は status code として producer に返し、panic にしない(C export は `ffi_export` の `catch_unwind` を通す)。
4. **gpui 0.2.2 の executor が唯一の wake 手段**である。実測(vendored ソース): `ForegroundExecutor::spawn`(`executor.rs:471`)は runnable を `PlatformDispatcher::dispatch_on_main_thread`(`executor.rs:483`、`platform.rs:565`)でスケジュールする。foreground task の `Waker` は `Send` であり、**任意スレッドから wake してよい**。つまり「メインスレッドで await している task を、producer スレッドがチャネル送信で起こす」経路は gpui の公開 API だけで成立する。

## 3. 設計

### 3.1 公開 ABI

新しい C export を 1 本追加する:

```c
// 任意スレッドから呼び出し可。non-blocking。
// view:  配送先 view id (VIEWS のインデックス)
// ptr:   ペイロード先頭。呼び出しの間だけ借用し、内部へコピーする
// len:   ペイロードのバイト長 (0 も許容: 「イベントが起きた」だけを運ぶ)
// 戻り値: GPUI_STATUS_OK / 負の GPUI_STATUS_*
int32_t gpui_post_event(int32_t view, const uint8_t *ptr, int32_t len);
```

**設計上の決定**:

- **ペイロードは opaque bytes である。** ライブラリはペイロードの意味を解釈しない。ストリーミングテキスト・JSON・アプリ独自のバイナリフレーミングはすべて消費側(producer と MoonBit ハンドラの間)の契約である。これにより ABI は「kind の増殖」から自由になり、`EVENT_TEXT` のような種別追加を消費側の都合で繰り返さずに済む。
- **non-blocking を保証する。** producer は UI の状態に関わらずブロックされない。満杯なら即座に `GPUI_STATUS_QUEUE_FULL` を返し、待つ・捨てる・まとめ直すの判断は producer に委ねる(§3.2)。
- **`ptr` は呼び出しの間だけ借用**し、内部キューへコピーする。既存 FFI と同じ契約(`architecture.md` §7)。
- **ヘッダ公開**: cbindgen が `gpui-sys/include/gpui_sys.h` へ自動で出す(既存 export と同一機構)。このヘッダが消費側 native コードのコンパイル対象になる。
- **ABI 安定性**: シグネチャは 5 スロット envelope(`abi.toml` `[callback]`)に触れないため `ABI_VERSION=4` は据え置き。イベント種別の追加は後方互換(古い MoonBit は未知 kind に `Unknown`/0 を返す。`architecture.md` §4b)。status code の追加も後方互換(負値の追加のみ)。公開 ABI としての互換性ポリシーは「シンボルとシグネチャは削除・変更しない。追加のみ」を `architecture.md` §4 に明文化する(#84 でドキュメント化)。

新しい status code(`lib.rs` の既存 `-1`〜`-10` に続く):

```rust
pub const GPUI_STATUS_QUEUE_FULL: i32 = -11;        // 注入キュー満杯 (back-pressure)
pub const GPUI_STATUS_PAYLOAD_TOO_LARGE: i32 = -12; // len が上限超過
```

### 3.2 注入キューと back-pressure(#70 の教訓)

```rust
// --- スケッチ ---
struct InjectQueue {
    entries: Mutex<VecDeque<(i32 /* view */, Vec<u8>)>>,
    wake_tx: futures::channel::mpsc::UnboundedSender<()>, // wake 専用。データは運ばない
}
static INJECT: OnceLock<InjectQueue> = OnceLock::new();
```

- **キューは有界とする**(提案値: 1024 エントリ、1 エントリ最大 1 MiB。§6-1)。#70 の教訓は「解放契約のないキューは必ずリークする」であり、本キューは (a) 有界、(b) drain 側が pop で所有権ごと取り出す、の 2 点で unbounded 成長を構造的に排除する。
- 満杯時は `GPUI_STATUS_QUEUE_FULL` を即返す。**ライブラリ側では捨てない・待たない・まとめない。** ストリーミング用途では producer がチャンクを結合して再送するのが自然な回復である。
- 順序保証: 全 producer を跨いだ**単一 FIFO**(Mutex 取得順)。同一 producer からの post は送信順に配送される。
- ウィンドウ起動前の post も受け付ける(キューに積まれ、ループ開始時の初回 drain で配送)。ループが存在しない限り wake は no-op で、キュー上限が自然な backstop になる。

### 3.3 wake 機構

`gpui_run_window` の `Application::new().run(...)` クロージャ内(`lib.rs:1220`)で、foreground executor に **drain task** を 1 つ spawn する:

```rust
// --- スケッチ: run_window 内 ---
let (wake_tx, mut wake_rx) = futures::channel::mpsc::unbounded::<()>();
INJECT.set(InjectQueue { entries: …, wake_tx }).ok();
cx.spawn(async move |cx: &mut AsyncApp| {          // App::spawn (app.rs:1417)
    while wake_rx.next().await.is_some() {         // producer の送信で wake
        drain_injected_events(cx);                 // §3.4
    }
}).detach();
```

- `gpui_post_event` はコピー完了後に `wake_tx.unbounded_send(())` する。チャネル送信が foreground task の `Waker` を起こし、gpui が `dispatch_on_main_thread` で drain task をメインスレッドにスケジュールする(§2-4)。producer 側にプラットフォーム依存コードは一切ない。
- wake チャネル自体は `()` しか運ばない(データはキューが持つ)。複数回の send が 1 回の drain にまとまっても、drain がキューを空にするので取りこぼしはない。

### 3.4 メインスレッド配送

drain task は 1 回の wake でキューを空になるまで処理する:

```rust
// --- スケッチ ---
fn drain_injected_events(cx: &mut AsyncApp) {
    while let Some((view, payload)) = pop_injected() {   // Mutex は pop の間だけ保持
        let len = payload.len() as i32;
        let token = {
            let mut q = EVENT_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
            q.push(payload);
            (q.len() - 1) as i32
        };
        let changed = unsafe { mb_dispatch(ABI_VERSION, EVENT_ASYNC, view, token, len) };
        EVENT_QUEUE.lock().unwrap_or_else(|e| e.into_inner()).clear(); // ← #70 の修正と同一契約
        if changed == 1 { notify_view(cx, view); }       // WeakEntity 経由で cx.notify()
    }
}
```

- **token+copy の再利用**: ペイロードは既存の `EVENT_QUEUE`(`lib.rs:113`)に載せ、MoonBit は既存の `gpui_event_copy_text` でコピーする。新しいコピー ABI は追加しない。「エントリは同期 dispatch 中のみ有効」という既存契約(`lib.rs:109-112`)をそのまま適用する。
- **dispatch 復帰直後のクリアを全経路に義務付ける。** これは #70 の修正そのものであり、#84 は `EVENT_TEXT` 経路(`lib.rs:1339-1346`)と本経路の両方にクリアを入れ、リーク回帰テストを追加する(#70 の検証項目を吸収)。
- **notify のルーティング**: 現行の notify はリスナー内の `cx.notify()`(`lib.rs:1326` 等)で、view エンティティ文脈が暗黙に手元にある。drain task にはないため、`FfiView` 構築時に view id → `WeakEntity<FfiView>` をメインスレッド専用レジストリ(`ScrollHandle` と同様の理由で `Mutex` 下に置けない。`architecture.md` §3)へ登録し、`entity.update(cx, |_, cx| cx.notify())` で通知する。ウィンドウが閉じて upgrade に失敗したイベントは捨てる(dispatch 済みでも UI がないため無害)。
- MoonBit 側の `dispatch` はメインスレッドから呼ばれるため、**MoonBit 作者から見た並行性の考慮はゼロのまま**である(RFC 0001 §2.3 の含意を維持)。

### 3.5 新イベント種別

`abi.toml` `[events]` に追加:

```toml
EVENT_ASYNC = 5
```

envelope: `(ABI_VERSION, EVENT_ASYNC, view, token, byte_len)`。`EVENT_TEXT` と同型で、ペイロードの解釈だけが異なる(UI 由来の入力テキスト vs 消費側定義の opaque bytes)。MoonBit 側は `Event` enum に `Async(String)` ではなく **`Async(Bytes)`** を追加する(ペイロードはテキストとは限らない。UTF-8 解釈は消費側ヘルパーの責務)。

### 3.6 ストリーミングテキスト表示(最初の消費者の姿)

#84 の受け入れデモ。ハーネスの「read-only ストリーミングビューア」の縮約版:

```
producer スレッド (Rust テスト or C):        MoonBit 側:
  loop {                                       dispatch → Async(bytes) ハンドラ:
    chunk = 次のトークン列                        buf += decode_utf8(bytes)
    gpui_post_event(0, chunk, len)               update_text(view, "stream-text", buf)
    (QUEUE_FULL なら結合して再送)                  失敗(KEY_NOT_FOUND)時のみ build_tree
  }                                              → 1 を返す(自動 notify)
```

`gpui_update_text`(#10)のその場更新と組み合わせることで、チャンクごとのフルツリー再構築を避ける。チャンク粒度が細かすぎる場合の coalescing は §6-3。

## 4. ABI 影響

| 要素 | 変更 | 後方互換性 |
|---|---|---|
| C export | `gpui_post_event` を**追加** | 追加のみ。既存シンボル無変更 |
| `[events]` | `EVENT_ASYNC = 5` を**追加** | 古い MoonBit は `Unknown`/0(`ABI_VERSION=4` 据え置き) |
| status code | `-11`/`-12` を**追加** | 負値の追加のみ |
| envelope / `[callback]` | **変更なし** | 5×i32 のまま。#76(params 重複)にも影響しない |
| `gpui_event_copy_text` | **変更なし**(EVENT_ASYNC でも使う) | 既存契約のまま |
| `EVENT_QUEUE` | dispatch 復帰後クリアを**追加**(#70 修正) | 契約(`lib.rs:109-112`)の実装であり変更ではない |
| wire format / opcode | **変更なし** | — |

## 5. 実装計画(#84 のスコープ)

1. **#70 修正 + 回帰テスト**: `EVENT_TEXT` 経路にクリアを追加、`gpui_event_copy_text` の unit test(正常系・境界・リーク回帰)。
2. **注入キュー + `gpui_post_event`**: 有界キュー、status code 追加、`ffi_export` 経由の panic 捕捉(#73 の教訓: 新 export は最初から `catch_unwind` を通す)。
3. **drain task + notify レジストリ**: `run_window` への配線、`WeakEntity` レジストリ、EVENT_ASYNC dispatch。
4. **MoonBit 受信 API**: `Event::Async(Bytes)`、`abi_constants` 再生成、UTF-8 デコードヘルパー。
5. **テスト**: ヘッドレス(#53 基盤): `TestAppContext` の test dispatcher は foreground task を駆動できるため、producer スレッド → post → drain → dispatch stub の全経路を GUI なしで固定できる。マルチ producer の順序・QUEUE_FULL・起動前 post も同様。
6. **デモ + 3 OS 手動検証**: §3.6 のストリーミングデモ(`examples/` または `cmd/`)。
7. **ドキュメント**: `architecture.md` §4(公開 ABI 互換性ポリシー含む)、`framework-gaps.md`。

実装順は 1 → 2 → 3 → 4 → 5 → 6 で、各段が独立に PR にできる。**#71(ヘッダ生成デッドロック)の修正が前提**(新 export の追加を伴うため。#92 の推奨どおり先行させる)。

## 6. 未決事項

1. **キュー上限の具体値**: 提案は 1024 エントリ / 1 エントリ 1 MiB。ストリーミング LLM 出力(数十 tok/s、チャンク数百バイト)には十分すぎる余裕があるが、実装時に定数として一箇所に置き、将来 `gpui_set_queue_limit` のような設定 ABI を足せる形にする(v1 では固定でよい)。
2. **`view` の検証タイミング**: post 時に view の存在を検証しない(producer スレッドから `VIEWS` を触るとロック競合が増えるだけで、TOCTOU も避けられない)。存在しない view 宛は drain 時に捨てる。post 側では `view < 0` のみ弾く。この方針でよいか。
3. **coalescing**: 1 回の drain で同一 view の連続ペイロードを 1 dispatch にまとめる最適化。v1 では入れない(dispatch は人間可視の頻度に対して十分軽い)。入れる場合も ABI 変更なしで drain 側だけで実装できることを確認済み。
4. **`EVENT_ASYNC` のサブ種別**: 消費側が複数種のイベントを流したい場合、ペイロード先頭の自前フレーミングで表現する(本 RFC の立場)か、envelope の追加スロットが欲しくなるか。ハーネス実装(#85 以降)からのフィードバックで再訪する。
5. **ヘッドレス環境の drain**: `run_window` を呼ばないヘッドレス消費(将来のテストハーネス)向けに、同期 drain を公開 ABI(`gpui_drain_events` 等)として出すか。v1 ではテスト内部ヘルパーに留める。

---

## 付録: 現行コードとの対応

| 現行 | 本 RFC |
|---|---|
| `EVENT_QUEUE` push + token(`lib.rs:1339-1341`) | EVENT_ASYNC 配送でも同一機構を再利用(§3.4) |
| クリアなし(#70) | 全 dispatch 経路で復帰直後にクリア(§3.4) |
| `notify_if_changed`(`lib.rs:1419`) + リスナー内 `cx.notify()` | drain task は `WeakEntity` レジストリ経由で notify(§3.4) |
| `run_window`(`lib.rs:1219-1246`) | wake チャネル生成 + drain task spawn を追加(§3.3) |
| イベント種別 4 種(`abi.toml` `[events]`) | `EVENT_ASYNC = 5` 追加(§3.5) |
