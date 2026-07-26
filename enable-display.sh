#!/usr/bin/env bash
#==============================================================================
# 통화 중 전화기 화면에 안내가 뜨도록 내선 설정을 켭니다.
#
#   sudo ./enable-display.sh --all         모든 내선에 (권장)
#   sudo ./enable-display.sh 1001 1002     지정한 내선만
#   sudo ./enable-display.sh --show        지금 상태만 보기
#   sudo ./enable-display.sh --off         되돌리기
#
# 왜 필요한가
#   7000 으로 "전화를 걸었을 때" 화면이 안 바뀌는 이유는 두 가지입니다.
#
#   1) Asterisk 가 통화 중 이름을 보내려면 RPID 또는 PAI 헤더가 있어야 하는데
#      둘 다 기본값이 no 입니다.
#        asterisk -rx 'config show help res_pjsip endpoint send_rpid'
#          send_rpid = [Boolean] (Default: no)
#
#   2) CONNECTEDLINE(pres) 기본값이 'unavailable' 입니다. 그대로 두면
#      send_pai=yes 를 켜도 "표시할 수 없는 정보"로 보고 헤더를 안 만듭니다.
#      -> 이건 다이얼플랜(wk-lib,disp)에서 이미 allowed_not_screened 로
#         바꾸도록 넣어 두었습니다. 이 스크립트는 1) 만 담당합니다.
#
#   전화를 "받을 때"는 INVITE 의 CallerID 라 그냥 뜹니다.
#   그래서 한쪽만 되는 것처럼 보였습니다.
#
# 어디에 쓰는가
#   pjsip.endpoint.conf 는 FreePBX 가 Apply Config 할 때마다 다시 만듭니다.
#   거기 직접 쓰면 다음 Apply 에서 사라집니다.
#   endpoint_custom_post 파일은 FreePBX 가 #include 하고 건드리지 않습니다.
#
#   공통 설정은 템플릿 한 블록에 두고, 내선마다 한 줄만 붙입니다.
#     [wk-display](!)          <- 공통 블록. 여기만 고치면 전부 반영됩니다.
#     [1001](+,wk-display)     <- 내선은 이 한 줄
#
#   (+) = 이미 있는 섹션에 덧붙이기,  (!) = 템플릿.
#   두 개를 (+,템플릿) 으로 같이 쓸 수 있는지 실제로 확인했습니다:
#     base 파일 send_rpid=no  ->  결과 send_rpid true
#==============================================================================
set -uo pipefail

TPL="wk-display"
CUSTOM="/etc/asterisk/pjsip.endpoint_custom_post.conf"
GEN="/etc/asterisk/pjsip.endpoint.conf"

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[X] %s\033[0m\n' "$*" >&2; exit 1; }

MODE="list"
EXTS=()
for a in "$@"; do
  case "$a" in
    --all)  MODE="all" ;;
    --show) MODE="show" ;;
    --off)  MODE="off" ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
    *) EXTS+=("$a") ;;
  esac
done
[[ ${#EXTS[@]} -gt 0 || "$MODE" != "list" ]] \
  || die "사용법: sudo ./enable-display.sh --all | <내선...> | --show | --off"
[[ $EUID -eq 0 ]] || die "sudo 로 실행하세요"
command -v asterisk >/dev/null || die "Asterisk 가 없습니다"

#------------------------------------------------------------------------------
# 내선 목록 찾기
#   FreePBX 가 만든 pjsip.endpoint.conf 의 섹션 이름이 곧 내선 목록입니다.
#   숫자로만 된 것만 고릅니다. 트렁크(이름이 문자)에 켜면 발신자 이름이
#   통신사로 새어 나갈 수 있어 일부러 제외합니다.
#------------------------------------------------------------------------------
find_exts() {
  if [[ -f "$GEN" ]]; then
    sed -n 's/^\[\([0-9][0-9]*\)\].*/\1/p' "$GEN" | sort -un
  else
    asterisk -rx 'pjsip show endpoints' 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*m//g' \
      | sed -n 's/^ *Endpoint: *\([0-9][0-9]*\) .*/\1/p' | sort -un
  fi
}

show_state() {
  local n=0 e line
  while read -r e; do
    [[ -n "$e" ]] || continue
    line="$(asterisk -rx "pjsip show endpoint $e" 2>/dev/null \
            | sed 's/\x1b\[[0-9;]*m//g' \
            | awk -F: '/send_rpid|send_pai|trust_id_outbound/{
                gsub(/ /,"",$1); gsub(/^ +| +$/,"",$2); printf "%s=%s ",$1,$2}')"
    [[ -n "$line" ]] || continue
    if [[ "$line" == *"send_rpid=true"* || "$line" == *"send_pai=true"* ]]; then
      printf '  \033[1;32m[ON ]\033[0m %-8s %s\n' "$e" "$line"
    else
      printf '  \033[1;33m[OFF]\033[0m %-8s %s\n' "$e" "$line"
    fi
    n=$((n + 1))
  done < <(find_exts)
  (( n > 0 )) || warn "내선을 하나도 찾지 못했습니다"
}

#------------------------------------------------------------------------------
if [[ "$MODE" == "show" ]]; then
  log "현재 상태"
  show_state
  exit 0
fi

log "FreePBX 가 이 파일을 읽는지 확인"
if grep -qh "^#include .*$(basename "$CUSTOM")" /etc/asterisk/pjsip*.conf 2>/dev/null; then
  echo "  OK: $(basename "$CUSTOM") 이(가) include 되어 있습니다"
else
  warn "include 목록에서 $(basename "$CUSTOM") 을 못 찾았습니다."
  echo "   확인:  sudo grep -h '^#include' /etc/asterisk/pjsip*.conf"
  echo "   목록에 없으면 FreePBX 가 이 파일을 안 읽습니다."
fi

touch "$CUSTOM"
BK="${CUSTOM}.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$CUSTOM" "$BK"
echo "  백업: $BK"

#------------------------------------------------------------------------------
if [[ "$MODE" == "off" ]]; then
  log "되돌리기"
  CUSTOM="$CUSTOM" TPL="$TPL" python3 - <<'PY'
import os, re
from pathlib import Path
p, tpl = Path(os.environ["CUSTOM"]), os.environ["TPL"]
out, drop = [], False
for ln in p.read_text(encoding="utf-8").splitlines(keepends=True):
    if re.match(r"\s*\[" + re.escape(tpl) + r"\]\(!\)", ln):
        drop = True
        continue
    if drop and re.match(r"\s*\[", ln):
        drop = False
    if drop:
        continue
    if re.match(r"\s*\[[0-9]+\]\(\+," + re.escape(tpl) + r"\)", ln):
        continue
    if ln.strip().startswith("; 알람전화 화면 표시"):
        continue
    out.append(ln)
p.write_text("".join(out), encoding="utf-8")
print("  제거 완료")
PY
  fwconsole reload >/dev/null 2>&1 || asterisk -rx 'module reload res_pjsip.so' >/dev/null
  sleep 2
  log "확인"
  show_state
  exit 0
fi

#------------------------------------------------------------------------------
if [[ "$MODE" == "all" ]]; then
  mapfile -t EXTS < <(find_exts)
  [[ ${#EXTS[@]} -gt 0 ]] || die "내선 목록을 찾지 못했습니다. 번호를 직접 적어 주세요."
  log "대상 내선 ${#EXTS[@]}개: ${EXTS[*]}"
fi

# 공통 템플릿 블록은 한 번만 넣습니다
if ! grep -q "^\[${TPL}\](!)" "$CUSTOM"; then
  log "공통 블록 추가"
  cat >> "$CUSTOM" <<EOF

; 알람전화 화면 표시 — 공통 설정 (이 블록 하나만 고치면 전부 반영됩니다)
[${TPL}](!)
send_rpid=yes
send_pai=yes
trust_id_outbound=yes
send_connected_line=yes
connected_line_method=invite
; 전화기가 UPDATE 를 못 받으면 위 줄을 아래로 바꿔 보세요
;connected_line_method=update
EOF
  echo "  [${TPL}](!) 추가"
else
  echo "  공통 블록은 이미 있습니다"
fi

log "내선 연결"
added=0
for ext in "${EXTS[@]}"; do
  [[ "$ext" =~ ^[0-9]+$ ]] || { warn "숫자 내선이 아니라 건너뜁니다: $ext"; continue; }
  if grep -q "^\[${ext}\](+,${TPL})" "$CUSTOM"; then
    echo "  이미 있음: $ext"
    continue
  fi
  printf '[%s](+,%s)\n' "$ext" "$TPL" >> "$CUSTOM"
  echo "  추가: $ext"
  added=$((added + 1))
done
echo "  새로 추가 ${added}개"

log "반영"
fwconsole reload >/dev/null 2>&1 || asterisk -rx 'module reload res_pjsip.so' >/dev/null
sleep 2

log "확인"
show_state

cat <<EOF

===========================================================================
 전화기에서 7000 을 눌러 확인해 보세요.

 나중에 내선을 새로 만들면 한 번만 다시 돌리면 됩니다
   sudo $(basename "$0") --all

 상태만 보기 / 되돌리기
   sudo $(basename "$0") --show
   sudo $(basename "$0") --off

 실제로 SIP 에 나가는지까지 보려면
   sudo asterisk -rx 'pjsip set logger on'
   # 전화기로 7000 눌러 메뉴까지
   sudo asterisk -rx 'pjsip set logger off'
   sudo grep -iE '^(UPDATE|INVITE) sip:|P-Asserted-Identity|Remote-Party-ID' \\
        /var/log/asterisk/full | tail -20

 그래도 화면이 안 바뀌면 전화기가 통화 중 이름 갱신을 안 그리는 기종입니다.
 그때는 화면 기능만 끄면 됩니다 (음성 안내는 그대로):
   /etc/asterisk/extensions_custom.conf 의 [wk-lib] 안
     exten => disp,1,GotoIf(...)   ->   exten => disp,1,Return()
   sudo asterisk -rx 'dialplan reload'
===========================================================================
EOF
