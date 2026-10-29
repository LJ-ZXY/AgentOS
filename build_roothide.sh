#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$ROOT_DIR"

if [ -d "$HOME/.local/share/theos-roothide" ]; then
    export THEOS="$HOME/.local/share/theos-roothide"
elif [ -d "/opt/theos-roothide" ]; then
    export THEOS="/opt/theos-roothide"
else
    export THEOS="${THEOS:-/opt/theos}"
fi

export THEOS_PACKAGE_SCHEME=roothide

echo "=================================================="
echo "  Building AgentOS for roothide (arm64/arm64e)..."
echo "  THEOS: $THEOS"
echo "=================================================="

if [ ! -d "$THEOS" ]; then
    echo "ERROR: Theos-roothide not found at $THEOS" >&2
    exit 1
fi

mkdir -p "$ROOT_DIR/packages"

if [[ "$ROOT_DIR" =~ [[:space:]] ]]; then
    STAGE_DIR="/tmp/theos_build_ios_deb"
    echo "⚠️ 检测到工程路径含空格，启用快速 staging 构建: $STAGE_DIR"
    mkdir -p "$STAGE_DIR"
    # clear staged packages so stale artifacts are never copied back
    find "$STAGE_DIR/packages" -maxdepth 1 -type f -name '*.deb' -delete 2>/dev/null || true
    
    rsync -a --delete \
        --exclude='.git' \
        --exclude='packages/*.deb' \
        "$ROOT_DIR/" "$STAGE_DIR/"
        
    (
        cd "$STAGE_DIR"
        make FINALPACKAGE=1 DEBUG=0 STRIP=1 THEOS_PACKAGE_SCHEME=roothide package
    )
    
    rsync -a "$STAGE_DIR/packages/" "$ROOT_DIR/packages/"
    if [ -d "$STAGE_DIR/.theos" ]; then
        rsync -a "$STAGE_DIR/.theos/" "$ROOT_DIR/.theos/"
    fi
else
    make FINALPACKAGE=1 DEBUG=0 STRIP=1 THEOS_PACKAGE_SCHEME=roothide package
fi

DEB=$(ls -t "$ROOT_DIR"/packages/*_iphoneos-arm64e.deb 2>/dev/null | head -n 1)
if [ -n "$DEB" ]; then
    echo ""
    echo "✅ 构建成功！安装包路径："
    echo "   $DEB"
    echo "📦 包体积: $(du -h "$DEB" | cut -f1)"
else
    echo "⚠️ 构建完成但未在 packages/ 找到 arm64e deb。"
fi
