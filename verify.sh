#!/usr/bin/env bash
#==============================================================================
# 깔린 것과 소스가 서로 맞는지 대조합니다.
#
#   sudo ./verify.sh
#
# 왜 필요한가
#   음성 조각, AGI, 다이얼플랜이 각각 다른 자리에 깔립니다.
#   설치가 중간에 멈추면 "음성은 새 것인데 다이얼플랜은 옛 것" 같은 상태가 되고,
#   그러면 안내는 "일번 몇 분 후" 라고 말하는데 일번을 누르면 시각을 묻습니다.
#   눈으로는 찾기 어려운 어긋남이라 기계로 대조합니다.
#==============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/extensions_custom-korean.conf"
DEPLOY="/etc/asterisk/extensions_custom.conf"
BANK="/var/lib/asterisk/sounds/custom/bank"
AGI="/var/lib/asterisk/agi-bin/wakeup.agi"

ok()   { printf '  \033[1;32m[OK]\033[0m   %s\n' "$*"; }
bad()  { printf '  \033[1;31m[문제]\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
note() { printf '         %s\n' "$*"; }
log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
FAIL=0

[[ $EUID -eq 0 ]] || { echo "sudo 로 실행하세요"; exit 1; }

#------------------------------------------------------------------------------
log "1. 메뉴 번호와 실제 목적지"
#------------------------------------------------------------------------------
# 메뉴는 wakeup-menu 에 있습니다 (wakeup-book 은 콜백 진입점).
# 다이얼플랜에 로드된 실제 값을 봅니다 (파일이 아니라 Asterisk 가 읽은 것)
LIVE="$(asterisk -rx 'dialplan show wakeup-menu' 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
if [[ -z "$LIVE" || "$LIVE" == *"no existence"* ]]; then
  bad "wakeup-menu 컨텍스트가 로드되지 않았습니다"
  note "sudo asterisk -rx 'dialplan reload'  를 먼저 해 보세요"
else
  declare -A DEST
  while read -r n d; do DEST[$n]="$d"; done < <(
    echo "$LIVE" | grep -oE '"\$\{SEL\}" = "[0-9]"\]\?[a-z-]+' \
                 | sed 's/.*= "\([0-9]\)"\]?\(.*\)/\1 \2/')
  for n in 1 2 3 9; do
    printf '  %s번 -> %s\n' "$n" "${DEST[$n]:-(없음)}"
  done
  # 음성이 무엇이라고 말하는지와 맞는지 확인
  EXPECT_1="wk-after"; EXPECT_2="wk-time"
  [[ "${DEST[1]:-}" == "$EXPECT_1" ]] \
    && ok "1번 = 몇 분 후 (wk-after)" \
    || bad "1번이 ${DEST[1]:-없음} 로 갑니다. wk-after 여야 합니다"
  [[ "${DEST[2]:-}" == "$EXPECT_2" ]] \
    && ok "2번 = 시각 (wk-time)" \
    || bad "2번이 ${DEST[2]:-없음} 로 갑니다. wk-time 여야 합니다"
  [[ "${DEST[3]:-}" == "wk-rep" ]] && ok "3번 = 반복" || bad "3번 목적지 이상"
  [[ "${DEST[9]:-}" == "wakeup-list" ]] && ok "9번 = 확인·삭제" || bad "9번 목적지 이상"
fi

# 콜백 진입점과 발신 컨텍스트가 로드됐는지
for ctx in wakeup-book wakeup-cb-dial; do
  L="$(asterisk -rx "dialplan show $ctx" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
  if [[ -z "$L" || "$L" == *"no existence"* ]]; then
    bad "콜백 컨텍스트 $ctx 가 없습니다"
  else
    ok "콜백 컨텍스트 $ctx 로드됨"
  fi
done

#------------------------------------------------------------------------------
log "2. 각 컨텍스트가 맞는 AGI 모드를 부르는가"
#------------------------------------------------------------------------------
check_ctx() {
  local ctx="$1" want="$2"
  local got
  got="$(asterisk -rx "dialplan show $ctx" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
        | grep -oE 'wakeup\.agi,(peek|book)-[a-z]+' | sed 's/.*,//' | sort -u | paste -sd, -)"
  if [[ -z "$got" ]]; then
    bad "$ctx: AGI 호출을 찾지 못했습니다"
  elif [[ "$got" == "$want" ]]; then
    ok "$ctx -> $got"
  else
    bad "$ctx -> $got  (기대: $want)"
  fi
}
check_ctx wk-after "book-after,peek-after"
check_ctx wk-time  "book-time,peek-time"
check_ctx wk-rep   "book-rep,peek-rep"

#------------------------------------------------------------------------------
log "3. 되돌아갈 자리(WK_BACK)가 자기 컨텍스트인가"
#------------------------------------------------------------------------------
for c in wk-after wk-time wk-rep; do
  v="$(asterisk -rx "dialplan show $c" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' \
      | grep -oE 'WK_BACK=[a-z-]+' | head -1 | cut -d= -f2)"
  [[ "$v" == "$c" ]] && ok "$c: WK_BACK=$v" || bad "$c: WK_BACK=$v (자기 이름이어야 합니다)"
done

#------------------------------------------------------------------------------
log "4. 깔린 다이얼플랜이 소스와 같은가"
#------------------------------------------------------------------------------
if [[ ! -f "$SRC" ]]; then
  note "소스 파일이 없어 건너뜁니다 ($SRC)"
elif [[ ! -f "$DEPLOY" ]]; then
  bad "$DEPLOY 이 없습니다"
else
  # 표시 구간만 떼어 내 비교합니다 (사용자가 다른 블록을 넣어 뒀을 수 있으므로)
  a="$(mktemp)"; b="$(mktemp)"
  sed -n '/WAKEUP-KOREAN BEGIN/,/WAKEUP-KOREAN END/p' "$DEPLOY" > "$a"
  sed -n '/WAKEUP-KOREAN BEGIN/,/WAKEUP-KOREAN END/p' "$SRC"    > "$b"
  if [[ ! -s "$a" ]]; then
    bad "깔린 파일에 알람전화 구간 표시가 없습니다 (옛 버전으로 보입니다)"
    note "sudo python3 replace-blocks.py $DEPLOY $SRC && sudo fwconsole reload"
  elif diff -q "$a" "$b" >/dev/null; then
    ok "깔린 다이얼플랜 = 소스"
  else
    bad "깔린 다이얼플랜이 소스와 다릅니다 ($(diff "$a" "$b" | grep -c '^[<>]') 줄)"
    note "다른 부분:"
    diff "$a" "$b" | grep '^[<>]' | head -6 | sed 's/^/           /'
    note "고치기: sudo python3 replace-blocks.py $DEPLOY $SRC && sudo fwconsole reload"
  fi
  rm -f "$a" "$b"
fi

#------------------------------------------------------------------------------
log "5. 음성 조각"
#------------------------------------------------------------------------------
if [[ ! -d "$BANK" ]]; then
  bad "$BANK 가 없습니다"
else
  N=$(find "$BANK" -name '*.wav' | wc -l)
  N16=$(find "$BANK" -name '*.wav16' | wc -l)
  WANT=$(python3 - "$HERE" <<'PY' 2>/dev/null || echo 0
import importlib.util, sys
p = sys.argv[1] + "/make-korean-sounds.py"
s = importlib.util.spec_from_file_location("m", p)
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(len(m.targets()))
PY
)
  [[ "$N" == "$WANT" ]] && ok "8kHz $N/$WANT" || bad "8kHz $N/$WANT 개"
  [[ "$N16" == "$WANT" ]] && ok "16kHz $N16/$WANT (G.722 통화용)" \
    || bad "16kHz $N16/$WANT — G.722 에서 소리가 뭉개질 수 있습니다"
  if [[ -x /usr/local/bin/wk-daily.py ]]; then
    /usr/local/bin/wk-daily.py --check >/dev/null 2>&1 \
      && ok "빠진 조각 없음" || bad "빠진 조각이 있습니다 (wk-daily.py --check)"
  fi
fi

#------------------------------------------------------------------------------
log "6. AGI"
#------------------------------------------------------------------------------
if [[ ! -f "$AGI" ]]; then
  bad "$AGI 가 없습니다"
else
  [[ -x "$AGI" ]] && ok "실행 권한 있음" || bad "실행 권한이 없습니다 (chmod +x)"
  python3 -c "import ast; ast.parse(open('$AGI').read())" 2>/dev/null \
    && ok "문법 정상" || bad "문법 오류"
  if [[ -f "$HERE/wakeup.agi" ]]; then
    cmp -s "$AGI" "$HERE/wakeup.agi" && ok "깔린 AGI = 소스" \
      || bad "깔린 AGI 가 소스와 다릅니다 (install -m 0755 wakeup.agi $AGI)"
  fi
fi

#------------------------------------------------------------------------------
log "7. 로그를 쓸 수 있는가"
#------------------------------------------------------------------------------
L=/var/log/asterisk/wakeup.log
if [[ -f "$L" ]]; then
  own="$(stat -c '%U' "$L")"
  [[ "$own" == "asterisk" ]] && ok "wakeup.log 소유자 asterisk" \
    || bad "wakeup.log 소유자가 $own — AGI 가 아무것도 못 씁니다 (chown asterisk)"
else
  note "wakeup.log 이 아직 없습니다 (첫 예약 때 만들어집니다)"
fi

#------------------------------------------------------------------------------
log "8. 화면 표시 설정"
#------------------------------------------------------------------------------
ON=(); OFF=(); SKIP=()
while read -r e; do
  [[ -n "$e" ]] || continue
  line="$(asterisk -rx "pjsip show endpoint $e" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')"
  if [[ -z "$line" || "$line" == *"Unable to find"* || "$line" == *"no object"* ]]; then
    SKIP+=("$e")                       # 설정 파일엔 있는데 엔드포인트로는 없는 것
  elif grep -qE 'send_(rpid|pai) +: +(yes|true)' <<<"$line"; then
    ON+=("$e")
  else
    OFF+=("$e")
  fi
done < <(sed -n 's/^\[\([0-9][0-9]*\)\].*/\1/p' /etc/asterisk/pjsip.endpoint.conf 2>/dev/null | sort -un)
if (( ${#ON[@]} + ${#OFF[@]} == 0 )); then
  note "내선을 찾지 못했습니다"
elif (( ${#OFF[@]} == 0 )); then
  ok "내선 ${#ON[@]}개 전부 켜져 있습니다: ${ON[*]}"
else
  bad "꺼진 내선: ${OFF[*]}   (켜진 것: ${ON[*]:-없음})"
  note "sudo ./enable-display.sh --all"
fi
(( ${#SKIP[@]} == 0 )) || note "엔드포인트로 조회되지 않는 섹션(무시): ${SKIP[*]}"
if grep -q 'CONNECTEDLINE(pres)' "$DEPLOY" 2>/dev/null; then
  ok "다이얼플랜에 pres 설정 있음"
else
  bad "다이얼플랜에 CONNECTEDLINE(pres) 가 없습니다 — 켜도 화면이 안 뜹니다"
fi

#------------------------------------------------------------------------------
printf '\n'
if (( FAIL == 0 )); then
  printf '\033[1;32m전부 맞습니다.\033[0m\n'
else
  printf '\033[1;31m문제 %d건.\033[0m 위의 [문제] 줄을 보세요.\n' "$FAIL"
  printf '대부분은 다시 설치하면 해결됩니다:\n'
  printf '  sudo ./install-korean-voice.sh --tts openai\n'
fi
exit $(( FAIL > 0 ))
