#
# @file detect-host.sh
# @brief ホストのアーキテクチャ・ディストリビューションの判定と、コマンドライン引数の解釈を行う
#
# SUSE向けビルドで使う値をここで確定する
# 対象アーキテクチャ、配布系列、作業ディレクトリ、ビルド形式、
# クリーンアップ方針、取得するClaudeの版と検証用ハッシュを決める
#
# 読み込み元 : build.sh
# 参照するグローバル変数 : なし (読み込み時点では何も参照しない)
# 変更するグローバル変数 : architecture, distro_family, original_user,
#   original_home, project_root, work_dir, app_staging_dir, build_format,
#   cleanup_action, perform_cleanup, test_flags_mode, local_exe_path,
#   release_tag, source_dir, node_pty_dir, install_prefix, override_arch,
#   dark_tray_icons, claude_version_override, claude_sha256_override,
#   claude_nupkg_url, claude_nupkg_filename, claude_nupkg_sha1,
#   claude_nupkg_sha256
#

# パッチスクリプトを検証済みのClaudeリリース (D-005)
# --claude-versionを付けないビルドはこのnupkgだけを取得し、
# アーキテクチャ別のSHA-256を照合する
# これにより、最新リリースしか載らないRELEASESからこの版が消えた後も
# 入力の検証を保てる
# 更新は3つを同時に行い、新しいバンドルへ全てのパッチが
# 問題なく適用できてから行う
CLAUDE_PINNED_VERSION='4.23118.0'                                        # 検証済みのClaudeリリース
CLAUDE_PINNED_SHA256_AMD64='f26ce9fc2132d9aeaf82867dc6c23e963280ed7cdefdcd15f57fdfc673036ddd'  # amd64向けnupkgのSHA-256
CLAUDE_PINNED_SHA256_ARM64='a5ec6c080f98671526d5dd8c99d28df3e11b027a9c305929ea4f328297cd7223'  # arm64向けnupkgのSHA-256

#
# @brief --archの指定を優先してパッケージの対象アーキテクチャを決める
# @global override_arch (参照のみ) --archで指定された値
# @global architecture 対象アーキテクチャ (amd64またはarm64) を設定する
# @note 対応していないアーキテクチャではexit 1で中断する
#
detect_architecture() {
	section_header 'Architecture Detection'
	echo 'Detecting system architecture...'

	local raw_arch
	if [[ -n ${override_arch:-} ]]; then
		echo "Architecture override via --arch: $override_arch"
		raw_arch="$override_arch"
	else
		raw_arch=$(uname -m) || {
			echo 'Failed to detect architecture' >&2
			exit 1
		}
		echo "Detected machine architecture: $raw_arch"
	fi

	case "$raw_arch" in
		x86_64|amd64)
			architecture='amd64'
			echo 'Configured for amd64 (x86_64) build.'
			;;
		aarch64|arm64)
			architecture='arm64'
			echo 'Configured for arm64 (aarch64) build.'
			;;
		*)
			echo "Unsupported architecture: $raw_arch. This script supports x86_64 (amd64) and aarch64 (arm64)." >&2
			exit 1
			;;
	esac

	echo "Target Architecture: $architecture"
	section_footer 'Architecture Detection'
}

#
# @brief SUSE系のディストリビューションかを判定する
# @global build_format (参照のみ) 非SUSEでrpmを組み立てる場合の警告に使う
# @global distro_family suseまたはunknownを設定する
#
detect_distro() {
	section_header 'Distribution Detection'
	echo 'Detecting Linux distribution family...'

	# openSUSEはSUSE-brand、旧SLEはSuSE-releaseを持ち、
	# どちらも無い環境はos-releaseの記述で判定する
	if [[ -f /etc/SUSE-brand || -f /etc/SuSE-release ]]; then
		distro_family='suse'
		echo "Detected SUSE-based distribution"
	elif grep -qi 'suse\|opensuse' /etc/os-release 2>/dev/null; then
		distro_family='suse'
		echo "Detected SUSE-based distribution (via os-release)"
	else
		distro_family='unknown'
		echo "Warning: Could not detect SUSE distribution"
		echo "  RPM build may not work correctly on unsupported distributions"
	fi

	# 引数の解釈はこの関数より先に済んでいるため、ここではbuild_formatが確定している
	if [[ $build_format == 'rpm' && $distro_family != 'suse' ]]; then
		echo "Warning: Building .rpm package on non-SUSE system ($distro_family). This may fail." >&2
	fi

	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	section_footer 'Distribution Detection'
}

#
# @brief 実行ユーザーとホームディレクトリを確認し、NVMのNode.jsをPATHへ足す
# @global original_user 実行ユーザー名 (本関数で設定する)
# @global original_home 実行ユーザーのホームディレクトリ (本関数で設定する)
# @global PATH NVMで導入したNode.jsのbinを先頭に足してexportする
# @note rootでの実行はCIやコンテナと判定できる場合だけ許し、
#       それ以外はexit 1で中断する
#
check_system_requirements() {
	# CIやコンテナではrootでのビルドを許す
	if (( EUID == 0 )); then
		if [[ -n ${CI:-} || -n ${GITHUB_ACTIONS:-} || -f /.dockerenv ]]; then
			echo 'Running as root in CI/container environment (allowed)'
		else
			echo 'This script should not be run using sudo or as the root user.' >&2
			echo 'It will prompt for sudo password when needed for specific actions.' >&2
			echo 'Please run as a normal user.' >&2
			exit 1
		fi
	fi

	original_user=$(whoami)
	original_home=$(getent passwd "$original_user" | cut -d: -f6)
	if [[ -z $original_home ]]; then
		echo "Could not determine home directory for user $original_user." >&2
		exit 1
	fi
	echo "Running as user: $original_user (Home: $original_home)"

	# NVMで導入したNode.jsがあれば読み込み、システムのNode.jsより優先する
	if [[ -d $original_home/.nvm ]]; then
		echo "Found NVM installation for user $original_user, checking for Node.js 20+..."
		export NVM_DIR="$original_home/.nvm"
		if [[ -s $NVM_DIR/nvm.sh ]]; then
			# shellcheck disable=SC1091
			\. "$NVM_DIR/nvm.sh"
			local node_bin_path=''
			node_bin_path=$(nvm which current | xargs dirname 2>/dev/null || \
				find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' | sort -V | tail -n 1)

			if [[ -n $node_bin_path && -d $node_bin_path ]]; then
				echo "Adding NVM Node bin path to PATH: $node_bin_path"
				export PATH="$node_bin_path:$PATH"
			else
				echo 'Warning: Could not determine NVM Node bin path.'
			fi
		else
			echo 'Warning: nvm.sh script not found or not sourceable.'
		fi
	fi

	echo 'System Information:'
	echo "Distribution: $(grep 'PRETTY_NAME' /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo 'Unknown')"
	echo "Distribution family: $distro_family"
	echo "Target Architecture: $architecture"
}

#
# @brief コマンドライン引数を解釈し、ビルド設定を各グローバル変数へ反映する
# @global project_root カレントディレクトリを設定する
# @global work_dir ビルドの作業ディレクトリを設定する
# @global app_staging_dir Electronアプリのステージング先を設定する
# @global build_format rpmまたはappimageを設定する
# @global cleanup_action 中間ファイルを消すか (yes/no) を設定する
# @global dark_tray_icons トレイアイコンを暗色版に差し替えるかを設定する
# @global test_flags_mode 引数の解釈だけで終了するかを設定する
# @global perform_cleanup cleanup_actionがyesならtrueを設定する
# @global local_exe_path, release_tag, install_prefix, source_dir,
#   node_pty_dir, override_arch, claude_version_override,
#   claude_sha256_override 指定された値を設定する
# @note 値の不足、不正な値、未知のオプションではexit 1で中断する
#
parse_arguments() {
	section_header 'Argument Parsing'

	project_root="$(pwd)"
	work_dir="$project_root/build"
	app_staging_dir="$work_dir/electron-app"

	build_format='rpm'
	dark_tray_icons=false

	while (( $# > 0 )); do
		case "$1" in
			-b|--build|-c|--clean|-e|--exe|-r|--release-tag|-p|--prefix|-s|--source-dir|--node-pty-dir|-a|--arch|--claude-version|--claude-sha256)
				# 値を取るオプションは、次の引数が無いか別のオプションなら
				# 値を取り違えたまま進まないよう即座に止める
				if [[ -z ${2:-} || $2 == -* ]]; then
					echo "Error: Argument for $1 is missing" >&2
					exit 1
				fi
				case "$1" in
					-b|--build) build_format="$2" ;;
					-c|--clean) cleanup_action="$2" ;;
					-e|--exe) local_exe_path="$2" ;;
					-r|--release-tag) release_tag="$2" ;;
					-p|--prefix) install_prefix="$2" ;;
					-s|--source-dir) source_dir="$2" ;;
					--node-pty-dir) node_pty_dir="$2" ;;
					-a|--arch) override_arch="$2" ;;
					--claude-version) claude_version_override="$2" ;;
					--claude-sha256) claude_sha256_override="$2" ;;
				esac
				shift 2
				;;
			--dark)
				dark_tray_icons=true
				shift
				;;
			--test-flags)
				test_flags_mode=true
				shift
				;;
		-h|--help)
			echo "Usage: $0 [options]"
			echo ''
			echo 'Build options:'
			echo '  --build rpm|appimage'
			echo '      Package format to build.'
			echo '      Default: rpm'
			echo ''
			echo '  --clean yes|no'
			echo '      Remove intermediate build files after packaging.'
			echo '      Default: yes'
			echo ''
			echo '  --exe /path/to/installer.exe'
			echo '      Use a local Claude installer instead of downloading it.'
			echo ''
			echo '  --claude-version X.Y.Z|latest'
			echo '      Claude release to download.'
			echo "      Default: $CLAUDE_PINNED_VERSION (the release the patch scripts"
			echo '      are verified against; its SHA-256 is pinned per arch).'
			echo '      latest: the newest release listed in RELEASES (SHA-1'
			echo '      verified, patches may not apply).'
			echo '      Other versions are verified only with --claude-sha256 or'
			echo '      while RELEASES still lists them.'
			echo ''
			echo '  --claude-sha256 HASH'
			echo '      Expected SHA-256 of the Claude nupkg; replaces the pinned'
			echo '      hash. Verifies --exe and --claude-version downloads.'
			echo '      The build aborts on mismatch.'
			echo ''
			echo '  --arch amd64|arm64'
			echo '      Override the target architecture for cross-building.'
			echo '      Default: host architecture (x86_64 -> amd64, aarch64 -> arm64)'
			echo ''
			echo '  --prefix /path'
			echo '      Installation prefix for packaged files.'
			echo '      Default: /usr/lib'
			echo '      Installs to: <prefix>/claude-desktop'
			echo ''
			echo '  --source-dir /path'
			echo '      Repository root containing scripts/ and assets/.'
			echo '      Default: current working directory'
			echo ''
			echo '  --node-pty-dir /path'
			echo '      Use a pre-built node-pty package and skip npm install.'
			echo ''
			echo '  --release-tag TAG'
			echo '      Append a wrapper version suffix to the package version.'
			echo '      Example: v1.3.2+claude1.1.799'
			echo ''
			echo '  --dark'
			echo '      Replace default tray icons with dark-mode variants.'
			echo ''
			echo '  --test-flags'
			echo '      Parse flags, print the resolved configuration, and exit.'
			echo ''
			echo '  -h, --help'
			echo '      Show this help text.'
			exit 0
			;;
			*)
				echo "Unknown option: $1" >&2
				echo 'Use -h or --help for usage information.' >&2
				exit 1
				;;
		esac
	done

	# source_dirはscriptsとassetsの置き場所で、既定はプロジェクトルート
	source_dir="${source_dir:-$project_root}"

	# 値の意味を揃えるため、比較の前に小文字へ正規化する
	build_format="${build_format,,}"
	cleanup_action="${cleanup_action,,}"

	if [[ ! -d $source_dir ]]; then
		echo "Error: --source-dir path does not exist: $source_dir" >&2
		exit 1
	fi
	if [[ -n $node_pty_dir && ! -d $node_pty_dir ]]; then
		echo "Error: --node-pty-dir path does not exist: $node_pty_dir" >&2
		exit 1
	fi
	if [[ -n $claude_version_override && $claude_version_override != 'latest' \
		&& ! $claude_version_override =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "Error: --claude-version must be a version like $CLAUDE_PINNED_VERSION or 'latest' (got: '$claude_version_override')" >&2
		exit 1
	fi
	if [[ -n $claude_sha256_override && ! $claude_sha256_override =~ ^[0-9a-fA-F]{64}$ ]]; then
		echo "Error: --claude-sha256 must be a 64-character hex SHA-256 (got: '$claude_sha256_override')" >&2
		exit 1
	fi

	if [[ $build_format != 'rpm' && $build_format != 'appimage' ]]; then
		echo "Invalid build format specified: '$build_format'. Must be 'rpm' or 'appimage'." >&2
		exit 1
	fi

	if [[ $cleanup_action != 'yes' && $cleanup_action != 'no' ]]; then
		echo "Invalid cleanup option specified: '$cleanup_action'. Must be 'yes' or 'no'." >&2
		exit 1
	fi

	echo "Selected build format: $build_format"
	echo "Cleanup intermediate files: $cleanup_action"
	echo "Install prefix: $install_prefix"

	[[ $cleanup_action == 'yes' ]] && perform_cleanup=true

	section_footer 'Argument Parsing'
}

#
# @brief 取得するClaudeのnupkg名、URL、検証用ハッシュを決める
# @global local_exe_path (参照のみ) 指定時はURL解決を行わない
# @global architecture (参照のみ) ダウンロード先のパスと既定ハッシュを選ぶ
# @global claude_version_override (参照のみ) 版の指定 (latestまたはx.y.z)
# @global claude_sha256_override (参照のみ) 指定時はピン留めのハッシュより優先する
# @global claude_nupkg_filename, claude_nupkg_url, claude_nupkg_sha1,
#   claude_nupkg_sha256 取得対象と検証用ハッシュを設定する
# @return 0 = URLを確定できた
# @note latest指定でRELEASESからnupkgを特定できない場合などはexit 1で中断する
#
resolve_latest_url() {
	# ローカルのインストーラを使う場合はURLを解決しない
	if [[ -n $local_exe_path ]]; then
		claude_nupkg_sha256="$claude_sha256_override"
		echo 'URL resolution skipped: using local installer (--exe)'
		return 0
	fi

	section_header 'URL Resolution'

	# Electron配布物のフィードで使うアーキテクチャ名へ変換する
	local arch_path
	case "$architecture" in
		amd64) arch_path='x64' ;;
		arm64) arch_path='arm64' ;;
	esac

	local releases_url="https://downloads.claude.ai/releases/win32/${arch_path}/RELEASES"

	local target_version="${claude_version_override:-$CLAUDE_PINNED_VERSION}"
	[[ $target_version == 'latest' ]] && target_version=''

	claude_nupkg_sha256="$claude_sha256_override"
	# ピン留めしたリリースだけは、アーキテクチャ別の既定ハッシュで検証する
	if [[ -z $claude_nupkg_sha256 && $target_version == "$CLAUDE_PINNED_VERSION" ]]; then
		case "$architecture" in
			amd64) claude_nupkg_sha256="$CLAUDE_PINNED_SHA256_AMD64" ;;
			arm64) claude_nupkg_sha256="$CLAUDE_PINNED_SHA256_ARM64" ;;
		esac
	fi

	# RELEASESはどちらのモードでも取得する
	# latestでは取得するnupkg名を決めるために使い、
	# どちらの場合も対象ファイルのSHA-1が載っていることがある
	# 版を固定している場合はRELEASES無しでもURLを組み立てられるため、
	# 取得に失敗しても警告だけで続行する
	local releases_content=''
	if ! releases_content=$(wget -qO- "$releases_url" 2>&1); then
		if [[ -z $target_version ]]; then
			echo "Error: Failed to fetch RELEASES file from $releases_url" >&2
			exit 1
		fi
		echo "Warning: Could not fetch RELEASES from $releases_url;" \
			'continuing without its SHA-1.' >&2
		releases_content=''
	fi

	if [[ -n $target_version ]]; then
		# 版を固定している場合はnupkg名をそのまま組み立てる
		# arm64のフィードも同じ"-full"名を自身のパスで配信しており、
		# "-arm64-full"名は404になる (1.44121.4から3.6556.1で確認)
		claude_nupkg_filename="AnthropicClaude-${target_version}-full.nupkg"
		if [[ -n $claude_version_override ]]; then
			echo "Using pinned Claude version: $target_version"
		else
			echo "Using verified Claude version: $target_version" \
				'(default; override with --claude-version)'
		fi
	else
		# latest指定ではRELEASESにある最新のfull nupkgの項目を使う
		echo "Fetching latest version from $releases_url..."
		local latest_nupkg
		latest_nupkg=$(echo "$releases_content" | grep -oP 'AnthropicClaude-[0-9.]+-full\.nupkg' | tail -1)
		if [[ -z $latest_nupkg ]]; then
			# arm64向けの名前で書かれている場合に備えて別のパターンでも探す
			latest_nupkg=$(echo "$releases_content" | grep -oP 'AnthropicClaude-[0-9.]+-arm64-full\.nupkg' | tail -1)
		fi
		if [[ -z $latest_nupkg ]]; then
			echo 'Error: Could not find latest nupkg in RELEASES file' >&2
			exit 1
		fi
		claude_nupkg_filename="$latest_nupkg"
	fi

	claude_nupkg_url="https://downloads.claude.ai/releases/win32/${arch_path}/${claude_nupkg_filename}"

	# RELEASESの各行は"SHA1 filename size"の形なので先頭列を使う
	# latestでは必ず載っており、固定した版ではRELEASESに残っている場合だけ載る
	claude_nupkg_sha1=$(echo "$releases_content" \
		| grep -F "$claude_nupkg_filename" \
		| awk '{print $1}' | tail -1) || true

	echo "Nupkg: $claude_nupkg_filename"
	echo "Download URL: $claude_nupkg_url"
	[[ -n $claude_nupkg_sha1 ]] && echo "Expected SHA-1: $claude_nupkg_sha1"
	[[ -n $claude_nupkg_sha256 ]] && echo "Expected SHA-256: $claude_nupkg_sha256"
	if [[ -z $claude_nupkg_sha1 && -z $claude_nupkg_sha256 ]]; then
		echo "Warning: no SHA-1 in RELEASES and no --claude-sha256 for" \
			"$claude_nupkg_filename; download will not be checksum-verified." >&2
	fi

	section_footer 'URL Resolution'
}
