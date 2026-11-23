# Kiritori

Mac 用のスクリーンショット・画面録画アプリです。メニューバーに常駐します。

- 範囲・全画面・ウィンドウの撮影、文字の読み取り、履歴
- 撮った画像の編集（矢印・文字・ぼかし・背景など）
- 画面録画と動画の編集（分ける・切り抜き・ズーム）

## 入れ方

Releases から `Kiritori-<版>.zip` を取り、[Mac miniでの入れ方.md](Mac%20miniでの入れ方.md) の手順で入れます。

## 自分で作る

Xcode は要りません。Command Line Tools が入っていれば作れます。

```bash
./build.sh
```

`build/Kiritori.app` と `build/Kiritori-<版>.zip` ができます。macOS 13 以降が対象です。
