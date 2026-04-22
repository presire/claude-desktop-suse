# Claude Desktop for openSUSE/SUSE Linux Enterprise

これは[aaddrick/claude-desktop-debian](https://github.com/aaddrick/claude-desktop-debian)のフォークで、openSUSEおよびSUSE Linux Enterpriseディストリビューション向けに適応されています。  

このプロジェクトは、Claude DesktopをopenSUSE/SUSE Linux Enterpriseでネイティブに実行するためのビルドスクリプトを提供します。  
公式のWindowsアプリケーションを再パッケージし、`.rpm`パッケージを生成します。  

**注意:**  
これは非公式のビルドスクリプトです。  
公式サポートについては、[Anthropicのウェブサイト](https://www.anthropic.com)をご覧ください。  
ビルドスクリプトやLinux実装に関する問題については、このリポジトリで[issueを開いて](https://github.com/presire/claude-desktop-suse/issues)ください。  

---

> **実験的機能: Coworkモードサポート**  
> Coworkモードはこのビルドで**デフォルトで有効**です。プラガブルな分離バックエンドを使用します。  
>
> | バックエンド | 分離方式 | 要件 |
> |------------|---------|------|
> | **bubblewrap**（デフォルト） | 名前空間サンドボックス | `bwrap` がインストールされ機能すること |
> | **host**（フォールバック） | 分離なし — ホスト上で直接実行 | 追加要件なし |
>
> 最適なバックエンドは起動時に自動検出されます。  
> `claude-desktop --doctor` を実行して、どのバックエンドが使用され、どの依存関係が不足しているかを確認できます。  
>
> **注意:**  
> bubblewrapバックエンドはホームディレクトリを読み取り専用でマウントします。(プロジェクトの作業ディレクトリのみ書き込み可能)  
> サンドボックスのマウントポイント（追加の読み取り専用/読み書きバインド、デフォルトマウントの無効化）は  
> `~/.config/Claude/claude_desktop_linux_config.json` でカスタマイズできます。詳細は [Configuration > Cowork Sandbox Mounts](docs/CONFIGURATION.md#cowork-sandbox-mounts) を参照してください。  
> hostバックエンドは分離を提供しません — セキュリティ上の影響を理解した上でのみ使用してください。  
>
> **KVMステータス:** KVM/QEMUバックエンドのコードは存在しますが、現在は非機能です — チェックサムループを防止するため、LinuxではVMファイルのダウンロードが無効化されています。将来の使用に備えてバックエンドコードは残されています。  

---

## 機能

- **ネイティブLinuxサポート**: 仮想化やWineを使わずにClaude Desktopを実行
- **MCPサポート**: Model Context Protocolの完全統合  
  設定ファイルの場所: `~/.config/Claude/claude_desktop_config.json`  
- **Coworkモード**: プラガブルな分離バックエンド（KVM / bubblewrap / host）と自動検出
- **診断機能**: `claude-desktop --doctor` による包括的ヘルスチェック
- **システム統合**:
  - グローバルホットキーサポート（Ctrl+Alt+Space） - X11およびWayland（XWayland経由）で動作
  - システムトレイ統合
  - デスクトップ環境統合
  - `CLAUDE_MENU_BAR` 環境変数によるメニューバー表示制御
  - XRDPリモートセッション検出（ウィンドウ白画面防止のためGPU合成を自動無効化）
- **カスタマイズ可能なインストールパス**: `--prefix` でインストールディレクトリを指定可能

### スクリーンショット

![Linux上で動作するClaude Desktop](screenshot/screenshot_01.png)

![グローバルホットキーポップアップ](screenshot/screenshot_02.png)

## インストール

### ソースからのビルド

詳細なビルド手順、技術的な詳細、手動アップデート方法については [docs/BUILDING.md](docs/BUILDING.md) を参照してください。

#### 前提条件

ビルド前に必要なパッケージをインストールしてください。  

```bash
sudo zypper install git gcc-c++ make
```

| パッケージ | 用途 |
|-----------|------|
| `git` | リポジトリのクローン |
| `gcc-c++` | node-ptyネイティブモジュールのコンパイル（Claude Codeターミナル機能に必要） |
| `make` | ネイティブコンパイル用ビルドシステム |

**注意:**
node-ptyネイティブモジュール（Claude Codeターミナル機能用）のビルドには**Python 3.8以降**が必要です。
システムのデフォルトPythonが古い場合（例: openSUSE Leap 15.xのPython 3.6）、`node-gyp`が使用するPythonのウォルラス演算子（`:=`、Python 3.8で導入）が原因で`gyp`の`SyntaxError: invalid syntax`エラーが発生し、node-ptyのコンパイルは失敗します。
Claude Desktop自体はビルド・動作しますが、Claude Codeターミナル機能は利用できません。

この問題を解決するには、ビルド前にPython 3.8以降のパスを指定してください:

```bash
# 現在のPythonバージョンを確認
python3 --version

# Python 3.8以降が別のパスにインストールされている場合:
export PYTHON=/path/to/python3.8+
./build.sh

# またはnpm設定で指定:
npm config set python /path/to/python3.8+
```

**RPMビルド** (`./build.sh`、デフォルト):  

ビルドスクリプトが残りの依存関係をzypper経由で自動インストールします。  

| 自動インストールされるパッケージ | 用途 |
|-------------------------------|------|
| `p7zip` | Windowsインストーラーの展開（7z形式） |
| `wget` | Claude Desktopインストーラーおよびnode.jsのダウンロード |
| `icoutils` | Windows実行ファイルからのアイコン抽出（`wrestool`, `icotool`） |
| `ImageMagick` | Linux向けトレイアイコンの画像処理 |
| `rpm-build` | RPMパッケージのビルド（`rpmbuild`コマンド） |

**AppImageビルド** (`./build.sh --build appimage`):  

ビルド前に追加で `libfuse2` をインストールしてください。  

```bash
sudo zypper install libfuse2
```

| パッケージ | 用途 |
|-----------|------|
| `libfuse2` | appimagetoolによるAppImageファイル生成に必要 |

上記の共通依存関係（`p7zip`, `wget`, `icoutils`, `ImageMagick`）はAppImageビルドでも自動インストールされます。  
Node.js 20+は未インストールの場合、ローカルに自動ダウンロードされます。  

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

Model Context Protocolの設定は以下に保存されます。  

```
~/.config/Claude/claude_desktop_config.json
```

### 環境変数

| 変数 | 値 | デフォルト | 説明 |
|------|-----|-----------|------|
| `CLAUDE_MENU_BAR` | `auto`, `visible`, `hidden` | `auto` | メニューバーの表示。`auto`: デフォルトで非表示、Altでトグル。`visible`: 常に表示。`hidden`: 常に非表示。 |
| `CLAUDE_USE_WAYLAND` | `1` | 未設定 | `1` に設定するとネイティブWaylandモード（グローバルホットキー無効）。デフォルトはXWayland経由のX11。 |
| `COWORK_VM_BACKEND` | `kvm`, `bwrap`, `host` | 自動検出 | Cowork分離バックエンドの選択を上書き。 |
| `COWORK_VM_DEBUG` | `1` | 未設定 | Coworkデーモンの詳細ログを有効化。 |
| `CLAUDE_LINUX_DEBUG` | `1` | 未設定 | Linux移植全般のデバッグログを有効化（ランチャーおよびデーモン）。 |

### アプリケーションログ

実行時のログは以下で確認できます。  

```
$HOME/.cache/claude-desktop-suse/launcher.log
```

Coworkデーモンログ:  

```
$HOME/.config/Claude/logs/cowork_vm_daemon.log
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

`claude-desktop --doctor` を実行すると、よくある問題を自動診断できます。(ディスプレイサーバ、サンドボックス権限、MCP設定、staleロック等)  
Coworkモードの準備状況 — 使用されるバックエンドと、不足している依存関係（KVM、QEMU、vsock、socat、virtiofsd、bubblewrap）も確認できます。  

### ウィンドウスケーリングの問題

初回起動時にウィンドウが正しくスケーリングされない場合:  
1. Claude Desktopトレイアイコンを右クリック  
2. 「終了」を選択（強制終了しないでください）  
3. アプリケーションを再起動  

これにより、アプリケーションがディスプレイ設定を適切に保存できるようになります。  

### よくある問題

- `claude-desktop --doctor` を実行して問題を自動診断
- `$HOME/.cache/claude-desktop-suse/launcher.log`のログファイルを確認
- Electronが適切にパッケージされているか確認（デフォルト: `/usr/lib/claude-desktop/`）

## 技術詳細

### 仕組み

Claude DesktopはWindows用に配布されているElectronアプリケーションです。  

このプロジェクトは:  

1. 公式のWindowsインストーラーをダウンロード  
2. アプリケーションリソースを抽出  
3. Linux互換パッチを適用（フレーム修正、トレイ統合、ネイティブモジュールスタブ、Coworkモード、Claude Code）  
4. ターミナルサポート用にnode-ptyをインストール  
5. openSUSE/SLE向けRPMパッケージまたはAppImageとして再パッケージ  

### ビルドスクリプト

- `build.sh` - メインビルドスクリプト（openSUSE/SLEを自動検出）
- `scripts/build-rpm-package.sh` - RPMパッケージビルダー（build.shから呼び出される）
- `scripts/build-appimage.sh` - AppImageビルダー（`--build appimage` で呼び出される）
- `scripts/launcher-common.sh` - 共有ランチャー関数（Wayland/X11検出、XRDPセッション検出、`--doctor` 診断、孤立デーモンクリーンアップ、staleロック/ソケット削除）
- `scripts/frame-fix-wrapper.js` - Linux向けElectron BrowserWindowフレーム修正（メニューバー制御、Ctrl+Qキーボードハンドリング、KWinバウンド修正）
- `scripts/claude-native-stub.js` - Linux互換性のためのネイティブモジュールスタブ
- `scripts/cowork-vm-service.js` - Cowork VMサービスデーモン（プラガブルKVM/bwrap/hostバックエンド、ライフサイクルログ）
- `tests/cowork-path-translation.bats` - Coworkパス変換のBATSテストスイート
- `tests/cowork-backend-detection.bats` - bwrapプローブエラー分類のBATSテストスイート
- `tests/launcher-xrdp-detection.bats` - XRDPセッション検出のBATSテストスイート

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

元のプロジェクトは、[k3d3のclaude-desktop-linux-flake](https://github.com/k3d3/claude-desktop-linux-flake)と、  
LinuxでClaude Desktopをネイティブに実行することについての[Reddit投稿](https://www.reddit.com/r/ClaudeAI/comments/1hgsmpq/i_successfully_ran_claude_desktop_natively_on/)にインスパイアされました。  

特別な感謝:  

- **aaddrick** - 元のDebianビルドスクリプト
- **k3d3** - 元のNixOS実装とネイティブバインディングの洞察
- **[emsi](https://github.com/emsi/claude-desktop)** - タイトルバー修正と代替実装アプローチ
- **[leobuskin](https://github.com/leobuskin/unofficial-claude-desktop-linux)** - PlaywrightベースのURL解決アプローチ
- **[yarikoptic](https://github.com/yarikoptic)** - codespellサポートとshellcheck準拠
- **[IamGianluca](https://github.com/IamGianluca)** - ビルド依存関係チェックの改善
- **[ing03201](https://github.com/ing03201)** - IBus/Fcitx5 入力メソッドサポート
- **[ajescudero](https://github.com/ajescudero)** - Node互換性のための@electron/asarピン留め
- **[delorenj](https://github.com/delorenj)** - Wayland互換性サポート
- **[Regen-forest](https://github.com/Regen-forest)** - Gear LeverをAppImageLauncher代替として提案
- **[niekvugteveen](https://github.com/niekvugteveen)** - Debianパッケージング権限の修正
- **[speleoalex](https://github.com/speleoalex)** - ネイティブウィンドウ装飾サポート
- **[imaginalnika](https://github.com/imaginalnika)** - ログを `~/.cache/` へ移動
- **[richardspicer](https://github.com/richardspicer)** - Linux上のメニューバー表示修正
- **[jacobfrantz1](https://github.com/jacobfrantz1)** - Claude Desktopコードプレビューサポートとクイックウィンドウ送信修正
- **[janfrederik](https://github.com/janfrederik)** - ローカルインストーラを使用するための `--exe` フラグ
- **[MrEdwards007](https://github.com/MrEdwards007)** - OAuthトークンキャッシュ修正の発見
- **[lizthegrey](https://github.com/lizthegrey)** - バージョン更新への貢献
- **[mathys-lopinto](https://github.com/mathys-lopinto)** - AURパッケージと自動デプロイ
- **[pkuijpers](https://github.com/pkuijpers)** - RPMリポジトリGPG署名問題の根本原因分析
- **[dlepold](https://github.com/dlepold)** - トレイアイコン変数名バグの特定と修正
- **[Voork1144](https://github.com/Voork1144)** - トレイアイコンミニファイアバグの詳細分析、Chromiumレイアウトキャッシュバグの根本原因分析、直接子 `setBounds()` 修正アプローチ
- **[sabiut](https://github.com/sabiut)** - `--doctor` 診断コマンド、ダウンロード用SHA-256チェックサム検証、deb/rpm/AppImageアーティファクトのビルド後統合テスト
- **[milog1994](https://github.com/milog1994)** - ポップアップ検出、機能スタブ、Waylandコンポジタサポートを含むLinux UX改善
- **[jarrodcolburn](https://github.com/jarrodcolburn)** - コンテナ/CI環境でのパスワードレスsudoサポート、gh-pages 4GB肥大化修正の特定、Debianでのvirtiofsdパス検出問題の特定、CIリリースパイプライン障害の詳細分析、session-startフックのsudoブロッキング問題の診断
- **[chukfinley](https://github.com/chukfinley)** - LinuxでのCowork モード実験的サポート
- **[CyPack](https://github.com/CyPack)** - 起動時の孤立したcoworkデーモンクリーンアップ
- **[IliyaBrook](https://github.com/IliyaBrook)** - Claude Desktop >= 1.1.3541 arm64リファクタのプラットフォームパッチ修正
- **[MichaelMKenny](https://github.com/MichaelMKenny)** - `$`プレフィックス付きelectron変数バグの診断と回避策
- **[daa25209](https://github.com/daa25209)** - coworkプラットフォームゲートクラッシュの詳細な根本原因分析とパッチスクリプト
- **[noctuum](https://github.com/noctuum)** - 設定可能なメニューバー表示とブール別名サポート付き `CLAUDE_MENU_BAR` 環境変数
- **[typedrat](https://github.com/typedrat)** - build.sh、node-pty derivation、CI自動更新を統合したNixOSフレーク、フレークパッケージスコーピングリグレッションの修正
- **[cbonnissent](https://github.com/cbonnissent)** - Cowork VMゲストRPCプロトコルのリバースエンジニアリング、KVM起動ブロッカーの修正、永続接続向けRPCレスポンスIDエコーイングの修正、専用Linux設定ファイルによる設定可能なbwrapマウントポイント
- **[joekale-pp](https://github.com/joekale-pp)** - RPMランチャーへの `--doctor` サポート追加
- **[ecrevisseMiroir](https://github.com/ecrevisseMiroir)** - tmpfsベースの最小ルートを使用したbwrapバックエンドサンドボックス分離
- **[arauhala](https://github.com/arauhala)** - NixOS `isPackaged` リグレッションの詳細な根本原因分析
- **[cromagnone](https://github.com/cromagnone)** - 初期トリアージを覆す詳細なログによるbwrapインストール上のVMダウンロードループ確認
- **[aHk-coder](https://github.com/aHk-coder)** - cowork smol-binパッチでのハードコード化されたミニファイ変数クラッシュの診断
- **[RayCharlizard](https://github.com/RayCharlizard)** - 自己参照 `.mcpb-cache` symlink ELOOP バグの詳細分析、HostBackendでの自動メモリパス変換の修正
- **[reinthal](https://github.com/reinthal)** - nixpkgsの `nodePackages` 削除によるNixOSビルドブレークの修正
- **[gianluca-peri](https://github.com/gianluca-peri)** - GNOMEの終了アクセシビリティ問題の報告とAppIndicatorでのトレイ動作の確認
- **[martin152](https://github.com/martin152)** - ランチャークリーンアップの3つのバグ（`cleanup_orphaned_cowork_daemon`の自己マッチ、`cleanup_stale_cowork_socket`のsocat依存no-op、`--doctor`での同様の自己マッチ）の詳細診断と完全なパッチ
- **[hfyeh](https://github.com/hfyeh)** - Ubuntu 24.04 AppArmor非特権ユーザー名前空間ブロックのCowork bwrapでの診断とAppArmorプロファイル回避策の提供
- **[davidamacey](https://github.com/davidamacey)** - リモートデスクトップセッションでのXRDP GPU合成による白画面問題の特定と修正
- **[pb3ck](https://github.com/pb3ck)** - Cowork `CLAUDE_CODE_OAUTH_TOKEN` 環境変数ストリップバグの診断と動作する参照diffの提供
- **[aJV99](https://github.com/aJV99)** - ネイティブWaylandモードでの `GDK_BACKEND=wayland` エクスポートによるHiDPIディスプレイでのXWaylandフォールバックぼやけの修正

NixOSユーザーの方は、Nix固有の実装について[k3d3のリポジトリ](https://github.com/k3d3/claude-desktop-linux-flake)を参照してください。  

## ライセンス

このリポジトリのビルドスクリプトは、以下のデュアルライセンスの下でライセンスされています。  

- MITライセンス（[LICENSE-MIT](LICENSE-MIT)を参照）
- Apache License 2.0（[LICENSE-APACHE](LICENSE-APACHE)を参照）

Claude Desktopアプリケーション自体は、[Anthropicの消費者向け利用規約](https://www.anthropic.com/legal/consumer-terms)の対象となります。  

## 貢献

貢献を歓迎します！貢献を提出することにより、このプロジェクトと同じデュアルライセンス条件の下でライセンスすることに同意したものとみなされます。  

元のDebianビルドスクリプトに関連する貢献については、[上流のリポジトリ](https://github.com/aaddrick/claude-desktop-debian)への貢献もご検討ください。  
