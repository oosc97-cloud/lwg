#!/bin/bash
# 에이전트 대상 서버용 설치 파일 생성 (개발 PC/테스트 서버에서 실행)
#   ./build-installer.sh                   → dist/fs-agent-install-<버전>.sh   (단독 실행용, 포트 15891)
#   ./build-installer.sh --release         → 위 파일 + release/fs-agent-install.sh (저장소에 커밋해 배포 경로에 내려보냄)
#   ./build-installer.sh --master-edition  → dist/fs-agent-m-install-<버전>.sh (마스터 연동용: 서비스 fs-agent-m,
#                                            /opt/fs-agent-m, 포트 15892, 설치 시 --master <마스터IP> 필수)
#                                            --release 를 함께 주면 release/fs-agent-m-install.sh
# 설치 파일 하나에 프로그램 번들(tar.gz)이 들어 있어 git·인터넷 없이 설치된다.
# 번들에는 실행에 필요한 파일만 넣는다 (개발용 문서·배포/재기동 스크립트 제외).
set -e
cd "$(dirname "$0")"
RELEASE=0
EDITION=standalone
for a in "$@"; do
  case "$a" in
    --release) RELEASE=1 ;;
    --master-edition) EDITION=master ;;
    *) echo "알 수 없는 옵션: $a"; exit 1 ;;
  esac
done
if [ "$EDITION" = master ]; then
  NAME=fs-agent-m; PORT=15892; NOTE="마스터 연동용: 처음 설치할 때 필수"
else
  NAME=fs-agent; PORT=15891; NOTE="생략하면 단독 실행"
fi
VERSION="$(date +%Y%m%d)-$(git rev-parse --short HEAD 2>/dev/null || echo local)"
[ -z "$(git status --porcelain 2>/dev/null)" ] || VERSION="$VERSION-dirty"
OUT="dist/$NAME-install-$VERSION.sh"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/fs-agent" dist
cp -a server.py config.json README.md MANUAL.md "$STAGE/fs-agent/"
mkdir -p "$STAGE/fs-agent/app"
( cd app && find . -name '__pycache__' -prune -o -type f ! -name '*.pyc' -print | while read -r f; do
    mkdir -p "$STAGE/fs-agent/app/$(dirname "$f")"; cp -a "$f" "$STAGE/fs-agent/app/$f"; done )
echo "$VERSION" > "$STAGE/fs-agent/VERSION"
# 마스터 연동판은 기본 포트가 다르고 웹 화면을 끔 (화면은 마스터에서만)
[ "$EDITION" = master ] && sed -i "s/\"port\": 15891,/\"port\": $PORT,\n  \"web_ui\": false,/" "$STAGE/fs-agent/config.json"

sed -e "s/@VERSION@/$VERSION/" -e "s/@SERVICE@/$NAME/" -e "s#@PREFIX@#/opt/$NAME#g" -e "s/@PORT@/$PORT/g" \
    -e "s/@EDITION@/$EDITION/" -e "s/@INSTALLER@/$NAME-install.sh/g" -e "s/@MASTER_NOTE@/$NOTE/" \
    installer/install-header.sh > "$OUT"
tar -C "$STAGE/fs-agent" --owner=0 --group=0 -czf - . >> "$OUT"
chmod +x "$OUT"
echo "생성: $OUT ($(du -h "$OUT" | cut -f1))"
if [ "$RELEASE" = 1 ]; then
  mkdir -p release
  cp "$OUT" "release/$NAME-install.sh"
  if [ "$EDITION" = master ]; then echo "$VERSION" > release/AGENT_M_VERSION; else echo "$VERSION" > release/VERSION; fi
  echo "복사: release/$NAME-install.sh (버전 $VERSION)"
fi
