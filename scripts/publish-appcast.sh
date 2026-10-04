#!/bin/bash
# 把本地 appcast.xml 通过 GitHub Contents API 提交到 main 分支（CI 发版专用）。
# 乐观锁：PUT 携带远端 sha，409（并发修改）时重读 sha 重试；成功后读回校验。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

REPO="wudanyang6/appwindow"
REMOTE_PATH="appcast.xml"
BRANCH="main"
MAX_ATTEMPTS=3
RETRY_SLEEP=2
READBACK_ATTEMPTS="${APPCAST_READBACK_ATTEMPTS:-24}"
READBACK_SLEEP="${APPCAST_READBACK_SLEEP:-10}"

VERSION="${VERSION:-}"
BUILD="${BUILD:-}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT/appcast.xml}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --build) BUILD="$2"; shift 2 ;;
        --appcast) APPCAST_PATH="$2"; shift 2 ;;
        *) echo "错误：未知参数 $1" >&2; exit 1 ;;
    esac
done

[[ -n "$VERSION" ]] || { echo "错误：缺少版本号（--version 或 VERSION 环境变量）" >&2; exit 1; }
[[ "$BUILD" =~ ^[0-9]+$ ]] || { echo "错误：缺少 build 号（--build 或 BUILD 环境变量，纯数字）" >&2; exit 1; }
[[ -f "$APPCAST_PATH" ]] || { echo "错误：appcast 文件不存在：$APPCAST_PATH" >&2; exit 1; }
if command -v xmllint >/dev/null; then
    xmllint --noout "$APPCAST_PATH"
fi

# 读取远端 appcast 的 sha 与最大 build（同一次调用取，保证两者来自同一版本）。
# 输出两行：sha / 最大 build（没有 <sparkle:version> 时输出 0）。
fetch_remote() {
    gh api "repos/$REPO/contents/$REMOTE_PATH?ref=$BRANCH" \
        | ruby -rjson -rbase64 -e '
            data = JSON.parse(STDIN.read)
            content = Base64.decode64(data["content"].to_s)
            max_build = content.scan(%r{<sparkle:version>\s*(\d+)\s*</sparkle:version>}).flatten.map(&:to_i).max || 0
            puts data["sha"]
            puts max_build
        '
}

# 用本地文件内容 + 乐观锁 sha 提交一次，成功输出新 commit sha
publish_once() {
    local sha="$1"
    ruby -rjson -rbase64 -e '
        puts JSON.generate(
            message: ARGV[0],
            content: Base64.strict_encode64(File.binread(ARGV[1])),
            sha: ARGV[2],
            branch: ARGV[3]
        )
    ' "Update appcast for v$VERSION (build $BUILD)" "$APPCAST_PATH" "$sha" "$BRANCH" \
        | gh api --method PUT "repos/$REPO/contents/$REMOTE_PATH" \
            -H "Accept: application/vnd.github+json" \
            --input - \
            --jq '.commit.sha'
}

echo "提交 appcast（build ${BUILD}）到 ${REPO}@${BRANCH}…"
commit=""
for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    if ! remote_info="$(fetch_remote)"; then
        echo "错误：读取远端 appcast 失败（${REMOTE_PATH} 是否已存在于 ${BRANCH}？）" >&2
        exit 1
    fi
    remote_sha="${remote_info%%$'\n'*}"
    remote_max="${remote_info##*$'\n'}"

    # 远端已有更新的 build：说明本地是陈旧副本（例如重跑旧 tag），覆盖会抹掉新条目
    if ((remote_max > BUILD)); then
        echo "错误：远端 appcast 已包含更新的 build ${remote_max}（本次 ${BUILD}），拒绝覆盖" >&2
        exit 1
    fi

    # stderr 单独收集：ruby/gh 的警告不能混进 stdout 的 commit sha
    error_file="$(mktemp)"
    if output="$(publish_once "$remote_sha" 2>"$error_file")"; then
        rm -f "$error_file"
        commit="$output"
        break
    fi
    error_text="$(cat "$error_file")"
    rm -f "$error_file"
    if [[ "$error_text" != *"HTTP 409"* ]]; then
        echo "错误：提交 appcast 失败：${error_text}" >&2
        exit 1
    fi
    if ((attempt < MAX_ATTEMPTS)); then
        echo "appcast 被并发修改，重读 sha 后重试（第 $attempt/$MAX_ATTEMPTS 次）…" >&2
        sleep "$RETRY_SLEEP"
    fi
done

if [[ -z "$commit" ]]; then
    echo "错误：appcast 提交未获得 commit sha（sha 冲突重试耗尽或 gh 输出为空）" >&2
    exit 1
fi

# Contents 读路径有 CDN 滞后（实测可超过 30s），以 git 层为准：
# main 分支头 == PUT 返回的 commit 即成功；contents raw 含新 build 作第二判据
verified=false
for ((attempt = 1; attempt <= READBACK_ATTEMPTS; attempt++)); do
    branch_head="$(gh api "repos/$REPO/git/ref/heads/$BRANCH" --jq '.object.sha' 2>/dev/null || true)"
    if [[ "$branch_head" == "$commit" ]]; then
        verified=true
        break
    fi
    if gh api "repos/$REPO/contents/$REMOTE_PATH?ref=$BRANCH" \
        -H "Accept: application/vnd.github.raw" 2>/dev/null \
        | grep -Fq "<sparkle:version>$BUILD</sparkle:version>"; then
        verified=true
        break
    fi
    if ((attempt < READBACK_ATTEMPTS)); then
        echo "读回校验未确认（第 $attempt/$READBACK_ATTEMPTS 次），${READBACK_SLEEP}s 后重试…" >&2
        sleep "$READBACK_SLEEP"
    fi
done

if [[ "$verified" != true ]]; then
    echo "错误：appcast 已提交（${commit}）但读回校验失败" >&2
    exit 1
fi

echo "✓ appcast 已发布：v$VERSION (build $BUILD)，commit $commit"
