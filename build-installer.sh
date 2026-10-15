#!/bin/bash
# 에이전트 대상 서버용 설치 파일 생성 (개발 PC/테스트 서버에서 실행)
#   ./build-installer.sh            → dist/fs-agent-install-<버전>.sh
#   ./build-installer.sh --release  → 위 파일 + release/fs-agent-install.sh (저장소에 커밋해 배포 경로에 내려보냄)
# 설치 파일 하나에 프로그램 번들(tar.gz)이 들어 있어 git·인터넷 없이 설치된다.
# 번들에는 실행에 필요한 파일만 넣는다 (개발용 문서·배포/재기동 스크립트 제외).
set -e
cd "$(dirname "$0")"
VERSION="$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo local)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || VERSION="$VERSION-dirty"
OUT="dist/fs-agent-install-$VERSION.sh"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/fs-agent" dist
cp -a server.py config.json README.md MANUAL.md "$STAGE/fs-agent/"
mkdir -p "$STAGE/fs-agent/app"
( cd app && find . -name '__pycache__' -prune -o -type f ! -name '*.pyc' -print | while read -r f; do
    mkdir -p "$STAGE/fs-agent/app/$(dirname "$f")"; cp -a "$f" "$STAGE/fs-agent/app/$f"; done )
echo "$VERSION" > "$STAGE/fs-agent/VERSION"

sed "s/@VERSION@/$VERSION/" installer/install-header.sh > "$OUT"
tar -C "$STAGE/fs-agent" --owner=0 --group=0 -czf - . >> "$OUT"
chmod +x "$OUT"
echo "생성: $OUT ($(du -h "$OUT" | cut -f1))"
if [ "${1:-}" = "--release" ]; then
  mkdir -p release
  cp "$OUT" release/fs-agent-install.sh
  echo "$VERSION" > release/VERSION
  echo "복사: release/fs-agent-install.sh (버전 $VERSION)"
fi
