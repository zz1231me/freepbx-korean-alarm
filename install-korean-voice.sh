#!/usr/bin/env bash
#==============================================================================
# 알림전화 안내를 한국어로 바꿉니다.  FreePBX 에서 한 번만 실행하세요.
#
#   sudo ./install-korean-voice.sh                 # gTTS (무료, 키 필요 없음)
#   sudo ./install-korean-voice.sh --tts openai    # OpenAI (키 필요, 목소리 더 좋음)
#   sudo ./install-korean-voice.sh --tts espeak    # 인터넷 없이 (발음 어색함)
#
# 하는 일
#   1) ffmpeg 설치, venv 만들고 TTS 라이브러리 설치
#   2) 한국어 안내 음성 조각 171개 생성  <- 여기서만 인터넷/TTS 를 씁니다
#   3) wakeup.agi 를 Asterisk AGI 폴더에 설치
#   4) 옛 wakeup-* 다이얼플랜을 한국어 버전으로 교체 (백업 후)
#
#   목소리: 기본 cedar. --voice marin / nova / coral ... 로 바꿀 수 있습니다.
#
# 끝나면 웹에서 번호만 연결하면 됩니다 (안내가 나옵니다).
#==============================================================================
set -euo pipefail

TTS="gtts"
VOICE="${TTS_VOICE:-cedar}"   # 공식 문서 기준 최고 품질(marin/cedar)
KEYFILE="/etc/korean-voice.env"
VENV="/opt/korean-voice/venv"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM="/etc/asterisk/extensions_custom.conf"
SOUNDS="/var/lib/asterisk/sounds/custom"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tts)   TTS="$2"; shift 2 ;;
    --voice) VOICE="$2"; shift 2 ;;
    --key)   OPENAI_API_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "알 수 없는 옵션: $1"; exit 1 ;;
  esac
done

log()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[X] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "sudo 로 실행하세요"
command -v fwconsole >/dev/null || die "FreePBX 서버에서 실행하세요"
[[ -f "$HERE/make-korean-sounds.py" ]] || die "make-korean-sounds.py 가 같은 폴더에 있어야 합니다"
[[ -f "$HERE/extensions_custom-korean.conf" ]] || die "extensions_custom-korean.conf 가 없습니다"

for f in wakeup.agi wk-daily.py replace-blocks.py wakeup-logrotate enable-display.sh \
         verify.sh trace-display.sh wakeup-daily.service wakeup-daily.timer wakeup-prune.service; do
  [[ -f "$HERE/$f" ]] || die "$f 가 같은 폴더에 있어야 합니다"
done

#------------------------------------------------------------------------------
log "1/4  준비"
#------------------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
PKGS=(ffmpeg python3-venv)
[[ "$TTS" == "espeak" ]] && PKGS+=(espeak-ng)
apt-get install -y --no-install-recommends "${PKGS[@]}" >/dev/null
echo "  ffmpeg $(ffmpeg -version 2>/dev/null | head -1 | cut -d' ' -f3)"

mkdir -p /opt/korean-voice "$SOUNDS/bank"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
case "$TTS" in
  gtts)   "$VENV/bin/pip" install -q gTTS   || die "gTTS 설치 실패" ;;
  openai) "$VENV/bin/pip" install -q openai || die "openai 설치 실패" ;;
  espeak) : ;;
  *) die "TTS 는 gtts | openai | espeak 중 하나입니다" ;;
esac
echo "  TTS 백엔드: $TTS"

# --- OpenAI 키 찾기 ----------------------------------------------------------
# sudo 는 기본적으로 환경변수를 지웁니다. 그래서 키를 명시적으로 챙깁니다.
if [[ "$TTS" == "openai" ]]; then
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    for f in "$KEYFILE" /etc/wakeup-voice.env; do
      if [[ -f "$f" ]]; then
        # shellcheck disable=SC1090
        set +u; . "$f"; set -u
        [[ -n "${OPENAI_API_KEY:-}" ]] && { echo "  키 출처: $f"; break; }
      fi
    done
  else
    echo "  키 출처: 환경변수/--key"
  fi
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    cat >&2 <<'MSG'

[X] OPENAI_API_KEY 를 찾지 못했습니다. 셋 중 하나로 주세요.

  방법 1 (추천) — 키 파일을 먼저 만들고 다시 실행
      sudo tee /etc/korean-voice.env >/dev/null <<'EOF'
      OPENAI_API_KEY=sk-여기에본인키
      EOF
      sudo chmod 600 /etc/korean-voice.env
      sudo ./install-korean-voice.sh --tts openai

  방법 2 — 명령줄로 (셸 기록에 키가 남습니다)
      sudo ./install-korean-voice.sh --tts openai --key sk-여기에본인키

  방법 3 — 환경변수를 유지한 채 sudo
      sudo -E ./install-korean-voice.sh --tts openai
MSG
    exit 1
  fi
  export OPENAI_API_KEY
  echo "  키 확인: sk-...${OPENAI_API_KEY: -4}"
  echo "  목소리 : $VOICE"
  # 다음에 다시 만들 때를 위해 저장해 둡니다
  if [[ ! -f "$KEYFILE" ]]; then
    printf 'OPENAI_API_KEY=%s\nTTS_VOICE=%s\n' "$OPENAI_API_KEY" "$VOICE" > "$KEYFILE"
    chmod 600 "$KEYFILE"
    echo "  저장: $KEYFILE (600)"
  fi
fi

#------------------------------------------------------------------------------
log "2/4  한국어 안내 음성 만들기 (171개, 몇 분 걸립니다)"
#------------------------------------------------------------------------------
install -m 0755 "$HERE/make-korean-sounds.py" /usr/local/bin/make-korean-sounds.py
if ! TTS="$TTS" TTS_VOICE="$VOICE" OPENAI_API_KEY="${OPENAI_API_KEY:-}" \
     "$VENV/bin/python" /usr/local/bin/make-korean-sounds.py; then
  warn "음성 생성에 실패했습니다. 위 메시지를 확인하세요."
  warn "  gtts   -> 서버가 translate.google.com 으로 나갈 수 있어야 합니다"
  warn "  openai -> 키가 맞는지, 잔액이 있는지 확인하세요"
  warn "다시 시도:"
  warn "  sudo TTS=$TTS TTS_VOICE=$VOICE \\"
  warn "    \$(grep -h OPENAI_API_KEY $KEYFILE 2>/dev/null) \\"
  warn "    $VENV/bin/python /usr/local/bin/make-korean-sounds.py --force"
fi

N=$(find "$SOUNDS/bank" -name '*.wav' | wc -l)
N16=$(find "$SOUNDS/bank" -name '*.wav16' | wc -l)
echo "  조각 ${N}/171 개 (8kHz) + ${N16}/171 개 (16kHz)"
(( N16 >= 171 )) || warn "16kHz 판이 부족합니다. G.722 통화에서 소리가 뭉개질 수 있습니다"
(( N >= 171 )) || warn "조각이 부족합니다. 부족한 시각은 안내가 조용할 수 있습니다"

#------------------------------------------------------------------------------
log "3/4  AGI 설치"
#------------------------------------------------------------------------------
# 시각 -> 한국어 변환과 예약 로직은 전부 wakeup.agi 안에 있습니다.
AGIDIR="$(asterisk -rx 'core show settings' 2>/dev/null \
          | awk -F: '/AGI directory/{gsub(/ /,"",$2); print $2}')"
AGIDIR="${AGIDIR:-/var/lib/asterisk/agi-bin}"
mkdir -p "$AGIDIR"
install -m 0755 "$HERE/wakeup.agi" "$AGIDIR/wakeup.agi"
chown asterisk:asterisk "$AGIDIR/wakeup.agi"
echo "  $AGIDIR/wakeup.agi"
python3 -c "import ast; ast.parse(open('$AGIDIR/wakeup.agi').read())" \
  && echo "  문법 확인 OK" || die "wakeup.agi 문법 오류"
# 반복 알림을 매일 펼쳐 주는 부분
install -m 0755 "$HERE/wk-daily.py" /usr/local/bin/wk-daily.py
mkdir -p /var/lib/asterisk/wakeup
chown asterisk:asterisk /var/lib/asterisk/wakeup
chmod 0775 /var/lib/asterisk/wakeup
# 로그 파일을 미리 asterisk 소유로 만들어 둡니다.
# root 로 먼저 만들어지면 AGI(=asterisk)가 그 뒤로 조용히 아무것도 못 씁니다.
touch /var/log/asterisk/wakeup.log
chown asterisk:asterisk /var/log/asterisk/wakeup.log
chmod 0664 /var/log/asterisk/wakeup.log
install -m 0644 "$HERE/wakeup-daily.service"  /etc/systemd/system/
install -m 0644 "$HERE/wakeup-daily.timer"    /etc/systemd/system/
install -m 0644 "$HERE/wakeup-prune.service"  /etc/systemd/system/
systemctl daemon-reload
systemctl enable wakeup-prune.service >/dev/null 2>&1 \
  && echo "  wakeup-prune.service 등록 (부팅 때 지난 알람 청소)" \
  || warn "prune 서비스 등록 실패"
systemctl enable --now wakeup-daily.timer >/dev/null 2>&1 \
  && echo "  wakeup-daily.timer 등록 (매일 00:05 + 부팅 2분 뒤)" \
  || warn "systemd timer 등록 실패 - 반복 알림이 다음 날 안 울릴 수 있습니다"
install -m 0644 "$HERE/wakeup-logrotate" /etc/logrotate.d/wakeup
install -m 0755 "$HERE/enable-display.sh" /usr/local/bin/wk-enable-display.sh
install -m 0755 "$HERE/verify.sh" /usr/local/bin/wk-verify.sh
install -m 0755 "$HERE/trace-display.sh" /usr/local/bin/wk-trace-display.sh
/usr/local/bin/wk-daily.py >/dev/null 2>&1 || true

# 옛 버전 잔재 정리
rm -f /usr/local/bin/wakeup-schedule.sh /usr/local/bin/wakeup-cancel.sh 2>/dev/null || true

#------------------------------------------------------------------------------
log "4/4  다이얼플랜 교체"
#------------------------------------------------------------------------------
touch "$CUSTOM"
BK="${CUSTOM}.bak-$(date +%Y%m%d-%H%M%S)"
cp -a "$CUSTOM" "$BK"
echo "  백업: $BK"

# 옛 wakeup-* 블록을 걷어내고 새 것으로 바꿉니다.
# #include / #exec 는 컨텍스트에 속하지 않으므로 절대 건드리지 않습니다.
install -m 0755 "$HERE/replace-blocks.py" /usr/local/bin/wk-replace-blocks.py
python3 /usr/local/bin/wk-replace-blocks.py \
  "$CUSTOM" "$HERE/extensions_custom-korean.conf" || die "다이얼플랜 교체 실패"
chown asterisk:asterisk "$CUSTOM"

fwconsole reload >/dev/null 2>&1 || fwconsole reload

#------------------------------------------------------------------------------
log "설치 확인 (깔린 것과 소스를 대조합니다)"
#------------------------------------------------------------------------------
"$HERE/verify.sh" || warn "위의 [문제] 줄을 확인하세요"

cat <<EOF

===========================================================================
 설치 완료

 남은 작업 (웹에서 1분)
   1. Admin -> Custom Destinations   Target: wakeup-book,s,1  (설명: 알람전화)
   2. Applications -> Misc Applications   Feature Code: 7000
   3. Apply Config
   (번호는 7000 하나뿐입니다. 확인/삭제는 메뉴 4번입니다.)

 통화 중 전화기 화면에 안내가 안 뜬다면
   Applications -> Extensions -> 내선 -> Advanced 탭
     Send RPID = Yes,  Trust RPID = Yes   -> Submit -> Apply Config
   웹에 그 항목이 없으면 콘솔로 (모든 내선 한 번에):
     sudo wk-enable-display.sh --all
     sudo wk-enable-display.sh --show     상태 보기
     sudo wk-enable-display.sh --off      되돌리기

 사용  —  7000 하나만 기억하시면 됩니다
   7000 -> "안녕하세요. 알림 써비스입니다."
        -> (한 항목씩 화면 넘기며) "몇 분 뒤에 알람을 받으시려면 일번,
            시간을 정해 두시려면 이번, 반복 알람을 맞추시려면 삼번,
            예약 목록을 확인하시려면 사번."

     1번  30          -> "삼십 분 뒤 알람 설정하였습니다"
     2번  1900        -> "오늘 저녁 일곱시 정각 알람 설정하였습니다"
     3번  1 → 0730    -> "평일 오전 일곱시 반 알람 설정하였습니다.
                          내일부터 시작합니다"
     4번             -> "예약된 알람입니다." (한 건씩)
                          "매일 오전 일곱 시. 수정 일번, 삭제 이번, 다음 구번."
                           1=수정(지우고 다시), 2=삭제, 9=다음, *=끝

   반복(3번): 1 평일 / 2 주말 / 3 요일별 / 4 매일 을 고른 뒤 시각 HHMM
   요일별(3): 요일을 하나씩 읽어 주며(화면도 넘김) 월1 … 일7 중 하루만
             (여러 요일이 필요하면 여러 번 예약)

 반복 알림 관리 (콘솔)
   sudo wk-daily.py --list        등록된 반복 알림 보기
   sudo wk-daily.py --del 3       3번 규칙 지우기
   sudo wk-daily.py --dry         오늘 무엇이 깔릴지 미리 보기
   sudo wk-daily.py --check       안내 음성 조각이 다 있는지 검사
   systemctl list-timers wakeup-daily.timer

 확인
   sudo wk-verify.sh                    <- 깔린 것과 소스를 전부 대조합니다
   ls /var/lib/asterisk/sounds/custom/bank/*.wav | wc -l   # 171 이어야 합니다
   ls /var/lib/asterisk/sounds/custom/bank/*.wav16 | wc -l # 171 (16kHz 판)
   ls -la --time-style=long-iso /var/spool/asterisk/outgoing/
   sudo asterisk -rx 'dialplan show wakeup-call'
   tail -f /var/log/asterisk/full

 목소리를 바꾸고 싶으면
   sudo rm -rf ${SOUNDS}/bank
   sudo ./install-korean-voice.sh --tts openai --voice cedar
   # 쓸 수 있는 목소리: alloy ash ballad coral echo fable nova onyx
   #                    sage shimmer verse marin cedar
===========================================================================
EOF
