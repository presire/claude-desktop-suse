#!/usr/bin/env python3
"""
@file resolve-download-url.py
@brief Claude DesktopのWindows版インストーラの実際のダウンロードURLを解決する

claude.aiのリダイレクトURLはCloudflareで保護されており、
単純なHTTPリクエストでは最終的なダウンロードURLを取得できない
そのため、Playwrightのヘッドレスブラウザでリダイレクトを開き、
ブラウザが発生させた通信からダウンロードURLを取り出す
arm64のURLが取得できない場合は、amd64のURLを書き換えて推定し、
HEADリクエストで実在を確認する
結果はURL=...やVERSION=...の形式で標準出力に書き、進捗は標準エラー出力に書く

使い方 : resolve-download-url.py {amd64,arm64,all} [--timeout ミリ秒] [--format {url,version,both}]
終了コード : 0 = 全アーキテクチャのURLを解決できた、1 = いずれかの解決に失敗した、2 = 引数が不正
"""

import argparse
import re
import sys

import requests
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout


# アーキテクチャごとの、最新版インストーラへのリダイレクトURL
REDIRECT_URLS = {
    "amd64": "https://claude.ai/redirect/claudedotcom.v1.290130bf-1c36-4eb0-9a93-2410ca43ae53/api/desktop/win32/x64/exe/latest/redirect",
    "arm64": "https://claude.ai/redirect/claudedotcom.v1.290130bf-1c36-4eb0-9a93-2410ca43ae53/api/desktop/win32/arm64/exe/latest/redirect",
}

# ヘッドレスブラウザと判定されて拒否されないよう、
# 通常のLinux版Chromeとして名乗るためのUser-Agent
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36"


def resolve_download_url(arch: str, timeout: int = 30000) -> str | None:
    """
    @brief 指定したアーキテクチャのリダイレクトURLを開き、最終的なダウンロードURLを取得する

    Args:
        arch: 解決するアーキテクチャ ("amd64"または"arm64")
        timeout: ページ遷移のタイムアウト(ミリ秒)

    Returns:
        取得したダウンロードURL、取得できなかった場合はNone

    Note:
        ダウンロードの開始やタイムアウトは正常な経過として扱い、
        それまでに捕捉したURLを返す
    """
    if arch not in REDIRECT_URLS:
        print(f"Error: Unknown architecture '{arch}'", file=sys.stderr)
        return None

    redirect_url = REDIRECT_URLS[arch]
    resolved_url = None

    def handle_request(request):
        """
        @brief ブラウザが送信したリクエストのうち、インストーラ本体のURLを記録する

        Args:
            request: Playwrightのリクエストオブジェクト
        """
        nonlocal resolved_url
        url = request.url
        # 旧形式の配布先では、リダイレクトの最終到達先が
        # Google Cloud Storage上の.exeになる
        if "storage.googleapis.com" in url and url.endswith(".exe"):
            resolved_url = url

    def handle_download(download):
        """
        @brief ブラウザがダウンロードを開始した時点で、そのURLを記録する

        Args:
            download: Playwrightのダウンロードオブジェクト
        """
        nonlocal resolved_url
        resolved_url = download.url

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1920, "height": 1080},
            accept_downloads=True,
        )

        # 自動操作中のブラウザであることを示すプロパティを隠し、
        # 通常のブラウザと同じ値に見せる
        context.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64' });
            Object.defineProperty(navigator, 'vendor', { get: () => 'Google Inc.' });
        """)

        page = context.new_page()
        page.on("request", handle_request)
        page.on("download", handle_download)

        try:
            # リダイレクトURLを開くとダウンロードが始まるため、
            # 通信が始まった時点で遷移完了とみなす
            page.goto(redirect_url, timeout=timeout, wait_until="commit")
            # ダウンロードURLを捕捉するイベントが発生するまで少し待つ
            page.wait_for_timeout(2000)
        except PlaywrightTimeout:
            # 必要なのはリダイレクト先のURLだけなので、
            # ページの読み込みがタイムアウトしても問題ない
            pass
        except Exception as e:
            # ダウンロードの開始時に発生する"Download is starting"の例外は、
            # URLを捕捉できたことを意味する
            if "Download is starting" not in str(e):
                print(f"Error navigating to {redirect_url}: {e}", file=sys.stderr)
        finally:
            browser.close()

    return resolved_url


def extract_version_from_url(url: str) -> str | None:
    """
    @brief ダウンロードURLのパスに含まれるバージョン番号を取り出す

    Args:
        url: ダウンロードURL (例 : https://downloads.claude.ai/releases/win32/x64/1.0.1234/Claude-xxx.exe)

    Returns:
        "1.0.1234"のような3つの数字からなるバージョン、見つからない場合はNone
    """
    match = re.search(r"/(\d+\.\d+\.\d+)/", url)
    if match:
        return match.group(1)
    return None


def verify_url_exists(url: str, timeout: int = 10) -> bool:
    """
    @brief HEADリクエストを送り、URLが実在するかを確認する

    Args:
        url: 確認するURL
        timeout: リクエストのタイムアウト(秒)

    Returns:
        リダイレクトを辿った結果のステータスコードが200の場合はTrue、
        それ以外のステータスや通信エラーの場合はFalse
    """
    try:
        response = requests.head(url, timeout=timeout, allow_redirects=True)
        return response.status_code == 200
    except requests.RequestException:
        return False


def derive_arm64_url_from_amd64(amd64_url: str) -> str | None:
    """
    @brief amd64のダウンロードURLの文字列を置換して、arm64のURLを推定する

    リダイレクト経由でarm64のURLを取得できなかった場合の代替手段として使う
    配布先には次の新旧2つの形式があり、両方に対応する
      旧形式 : https://storage.googleapis.com/.../nest-win-x64/Claude-Setup-x64.exe
      新形式 : https://downloads.claude.ai/releases/win32/x64/1.0.xxx/Claude-xxx.exe

    Args:
        amd64_url: 解決済みのamd64のダウンロードURL

    Returns:
        推定したarm64のURL、置換できる箇所がなかった場合はNone

    Note:
        推定したURLが実在するとは限らないため、
        呼び出し側でverify_url_exists()を使って確認する
    """
    if not amd64_url:
        return None

    arm64_url = amd64_url

    # 新形式 : downloads.claude.ai/releases/win32/x64/を/win32/arm64/に置き換える
    arm64_url = arm64_url.replace("/win32/x64/", "/win32/arm64/")

    # 旧形式 : storage.googleapis.com上の、ディレクトリ名とファイル名に含まれるx64を置き換える
    arm64_url = arm64_url.replace("nest-win-x64", "nest-win-arm64")
    arm64_url = arm64_url.replace("Claude-Setup-x64.exe", "Claude-Setup-arm64.exe")
    arm64_url = arm64_url.replace("-x64.exe", "-arm64.exe")

    # どの形式にも一致せずURLが変わらなかった場合は、推定できなかったものとして扱う
    if arm64_url != amd64_url:
        return arm64_url
    return None


def main():
    """
    @brief コマンドライン引数で指定されたアーキテクチャのURLを解決し、結果を出力する

    Note:
        いずれかのアーキテクチャの解決に失敗した場合は、終了コード1で終了する
    """
    parser = argparse.ArgumentParser(
        description="Resolve Claude Desktop download URLs"
    )
    parser.add_argument(
        "arch",
        choices=["amd64", "arm64", "all"],
        help="Architecture to resolve (amd64, arm64, or all)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30000,
        help="Timeout in milliseconds (default: 30000)",
    )
    parser.add_argument(
        "--format",
        choices=["url", "version", "both"],
        default="url",
        help="Output format (default: url)",
    )

    args = parser.parse_args()

    architectures = ["amd64", "arm64"] if args.arch == "all" else [args.arch]

    results = {}
    for arch in architectures:
        print(f"Resolving {arch} download URL...", file=sys.stderr)
        url = resolve_download_url(arch, args.timeout)

        if url:
            version = extract_version_from_url(url)
            results[arch] = {"url": url, "version": version, "derived": False}
            print(f"  Resolved: {url}", file=sys.stderr)
            if version:
                print(f"  Version: {version}", file=sys.stderr)
        else:
            print(f"  Failed to resolve {arch} URL via redirect", file=sys.stderr)
            results[arch] = None

    # arm64はリダイレクトでの解決に失敗することがあるため、
    # amd64が成功していればそのURLから推定する
    if args.arch == "all" and results.get("arm64") is None and results.get("amd64"):
        print("Attempting to derive ARM64 URL from AMD64 URL...", file=sys.stderr)
        derived_url = derive_arm64_url_from_amd64(results["amd64"]["url"])
        if derived_url:
            print(f"  Derived URL: {derived_url}", file=sys.stderr)
            print("  Verifying URL exists...", file=sys.stderr)
            if verify_url_exists(derived_url):
                version = extract_version_from_url(derived_url)
                results["arm64"] = {"url": derived_url, "version": version, "derived": True}
                print(f"  ✓ Verified ARM64 URL exists", file=sys.stderr)
            else:
                print("  ✗ Derived URL does not exist (404)", file=sys.stderr)
        else:
            print("  Could not derive ARM64 URL pattern", file=sys.stderr)

    # 複数のアーキテクチャを解決した場合は、呼び出し側で区別できるよう、
    # AMD64_URL=のようにアーキテクチャ名の接頭辞を付ける
    for arch, result in results.items():
        if result is None:
            continue

        prefix = f"{arch.upper()}_" if len(architectures) > 1 else ""

        if args.format == "url":
            print(f"{prefix}URL={result['url']}")
        elif args.format == "version":
            if result["version"]:
                print(f"{prefix}VERSION={result['version']}")
        elif args.format == "both":
            print(f"{prefix}URL={result['url']}")
            if result["version"]:
                print(f"{prefix}VERSION={result['version']}")

    # 1つでも解決できなかったアーキテクチャがあれば、
    # 呼び出し側が処理を止められるよう失敗として終了する
    if any(r is None for r in results.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
