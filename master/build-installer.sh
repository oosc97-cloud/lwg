#!/bin/bash
# 마스터 서버용 설치 파일 생성 (개발 PC/테스트 서버에서 실행)
#   master/build-installer.sh            → dist/fs-master-install-<버전>.sh
#   master/build-installer.sh --release  → 위 파일 + release/fs-master-install.sh (저장소에 커밋해 배포 경로에 내려보냄)
# 에이전트 설치 파일(build-installer.sh)과는 별개이며 서로 영향을 주지 않는다.
set -e
cd "$(dirname "$0")"
REPO="$(cd .. && pwd)"
VERSION="$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo local)"
[ -z "$(git status --porcelain -- . 2>/dev/null)" ] || VERSION="$VERSION-dirty"
OUT="$REPO/dist/fs-master-install-$VERSION.sh"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/fs-master/static" "$REPO/dist"
cp -a server.py master_db.py config.json README.md "$STAGE/fs-master/"
cp -a static/. "$STAGE/fs-master/static/"
cp -a ../app/static/index.html "$STAGE/fs-master/static/agent.html"   # 서버별 상세 화면 (에이전트 대시보드)
echo "$VERSION" > "$STAGE/fs-master/VERSION"

sed "s/@VERSION@/$VERSION/" installer/install-header.sh > "$OUT"
tar -C "$STAGE/fs-master" --owner=0 --group=0 -czf - . >> "$OUT"
chmod +x "$OUT"
echo "생성: $OUT ($(du -h "$OUT" | cut -f1))"
if [ "${1:-}" = "--release" ]; then
  mkdir -p "$REPO/release"
  cp "$OUT" "$REPO/release/fs-master-install.sh"
  echo "$VERSION" > "$REPO/release/MASTER_VERSION"
  echo "복사: release/fs-master-install.sh (버전 $VERSION)"
fi
