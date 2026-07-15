# Artifact and external harness verification

このページは、SUSE向けRPM/AppImageの低レベル検証と、通常のlauncherを使うL2外部確認の実行契約を定義します。

## Supported boundary

ビルド入力はAnthropicのWindows `.nupkg`です。出力とこの検証手順の対象は、openSUSE/SLE向けの`.rpm`と配布用`.AppImage`だけです。

RPMのインストール確認は`zypper`または`rpm -q`の運用に従います。外部harnessはRPMをホストへインストールせず、既に同じNEVRAのRPMがインストール済みの場合だけ通常の`/usr/bin/claude-desktop`を起動します。

## Artifact validators

低レベルのファイル、権限、desktop entry、`app.asar`、`--doctor`、`--version`、起動smokeの検証はBatsと既存のartifact validatorが担当します。

```bash
bats tests
./tests/test-artifact-common.sh
./tests/test-artifact-rpm.sh <artifact-dir>
./tests/test-artifact-appimage.sh <artifact-dir>
```

artifact validatorは、RPM/AppImageの`--version` fast pathを表示・D-Bus・ユーザー状態なしで確認します。artifactが指定ディレクトリにない場合は`[SKIP]`を出力して終了し、実artifactの検証済みPASSとは扱いません。artifactがある場合のlaunch smokeは、`xvfb-run`と`dbus-run-session`の下で全てのXDG rootを分離し、`setsid`のプロセスグループを終了処理します。

Batsとartifact validatorが低レベルの責務を持ち、外部harnessへ静的検査やpackage assertionを移しません。

## External harness invocation

外部harnessは、1回の実行につきRPMまたはAppImageを1つだけ受け取ります。

```bash
# Run from the claude-desktop-suse repository root.
./scripts/external-harness.sh \
	--artifact /path/to/claude-desktop-VERSION.x86_64.rpm \
	--results /tmp/opencode/claude-desktop-suse-results.jsonl

./scripts/external-harness.sh \
	--artifact /path/to/claude-desktop-VERSION-amd64.AppImage
```

`--results`を省略すると、結果は`/tmp/opencode/claude-desktop-suse-results.<pid>.jsonl`に保存されます。`--artifact`がない、複数ある、存在しない、または`.rpm`/`.AppImage`以外の場合は入力エラーです。

RPMは同一NEVRAのインストール済みlauncherが使える場合だけ通常起動を行います。未インストールのRPMは`rpm2cpio`/`cpio`でファイルprobe用に展開しますが、ホストのインストールを変更せず、起動probeはSKIPになります。AppImageは通常のAppImage launcherと`--appimage-extract`だけを使います。

## Isolation and cleanup

各実行は`/tmp/opencode/claude-desktop-suse-harness.XXXXXX`以下に新しいrun rootを作ります。callerが設定した値を再利用せず、`HOME`、`XDG_CONFIG_HOME`、`XDG_CACHE_HOME`、`XDG_DATA_HOME`、`XDG_STATE_HOME`、`XDG_RUNTIME_DIR`をこのrun rootへ向けます。runtime directoryはmode 700です。

probe logは`/tmp/opencode/claude-desktop-suse-logs.<pid>/`へ保持され、run rootは終了時に削除されます。起動したプロセスは`setsid`で作ったプロセスグループ単位で終了させます。既存のClaudeプロセスが対象WM_CLASSを使用している場合、干渉を避けるため起動をSKIPします。

実ユーザーの`~/.config/Claude`、`~/.cache/claude-desktop-suse`、認証情報、保存済みアプリ状態は使いません。

## Prerequisites and skip behavior

基本のfile probeにはBashと対象artifactが必要です。追加のprobeには次の依存関係を使います。

| Dependency | Purpose | Missing dependency result |
| --- | --- | --- |
| `rpm2cpio` and `cpio` | Uninstalled RPM file probes | RPM extraction failure is recorded; launch remains unavailable |
| `xprop` | X11/XWayland PID, title, and WM_CLASS probes | The L2 probe group is `SKIP` |
| `dbus-send` from `dbus-1-tools` | Optional PID-owned StatusNotifierItem probe | Tray probe is `SKIP` |
| `setsid` | External-harness process-group cleanup | External L2 launch can `FAIL`; install it before running |
| `xvfb-run`, `dbus-run-session`, `setsid` | Artifact-validator launch smoke | Artifact smoke is `SKIP` |

openSUSE/SLEでは不足するツールを`zypper`で導入してください。`xprop`はX11/XWaylandセッションでのみ使えます。`DISPLAY`がなく`WAYLAND_DISPLAY`だけがあるnative Waylandでは、window queryをサポート済みとはせず、launcher process、launcher log、window、trayを含むL2 probe group全体を明示的に`SKIP`にします。`xprop`がない場合も同じくL2 probe group全体がSKIPになります。

`SKIP`は環境または任意probeの制約を正しく記録した結果であり、`PASS`ではありません。external harnessは1件以上の`FAIL`があれば終了コード1、FAILなしでSKIPがあれば終了コード77、全probeがPASSなら終了コード0です。`--help`は終了コード2です。artifact validatorはartifact不在時に`[SKIP]`を表示しますが、既存のvalidator契約により終了コード0です。

## JSONL evidence

結果は1行1recordのJSONLです。各recordには次のフィールドが必ずあります。

`schema_version`, `probe_id`, `probe`, `expected`, `actual`, `exit_code`, `status`, `skip_reason`, `log_path`, `timestamp`, `duration_ms`

`status`は`PASS`、`FAIL`、`SKIP`のいずれかです。`SKIP` recordには理由とprobe log pathが入り、`timestamp`はUTCの`Z`形式です。主なprobeはlauncher、desktop entry、`resources/app.asar`、`StartupWMClass`、launcher process、launcher log、X11/XWayland window title、任意のStatusNotifierItem、およびrun summaryです。

各probeの`expected`、`actual`、`exit_code`、`log_path`を結果から確認してください。実artifactがない場合はartifact validatorと同様に環境制限として記録し、起動成功とは報告しません。

## L2 boundary

外部harnessは通常のlauncherを起動し、公開ファイル、プロセス状態、X11/XWaylandの`xprop` window情報、任意のsession bus StatusNotifierItemだけを観測します。外部harnessはcallerの既存displayとsession busを使い、`xvfb-run`や`dbus-run-session`を自動起動しません。`dbus-send`によるtray probeは任意で、WatcherまたはPID所有項目が確認できない場合はSKIPです。

外部harnessはPlaywright、inspector、CDP、DevTools、remote debugging、Electron内部API、internal L1 hooks、認証、状態seed、Electron monkey-patchingを使いません。native Waylandのwindow queryを成功扱いすることもありません。

launcher、desktop entry、`resources/app.asar`、ログ、window、trayのprobe結果と保持されたlog pathを保存してから、分離run rootをcleanupします。
