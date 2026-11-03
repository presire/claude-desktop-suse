[< READMEに戻る](../README.md)

# ソースコードからのビルド

## 前提条件

- openSUSE Leap 16以降 / openSUSE Tumbleweed / SUSE Linux Enterprise 16以降  
- Git、gcc-c++、make  
- 基本的なビルドツール (スクリプトがzypper経由で自動インストール)  

### Node.jsとasar

ビルドには、Node.js **22.12.0以降**が必要です。(`scripts/setup/dependencies.sh`の`NODE_MIN_VERSION`)  

この下限は`@electron/asar` 4.xの`engines.node`制約です。  
npmは満たされない場合に警告するだけで、その後実行を拒否するラッパーをインストールします。  
古いホストでは、セットアップ手順がシステムのNodeを使わず、ローカルのNode 22.23.2を`build/node/`にダウンロードします。  

パッチ段階後に`app.asar`を再パックするasarは`@electron/asar@4.3.1`に固定されています。  
(`scripts/setup/dependencies.sh`の`ASAR_PINNED_VERSION`)  
その出力が`.rpm`と`.AppImage`に同梱されるためです。  

`--clean no`で保持した作業ディレクトリに別のasarバージョンがある場合は再インストールされ、  
ステージされたasarが固定バージョンを報告しない場合はビルドが失敗します。  
固定バージョンの更新は、意図的に行う1行の変更です。  

`scripts/verify-patches.sh`は`.asar`入力を見つかった最初の実行可能なasarで展開します:  
`ASAR_BIN`、`build/node_modules/.bin/asar`、次に`PATH`上の`asar`の順です。  
ダウンロードは一切行いません。  

ローカルコピーを配置するには`./build.sh`を一度実行するか、`ASAR_BIN`を動作するCLIに向けてください。  

<br>

## ビルド手順

```bash
# Clone the repository
git clone https://github.com/presire/claude-desktop-suse.git
cd claude-desktop-suse

# Build RPM package (default)
./build.sh

# Or specify a format explicitly:
./build.sh --build rpm       # openSUSE/SLE .rpm package
./build.sh --build appimage  # Distribution-agnostic AppImage

# Build with custom options
./build.sh --build rpm --clean no   # Keep intermediate files
./build.sh --prefix /usr/lib64      # Custom install prefix

# Build with dark-mode tray icons (white icons for dark panels)
./build.sh --dark
./build.sh --build appimage --dark  # Combine with other options

# Build input is the Windows `.nupkg` resolved by the build pipeline.
# Do not use a Linux `.deb` as build input.
```

### Claudeのバージョン

デフォルトでは、ビルドはパッチスクリプトの検証対象であるClaudeリリースをダウンロードして  
(`scripts/setup/detect-host.sh`の`CLAUDE_PINNED_VERSION`、現在は`4.4212.0`)、
対象アーキテクチャ用に固定されたSHA-256と照合します。  
(詳しくは、[D-005](DECISIONS.md#d-005--builds-default-to-a-verified-claude-release)を参照)  

不一致の場合はビルドが中止されます。  
CIのビルドワークフローも同じバージョンを明示的に渡して (`.github/workflows/test-artifacts.yml`と`release.yml`の`CLAUDE_DESKTOP_VERSION`)、  
`CLAUDE_PINNED_VERSION`と異なる場合は失敗します。  
そのため、固定バージョンの更新では`detect-host.sh`と両方のワークフローを同時に更新します。  

```bash
./build.sh --claude-version latest            # Newest release in RELEASES (SHA-1 verified; patches may not apply)
./build.sh --claude-version X.Y.Z \
  --claude-sha256 HASH                        # Another release, verified against your hash
```

固定バージョン以外は、`--claude-sha256`を指定した場合、  
またはAnthropicの`RELEASES`ファイルにまだ記載されている場合にのみチェックサム検証されます。(同ファイルには最新リリースのみが記載されます)  

### x64ホスト上でのarm64パッケージのビルド

`--arch arm64`を指定すると、x86_64ホスト上でaarch64の`.rpm`または`.AppImage`をビルドします。  
Electronランタイムは対象アーキテクチャ向けに取得され (`scripts/setup/fetch-electron-binary.js`に渡される`ELECTRON_TARGET_ARCH`)、  
`--clean no`で保持した作業ディレクトリの`node_modules/electron/dist/electron`が別アーキテクチャ向けの場合は再利用せず再取得します。  

```bash
./build.sh --build rpm --arch arm64
./build.sh --build appimage --arch arm64
```

x64ホスト上でarm64パッケージのアーティファクトチェックを実行するには、  
qemu-user binfmtを登録し (`sudo zypper install qemu-linux-user`)、arm64コンテナ内で実行します。  

例: `podman run --arch arm64 registry.opensuse.org/opensuse/leap:16.0`  

エミュレーション下の起動は実ハードウェアよりはるかに遅くなります。  

ビルドスクリプトはopenSUSE/SLEではデフォルトでRPM形式になります:  

| ディストリビューション | デフォルト形式 | パッケージマネージャ |
|--------------|----------------|-----------------|
| openSUSE、SLE | `.rpm` | zypper |
| その他 | `.AppImage` | - |

<br>

## ビルドしたパッケージのインストール

### .rpmパッケージの場合 (openSUSE/SLE)

```bash
sudo zypper install ./claude-desktop-VERSION-ARCH.rpm
# Or: sudo rpm -i ./claude-desktop-VERSION-ARCH.rpm
```

### AppImageの場合

```bash
# Make executable
chmod +x ./claude-desktop-*.AppImage

# Run directly
./claude-desktop-*.AppImage

# Or integrate with your system using Gear Lever
```

> **注意:**  
> AppImageでのログインには適切なデスクトップ統合が必要です。  
> 
> [Gear Lever](https://flathub.org/apps/it.mijorus.gearlever)を使用するか、  
> 提供される`.desktop`ファイルを手動で`~/.local/share/applications/`にインストールしてください。  

AppImageビルドは、`PATH`に`appimagetool`がある場合はそれを使用します。  
無い場合は、固定された`appimagetool`リリースと固定された静的type2ランタイムをダウンロードし、  
両方を`scripts/packaging/appimage.sh`に記録されたSHA-256値と照合します。(不一致の場合はビルドが中止されます)  
生成されたAppImageは`fusermount3` (`fuse3`) を必要としますが、`libfuse2`は不要です。  

ローカルビルドには更新情報が埋め込まれません。  
リリースビルド (`GITHUB_ACTIONS`) は`gh-releases-zsync`更新情報を埋め込み、  
`appimagetool`が`.zsync`ファイルを生成しない場合は失敗します。  

<br>

## アーティファクトの検証

ビルドしたRPMおよびAppImageアーティファクトは、既存の低レベルチェックで検証してください。  
その後、分離されたL2検証には[アーティファクトおよび外部ハーネスの実行手順書](HARNESS.md)を使用してください。  

```bash
./tests/test-artifact-rpm.sh <artifact-dir>
./tests/test-artifact-appimage.sh <artifact-dir>
```

RPMスイートはパッケージをインストールして削除するため、使い捨てのコンテナ内でrootとして実行してください。  
(例: `opensuse/leap:16`を使ったrootless `podman`)  
`claude-desktop`が既にインストールされている環境では実行を拒否します。  

両方のスイートは、`app.asar.unpacked`にWindows PEの`.node`モジュールが同梱されていないことを確認します。  

現在の環境で実行できないチェック (`/dev/fuse`がない、`appstreamcli`がない、非特権のスモークテストユーザがいない等) はSKIPとして報告され、  
スイートを失敗させません。  
`ARTIFACT_FAIL_ON_SKIP=1`を設定すると、全てのSKIPが非ゼロ終了になります。  

`.github/workflows/test-artifacts.yml`はCIで下記を行います:  
`opensuse/leap:16.0`コンテナ内でx86_64の`.rpm`と`.AppImage`をビルドし、  
その後`ARTIFACT_FAIL_ON_SKIP=1`を指定して各スイートを個別のコンテナジョブで実行します。  

RPMスイートはrootとして実行します。  
AppImageはFUSEマウントチェックのため、`/dev/fuse`と`SYS_ADMIN`を取得して、非特権ユーザとして実行します。  
Electronは`--no-sandbox`なしではrootとして起動を拒否するためです。  

<br>

## 技術的な詳細

### 仕組み

Claude DesktopはWindows向けに配布されているElectronアプリケーションです。  

このプロジェクトは以下を行います:  

1. 公式のWindows `.nupkg`ビルド入力を解決する
2. nupkgからアプリケーションリソースを展開する
3. Windows固有のネイティブモジュールをLinux互換の実装に置き換え、
   nupkgに同梱されるすべてのWindows PE `*.node`を削除します。  
   (node-ptyの`conpty.node` / `conpty_console_list.node`、`claude-native`バインディング、office365-mcpの`msal-node-runtime.node`) 
   
   ファイルはパスではなく`MZ`ヘッダで判定されるため、この手順はx64とarm64で同じです。  
   再パック不変性チェックは、1つでも`app.asar.unpacked`に到達した場合にビルドを失敗させます。  
   その他のWindowsペイロード (`github-mcp-server.exe`、`msalruntime*.dll`) はNodeモジュールではないため、同梱されたまま残します。
4. Linux固有のパッチを適用する (フレーム修正、トレイ統合、Coworkモード)
5. 次のいずれかとして再パッケージする:  
   - **RPMパッケージ (.rpm)**: openSUSE、SUSE Linux Enterprise向け
   - **AppImage**: ポータブルでディストリビューション非依存の実行ファイル

### ビルドプロセス

ビルドスクリプト (`build.sh`) は以下を処理します:  
- 依存関係の確認とインストール (zypper経由)。確認対象のビルドツール (`gcc`、`gcc-c++`、`make`、`python3`) も含みます。  
  `node-pty`はプリビルドのLinuxバイナリとして配置されるため、node-gypによるコンパイルやPythonビルド手順は実行されません
- 公式リリースサーバからの動的バージョン解決
- Windowsインストーラからのリソース展開
- Linuxデスクトップ標準向けのアイコン処理
- ネイティブモジュールの置き換え (claude-nativeスタブ、node-pty)
- Linux互換性のための10以上のアプリケーションパッチ
- 選択した形式に基づくパッケージ生成

#### パッチ効果の確認

各機能パッチは、実行前と実行後に取得した`app.asar.contents/.vite/build`のダイジェストとともに実行されます。  
ダイジェストが変わらないパッチはビルドを失敗させます:  

```
Patch effect: '<function>' left app.asar.contents/.vite/build byte-identical.
```

これは通常、固定リリースがパッチのアンカーとするミニファイ済みコードの形を変更したことを意味します。  

アンカーを修正してください。  
チェックを無効化しないでください。  

意図的なNOPは、`scripts/patches/_common.sh`の`_PATCH_EFFECT_ALLOWLIST`に1行の理由付きで記載されています:  
例えば、変数を記録するだけでファイルを書き込まない`extract_electron_variable`や、上流リリースがすでにその動作を提供しているパッチです。  

許可リストに登録された関数は、そのレビュー済みブランチから`_declare_patch_noop`も呼び出す場合にのみ通過します。  
そのため、アンカーがずれた許可リスト済みパッチは依然として失敗します。  
非ゼロを返すパッチ関数は、`Patch stage: <function> failed (exit N)`でステージを失敗させます。  

`PATCH_STAGE_RERUN=1`は2回目のパスでこのパッチごとのチェックをスキップします。  
それは、全てのパッチがno-opになることが期待されるためです。  
ステージ全体の冪等性チェックは引き続き実行されます。  

> **Electronバージョンに関する注意:**  
> ビルドは`electron@^44`をインストールします。  
> これは、現在のWindows `.nupkg`に同梱されているメジャーバージョンです。(詳しくは[DECISIONS.md](DECISIONS.md)のD-004を参照)  
> 
> `--clean no`で保持した作業ディレクトリに別のElectronメジャーバージョンが残っている場合は自動的に再インストールされます。  
> 
> `electron@42.0.0`以降には`node_modules/electron/dist/`を埋めるpostinstallスクリプトがありません。  
> 代わりに`scripts/setup/fetch-electron-binary.js`がバイナリをダウンロードします。(上流のissue #584を参照)  

### 手動アップデート

特定のバージョンでビルドする必要がある場合は、対応するWindows `.nupkg`をビルドパイプライン経由で提供してください。  
ビルド入力としてLinuxの`.deb`を使用しないでください。  
