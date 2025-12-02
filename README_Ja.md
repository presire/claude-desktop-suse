# Claude Desktop for Linux（openSUSE/SLE対応版）

これは[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)のフォークで、openSUSEおよびSUSE Linux Enterpriseディストリビューションのサポートが追加されています。

このプロジェクトは、Claude DesktopをLinuxシステムでネイティブに実行するためのビルドスクリプトを提供します。
公式のWindowsアプリケーションを、DebianベースおよびopenSUSE/SLEディストリビューション向けに再パッケージし、`.deb`パッケージ、`.rpm`パッケージ、またはAppImageを生成します。

**注意:**
これは非公式のビルドスクリプトです。
公式サポートについては、[Anthropicのウェブサイト](https://www.anthropic.com)をご覧ください。
ビルドスクリプトやLinux実装に関する問題については、このリポジトリで[issueを開いて](https://github.com/presire/claude-desktop-suse/issues)ください。

## このフォークの追加機能

- ✨ **openSUSE/SLEサポート**: openSUSEおよびSUSE Linux Enterprise用のRPMパッケージのビルド
- 📦 新しいビルドスクリプト: `build-suse.sh`および`build-rpm-package.sh`
- 🔧 DebianベースとRPMベースの両方のディストリビューションとの完全な互換性

## 機能

- **ネイティブLinuxサポート**: 仮想化やWineを使わずにClaude Desktopを実行
- **MCPサポート**: Model Context Protocolの完全統合
  設定ファイルの場所: `~/.config/Claude/claude_desktop_config.json`
- **システム統合**:
  - X11グローバルホットキーサポート（Ctrl+Alt+Space）
  - システムトレイ統合
  - デスクトップ環境統合
- **マルチディストリビューションサポート**:
  - Debianベース: `.deb`パッケージ
  - openSUSE/SLE: `.rpm`パッケージ
  - ユニバーサル: AppImages

### スクリーンショット

![Linux上で動作するClaude Desktop](https://github.com/user-attachments/assets/93080028-6f71-48bd-8e59-5149d148cd45)

![グローバルホットキーポップアップ](https://github.com/user-attachments/assets/1deb4604-4c06-4e4b-b63f-7f6ef9ef28c1)

![KDEのシステムトレイメニュー](https://github.com/user-attachments/assets/ba209824-8afb-437c-a944-b53fd9ecd559)

## インストール

### ソースからのビルド

#### 前提条件

**Debianベースのディストリビューション（Debian、Ubuntu、Linux Mint、MX Linuxなど）の場合:**
- Git
- 基本的なビルドツール（スクリプトによって自動的にインストールされます）

**openSUSE/SLEディストリビューションの場合:**
- Git
- rpm-build（スクリプトによって自動的にインストールされます）
- 基本的なビルドツール

#### ビルド手順

**Debianベースのディストリビューションの場合:**
```bash
# リポジトリのクローン
git clone https://github.com/presire/claude-desktop-debian.git
cd claude-desktop-debian

# .debパッケージのビルド（デフォルト）
./build.sh

# AppImageのビルド
./build.sh --build appimage

# カスタムオプションでのビルド
./build.sh --build deb --clean no  # 中間ファイルを保持
```

**openSUSE/SLEディストリビューションの場合:**
```bash
# リポジトリのクローン
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# RPMパッケージのビルド
./build-suse.sh

# スクリプトは自動的にシステムアーキテクチャを検出します
```

#### ビルドしたパッケージのインストール

**.debパッケージの場合（Debian、Ubuntuなど）:**
```bash
sudo dpkg -i ./claude-desktop_VERSION_ARCHITECTURE.deb

# 依存関係の問題が発生した場合:
sudo apt --fix-broken install
```

**.rpmパッケージの場合（openSUSE、SUSE）:**
```bash
# パッケージのインストール
sudo zypper install ./claude-desktop-VERSION-ARCHITECTURE.rpm

# またはrpmを直接使用:
sudo rpm -ivh ./claude-desktop-VERSION-ARCHITECTURE.rpm
```

**AppImageの場合:**
```bash
# 実行可能にする
chmod +x ./claude-desktop-*.AppImage

# 直接実行
./claude-desktop-*.AppImage

# またはGear Leverを使ってシステムに統合
```

**注意:** AppImageのログインには適切なデスクトップ統合が必要です。[Gear Lever](https://flathub.org/apps/it.mijorus.gearlever)を使用するか、提供された`.desktop`ファイルを`~/.local/share/applications/`に手動でインストールしてください。

**自動更新:** GitHubリリースからダウンロードしたAppImageには埋め込まれた更新情報が含まれており、Gear Leverとシームレスに連携して自動更新が可能です。ローカルでビルドされたAppImageは、Gear Leverで手動で更新設定を行うことができます。

## 設定

### MCP設定

Model Context Protocolの設定は以下に保存されます:
```
~/.config/Claude/claude_desktop_config.json
```

### アプリケーションログ

実行時のログは以下で確認できます:

**Debianベースのディストリビューションの場合:**
```
$HOME/.cache/claude-desktop-debian/launcher.log
```

**openSUSE/SLEディストリビューションの場合:**
```
$HOME/.cache/claude-desktop-opensuse/launcher.log
```

## アンインストール

**.debパッケージの場合:**
```bash
# パッケージの削除
sudo dpkg -r claude-desktop

# パッケージと設定の削除
sudo dpkg -P claude-desktop
```

**.rpmパッケージの場合:**
```bash
# パッケージの削除
sudo zypper remove claude-desktop

# またはrpmを直接使用:
sudo rpm -e claude-desktop
```

**AppImageの場合:**
1. `.AppImage`ファイルを削除
2. `~/.local/share/applications/`から`.desktop`ファイルを削除
3. Gear Leverを使用している場合は、そのアンインストールオプションを使用

**ユーザー設定の削除（すべての形式）:**
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

### AppImageサンドボックス警告

AppImageは、electronのchrome-sandboxが特権のないネームスペース作成にroot権限を必要とするため、`--no-sandbox`で実行されます。これはElectronアプリケーションのAppImage形式の既知の制限です。

セキュリティ強化のために、以下を検討してください:
- 代わりに.debまたは.rpmパッケージを使用
- AppImageを別のサンドボックス内で実行（例: bubblewrap）
- より良い隔離のためにGear Leverの統合AppImage管理を使用

### openSUSE/SLE固有の問題

openSUSE/SLEで問題が発生した場合:
- すべての依存関係がインストールされていることを確認: `sudo zypper install nodejs npm p7zip`
- `$HOME/.cache/claude-desktop-opensuse/launcher.log`のログファイルを確認
- `/opt/claude-desktop/`にElectronが適切にパッケージされているか確認

## 技術詳細

### 仕組み

Claude DesktopはWindows用に配布されているElectronアプリケーションです。このプロジェクトは:

1. 公式のWindowsインストーラーをダウンロード
2. アプリケーションリソースを抽出
3. Windows固有のネイティブモジュールをLinux互換の実装に置き換え
4. 以下のいずれかとして再パッケージ:
   - **Debianパッケージ(.deb)**: Debianベースディストリビューション用の標準システムパッケージ
   - **RPMパッケージ(.rpm)**: openSUSE/SLEディストリビューション用の標準システムパッケージ
   - **AppImage**: どのディストリビューションでも使用できる、ポータブルで自己完結型の実行ファイル

### ビルドプロセス

ビルドスクリプトは以下を処理します:
- 依存関係のチェックとインストール
- Windowsインストーラーからのリソース抽出
- Linuxデスクトップ標準に合わせたアイコン処理
- ネイティブモジュールの置き換え
- 選択した形式とディストリビューションに基づくパッケージ生成

**ビルドスクリプト:**
- `build.sh` - Debianベースディストリビューション用のメインビルドスクリプト
- `build-deb-package.sh` - Debianパッケージビルダー（build.shから呼び出される）
- `build-suse.sh` - openSUSE/SLEディストリビューション用のビルドスクリプト
- `build-rpm-package.sh` - RPMパッケージビルダー（build-suse.shから呼び出される）

### 新しいリリースへの更新

スクリプトは自動的にシステムアーキテクチャを検出し、適切なバージョンをダウンロードします。Claude DesktopのダウンロードURLが変更された場合は、各ビルドスクリプトの`CLAUDE_DOWNLOAD_URL`変数を更新してください。

## ディストリビューションサポート

### テスト済みディストリビューション

**Debianベース（.deb経由）:**
- Debian 11、12
- Ubuntu 20.04、22.04、24.04
- Linux Mint 20、21、22
- MX Linux 21、23

**openSUSE/SLE（.rpm経由）:**
- openSUSE Leap 15.5以降
- openSUSE Tumbleweed
- SUSE Linux Enterprise 15 SP5以降

**ユニバーサル（AppImage経由）:**
- glibc 2.31以降を搭載した最新のLinuxディストリビューション

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
