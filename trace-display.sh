#!/usr/bin/env bash
#==============================================================================
# 화면 표시가 SIP 로 실제 나가는지 잡아 봅니다.
#
#   sudo ./trace-display.sh 10.10.10.106
#   sudo ./trace-display.sh            (전화기 IP 를 자동으로 찾습니다)
#
# 하는 일
#   1. 전화기와 PBX 사이 SIP 를 30초 캡처합니다
#   2. 그 사이에 전화기로 7000 을 눌러 메뉴까지 들어가세요
#   3. UPDATE / re-INVITE 와 이름 헤더가 나갔는지 보여 줍니다
#
# 판정
#   - UPDATE 도 없고 이름 헤더도 없으면  -> Asterisk 쪽 문제 (설정/다이얼플랜)
#   - 이름 헤더는 나가는데 화면이 안 바뀌면 -> 전화기가 안 그리는 것
#     그때는 화면 기능을 끄는 게 낫습니다. 음성 안내는 그대로입니다.
#==============================================================================
set -uo pipefail

SEC="${WK_TRACE_SEC:-30}"
PCAP="/tmp/wk-sip-$(date +%H%M%S).pcap"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok()   { printf '  \033[1;32m%s\033[0m\n' "$*"; }
bad()  { printf '  \033[1;31m%s\033[0m\n' "$*"; }
warn() { printf '  \033[1;33m%s\033[0m\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "sudo 로 실행하세요"; exit 1; }
command -v tcpdump >/dev/null || {
  echo "tcpdump 가 없습니다:  sudo apt-get install -y tcpdump"; exit 1; }

PHONE="${1:-}"
if [[ -z "$PHONE" ]]; then
  log "전화기 IP 찾기 (등록된 내선의 접속 주소)"
  PHONE="$(asterisk -rx 'pjsip show aors' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
           | grep -oE 'sip:[^@]*@[0-9.]+' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
           | head -1)"
  [[ -n "$PHONE" ]] && ok "찾음: $PHONE" || {
    bad "못 찾았습니다. 전화기 IP 를 인자로 주세요:  sudo $0 10.10.10.106"; exit 1; }
fi

log "캡처 시작 (${SEC}초)"
printf '  \033[1;33m지금 전화기로 7000 을 눌러 메뉴까지 들어가세요.\033[0m\n'
printf '  숫자를 하나 눌러 하위 메뉴까지 가면 더 확실합니다.\n\n'
tcpdump -i any -n -s0 -w "$PCAP" "host $PHONE and udp port 5060" \
        >/dev/null 2>&1 &
TP=$!
for i in $(seq "$SEC" -1 1); do printf '\r  남은 시간 %2d초 ' "$i"; sleep 1; done
printf '\r  캡처 종료          \n'
kill "$TP" 2>/dev/null; wait "$TP" 2>/dev/null

SZ=$(stat -c %s "$PCAP" 2>/dev/null || echo 0)
log "결과  ($PCAP, ${SZ} bytes)"

TXT="/tmp/wk-sip.txt"
tcpdump -r "$PCAP" -n -A 2>/dev/null > "$TXT"
[[ -s "$TXT" ]] || { bad "패킷이 하나도 안 잡혔습니다."
  warn "전화기 IP 가 맞는지, 통화를 실제로 했는지 확인하세요."; exit 1; }

# tcpdump -A 는 패킷의 첫 줄을 자기 헤더 뒤에 이어 붙입니다.
# 그래서 ^ 로 잡으면 안 됩니다.
n_inv=$(grep -cE 'INVITE sip:' "$TXT")
n_upd=$(grep -cE 'UPDATE sip:' "$TXT")
n_pai=$(grep -ciE 'P-Asserted-Identity:' "$TXT")
n_rpid=$(grep -ciE 'Remote-Party-ID:' "$TXT")

printf '  INVITE %-4s  UPDATE %-4s  P-Asserted-Identity %-4s  Remote-Party-ID %s\n' \
       "$n_inv" "$n_upd" "$n_pai" "$n_rpid"

log "PBX 가 전화기로 보낸 이름 헤더"
grep -oiE '(P-Asserted-Identity|Remote-Party-ID): [^\r]*' "$TXT" | sort -u \
  | sed 's/^/  /' || echo "  (없음)"
warn "한글은 tcpdump -A 에서 점(.)으로 보입니다. 헤더가 있는지만 확인하면 됩니다."

log "판정"
if (( n_upd == 0 && n_pai == 0 && n_rpid == 0 )); then
  bad "Asterisk 가 이름을 아예 안 보냈습니다."
  warn "확인 순서:"
  warn "  1) sudo ./verify.sh          <- 다이얼플랜에 pres 설정이 있는지"
  warn "  2) sudo ./enable-display.sh --show"
  warn "  3) 통화 중 화면 갱신 자리(메뉴)까지 실제로 들어갔는지"
elif (( n_pai > 0 || n_rpid > 0 )); then
  if (( n_upd > 0 )); then
    ok "UPDATE 로 이름을 보냈습니다. Asterisk 는 제 몫을 다했습니다."
  else
    warn "이름은 보냈지만 UPDATE 가 없습니다 (re-INVITE 로 나갔을 수 있습니다)."
    warn "전화기가 UPDATE 만 받아 그리는 기종이면 아래를 시도해 보세요:"
    warn "  sudo sed -i 's/^connected_line_method=invite/connected_line_method=update/' \\"
    warn "    /etc/asterisk/pjsip.endpoint_custom_post.conf && sudo fwconsole reload"
  fi
  echo
  warn "그런데도 화면이 안 바뀌면 전화기가 안 그리는 것입니다."
  warn "화면 기능만 끄세요 (음성 안내는 그대로):"
  warn "  sudo sed -i 's/^exten => disp,1,GotoIf.*/exten => disp,1,Return()/' \\"
  warn "    /etc/asterisk/extensions_custom.conf && sudo asterisk -rx 'dialplan reload'"
else
  warn "UPDATE 는 있는데 이름 헤더가 없습니다."
  warn "send_rpid / send_pai 가 실제로 적용됐는지 다시 보세요:"
  warn "  sudo ./enable-display.sh --show"
fi

cat <<EOF

  전체 내용을 직접 보려면
    sudo tcpdump -r $PCAP -n -A | less
  Asterisk 가 통화 중에 무엇을 하려 했는지
    sudo grep -E 'CONNECTEDLINE|connected line' /var/log/asterisk/full | tail
EOF
