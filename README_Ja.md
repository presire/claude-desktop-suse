# Claude Desktop for openSUSE/SLE Linux

これは[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)のフォークで、openSUSEおよびSUSE Linux Enterpriseディストリビューション向けに適応されています。

このプロジェクトは、Claude DesktopをopenSUSE/SLE Linuxシステムでネイティブに実行するためのビルドスクリプトを提供します。
公式のWindowsアプリケーションを再パッケージし、`.rpm`パッケージを生成します。

**注意:**
これは非公式のビルドスクリプトです。
公式サポートについては、[Anthropicのウェブサイト](https://www.anthropic.com)をご覧ください。
ビルドスクリプトやLinux実装に関する問題については、このリポジトリで[issueを開いて](https://github.com/presire/claude-desktop-suse/issues)ください。

## 機能

- **ネイティブLinuxサポート**: 仮想化やWineを使わずにClaude Desktopを実行
- **MCPサポート**: Model Context Protocolの完全統合
  設定ファイルの場所: `~/.config/Claude/claude_desktop_config.json`
- **システム統合**:
  - X11グローバルホットキーサポート（Ctrl+Alt+Space）
  - システムトレイ統合
  - デスクトップ環境統合
- **カスタマイズ可能なインストールパス**: `--prefix` でインストールディレクトリを指定可能

### スクリーンショット

![Linux上で動作するClaude Desktop](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![グローバルホットキーポップアップ](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![KDEのシステムトレイメニュー](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## インストール

### ソースからのビルド

#### 前提条件

ビルド前に必要なパッケージをインストールしてください:

```bash
sudo zypper install git gcc-c++ make
```

| パッケージ | 用途 |
|-----------|------|
| `git` | リポジトリのクローン |
| `gcc-c++` | node-ptyネイティブモジュールのコンパイル（Claude Codeターミナル機能に必要） |
| `make` | ネイティブコンパイル用ビルドシステム |

**注意:** node-ptyネイティブモジュール（Claude Codeターミナル機能用）のビルドには**Python 3.8以降**が必要です。システムのデフォルトPythonが古い場合（例: openSUSE Leap 15.xのPython 3.6）、node-ptyのコンパイルは失敗します。Claude Desktop自体はビルド・動作しますが、Claude Codeターミナル機能は利用できません。

**RPMビルド** (`./build.sh`、デフォルト):

ビルドスクリプトが残りの依存関係をzypper経由で自動インストールします:

| 自動インストールされるパッケージ | 用途 |
|-------------------------------|------|
| `p7zip` | Windowsインストーラーの展開（7z形式） |
| `wget` | Claude Desktopインストーラーおよびnode.jsのダウンロード |
| `icoutils` | Windows実行ファイルからのアイコン抽出（`wrestool`, `icotool`） |
| `ImageMagick` | Linux向けトレイアイコンの画像処理 |
| `rpm-build` | RPMパッケージのビルド（`rpmbuild`コマンド） |

**AppImageビルド** (`./build.sh --build appimage`):

ビルド前に追加で `libfuse2` をインストールしてください:

```bash
sudo zypper install libfuse2
```

| パッケージ | 用途 |
|-----------|------|
| `libfuse2` | appimagetoolによるAppImageファイル生成に必要 |

上記の共通依存関係（`p7zip`, `wget`, `icoutils`, `ImageMagick`）はAppImageビルドでも自動インストールされます。Node.js 20+は未インストールの場合、ローカルに自動ダウンロードされます。

#### ビルド手順

```bash
# リポジトリのクローン
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# RPMパッケージのビルド（デフォルト）
./build.sh

# AppImageのビルド
./build.sh --build appimage

# カスタムインストールプレフィックスでビルド（RPMのみ）
./build.sh --prefix /opt

# 中間ファイルを保持してビルド
./build.sh --clean no
```

#### ビルドしたパッケージのインストール

```bash
# パッケージのインストール
sudo zypper install ./claude-desktop-VERSION-ARCHITECTURE.rpm

# またはrpmを直接使用:
sudo rpm -ivh ./claude-desktop-VERSION-ARCHITECTURE.rpm
```

## 設定

### MCP設定

Model Context Protocolの設定は以下に保存されます:
```
~/.config/Claude/claude_desktop_config.json
```

### アプリケーションログ

実行時のログは以下で確認できます:
```
$HOME/.cache/claude-desktop-suse/launcher.log
```

## アンインストール

```bash
# パッケージの削除
sudo zypper remove claude-desktop

# またはrpmを直接使用:
sudo rpm -e claude-desktop
```

**ユーザー設定の削除:**
```bash
rm -rf ~/.config/Claude
```

## トラブルシューティング

### ウィンドウスケーリングの問題

初回起動時にウィンドウが正しくスケーリングされない場合:
1. Claude Desktopトレイアイコンを右クリック
2. 「終了」を選択（強制終了しないでください）
3. アプリケーションを再起動

これにより、アプリケーションがディスプレイ設定を適切に保存できるようになります。

### よくある問題

- すべての依存関係がインストールされていることを確認: `sudo zypper install nodejs npm p7zip`
- `$HOME/.cache/claude-desktop-suse/launcher.log`のログファイルを確認
- Electronが適切にパッケージされているか確認（デフォルト: `/usr/lib/claude-desktop/`）

## 技術詳細

### 仕組み

Claude DesktopはWindows用に配布されているElectronアプリケーションです。このプロジェクトは:

1. 公式のWindowsインストーラーをダウンロード
2. アプリケーションリソースを抽出
3. Linux互換パッチを適用（フレーム修正、トレイ統合、ネイティブモジュールスタブ）
4. ターミナルサポート用にnode-ptyをインストール
5. openSUSE/SLE向けRPMパッケージまたはAppImageとして再パッケージ

### ビルドスクリプト

- `build.sh` - メインビルドスクリプト（openSUSE/SLEを自動検出）
- `scripts/build-rpm-package.sh` - RPMパッケージビルダー（build.shから呼び出される）
- `scripts/build-appimage.sh` - AppImageビルダー（`--build appimage` で呼び出される）
- `scripts/launcher-common.sh` - 共有ランチャー関数（Wayland/X11検出）
- `scripts/frame-fix-wrapper.js` - Linux向けElectron BrowserWindowフレーム修正
- `scripts/claude-native-stub.js` - Linux互換性のためのネイティブモジュールスタブ

### ビルドオプション

| オプション | 説明 | デフォルト |
|-----------|------|-----------|
| `--build rpm\|appimage` | ビルドフォーマット | `rpm` |
| `--clean yes\|no` | 中間ファイルの削除 | `yes` |
| `--prefix /path` | インストールプレフィックス | `/usr/lib` |
| `--exe /path/to/installer.exe` | ローカルインストーラーを使用 | ダウンロード |
| `--release-tag TAG` | バージョニング用リリースタグ | なし |

## ディストリビューションサポート

### テスト済みディストリビューション

- openSUSE Leap 15.5以降
- openSUSE Tumbleweed
- SUSE Linux Enterprise 15 SP5以降

## 謝辞

このフォークは[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)をベースにしています。

元のプロジェクトは、[k3d3のclaude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake)と、LinuxでClaude Desktopをネイティブに実行することについての[Reddit投稿](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/)にインスパイアされました。

特別な感謝:
- **aaddrick** - 元のDebianビルドスクリプト
- **k3d3** - 元のNixOS実装とネイティブバインディングの洞察
- **[emsi](https://github.com/emsi/claude-desktop)** - タイトルバー修正と代替実装アプローチ

NixOSユーザーの方は、Nix固有の実装について[k3d3のリポジトリ](https://github.com/k3d3/claude-desktop-linux-flake)を参照してください。

## ライセンス

このリポジトリのビルドスクリプトは、以下のデュアルライセンスの下でライセンスされています:
- MITライセンス（[LICENSE-MIT](LICENSE-MIT)を参照）
- Apache License 2.0（[LICENSE-APACHE](LICENSE-APACHE)を参照）

Claude Desktopアプリケーション自体は、[Anthropicの消費者向け利用規約](https://www.anthropic.com/legal/consumer-terms)の対象となります。

## 貢献

貢献を歓迎します！貢献を提出することにより、このプロジェクトと同じデュアルライセンス条件の下でライセンスすることに同意したものとみなされます。

元のDebianビルドスクリプトに関連する貢献については、[上流のリポジトリ](https://github.com/aaddrick/claude-desktop-debian)への貢献もご検討ください。
