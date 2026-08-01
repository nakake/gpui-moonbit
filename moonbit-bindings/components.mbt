// Reusable components (RFC 0001 §3.1, G11).
//
// A component is a plain function that emits a subtree onto a `CommandBuffer`
// from props (and, for stateful components, store cells reached through a
// `RenderCtx`). Under the retained + full-rebuild model (RFC 0001 §2.4) a
// component only needs to produce the same subtree from the same props/state
// on every call — there is no diffing.
//
// Contract: after a component call, the subtree's root is left on the command
// buffer stack so the caller attaches it with `add_child`. This generalizes
// the old `make_button` helper, which pushed a button div and left it on top.
//
// `RenderCtx` is passed as an explicit argument (RFC 0001 §6-6): MoonBit has
// no implicit context mechanism, and stateful components reach their store
// cells and handler registry through it.

///|
/// レンダリング中のコンポーネントが store とハンドラレジストリにアクセスするための
/// コンテキストです（RFC 0001 §3.1）。状態を持つコンポーネントは `store.cell_for_key`
/// でキーにスコープしたローカル状態セルを得て、`handlers` にハンドラを登録します。
/// コンポーネント関数へ明示引数として渡します（RFC 0001 §6-6）。
pub(all) struct RenderCtx {
  /// 配送先 view id（envelope の slot 2。再構築対象のルーティングに使います）。
  view : Int
  /// 状態セルの格納庫（RFC 0001 §3.3）。
  store : Store
  /// 型付きハンドラレジストリ（RFC 0001 §3.2）。
  handlers : HandlerRegistry
}

///|
/// `button` コンポーネントの props です（RFC 0001 §3.1 のスケッチに対応）。
/// `key` は再構築を跨ぐ安定識別子（`set_key` に渡す。将来の部分更新アドレスにも
/// なる）、`on_click` はレジストリ発行の型付きハンドラ id です。
pub(all) struct ButtonProps {
  /// 安定識別子（`set_key` に渡す。再構築を跨ぐ同一性）。
  key : String
  /// ボタン中央に表示するラベル。
  label : String
  /// 背景色。
  color : Color
  /// クリックハンドラ id（`HandlerRegistry::on_click` の発行値）。
  on_click : HandlerId
}

///|
/// ラベル付きのクリック可能ボタンをコマンドバッファに出力する再利用コンポーネント
/// です。92×56 の div に背景色・角丸・flex 中央揃えを設定し、白いラベルテキストを
/// 子として接続します。出力後、ボタン div はスタックトップに残るため、呼び出し元は
/// `add_child` で親に接続できます。
pub fn button(cb : CommandBuffer, props : ButtonProps) -> Unit {
  cb.div()
  cb.set_key(props.key)
  cb.set_size(92.0, 56.0)
  cb.set_bg_color(props.color)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(props.on_click.to_int())
  cb.text(props.label, 255, 255, 255, 18.0)
  cb.add_child() // attach the label to the button; button stays on top
}

///|
/// `text_input` コンポーネントの props です（RFC 0003 §3.6）。`key` は再構築を跨ぐ安定
/// 識別子（`set_key` に渡す）、`input_id` は `HandlerRegistry::new_input_id` の発行値、
/// `placeholder` は空欄時の薄表示です。イベントハンドラ（`EVENT_INPUT_CHANGED` /
/// `EVENT_INPUT_SUBMIT`）は props に持たず、アプリ側で `on_input_changed` / `on_submit`
/// を登録します（RFC 0003 §3.4: 通知は input_id だけ、値は pull）。
pub(all) struct TextInputProps {
  /// 安定識別子（`set_key` に渡す。再構築を跨ぐ同一性）。
  key : String
  /// テキスト入力 widget の id（`HandlerRegistry::new_input_id` の発行値）。
  input_id : InputId
  /// 空欄時の薄表示テキスト。
  placeholder : String
}

///|
/// 編集可能な 1 行テキスト入力をコマンドバッファに出力する再利用コンポーネントです
/// （RFC 0003、issue #88）。枠・角丸・padding を付けた div の中に `OP_TEXT_INPUT` の
/// leaf ノードを接続します。編集バッファ・選択範囲・IME preedit は Rust 側のテキスト
/// モデルが保持し、再構築を跨いで生存します。出力後、外枠 div はスタックトップに残る
/// ため、呼び出し元は `add_child` で親に接続できます。
pub fn text_input(cb : CommandBuffer, props : TextInputProps) -> Unit {
  cb.div()
  cb.set_key(props.key)
  cb.set_border(1.0, 120, 120, 140)
  cb.set_rounded(6.0)
  cb.set_padding(8.0)
  cb.text_input(props.input_id.to_int(), props.placeholder)
  cb.add_child() // attach the input leaf to the frame; frame stays on top
}
