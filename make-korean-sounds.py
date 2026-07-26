#!/usr/bin/env python3
"""알림전화 안내 음성을 한국어로 만듭니다. 딱 한 번만 실행하면 끝입니다.

    python3 make-korean-sounds.py                    # gTTS (무료, 키 필요 없음)
    TTS=openai python3 make-korean-sounds.py         # OpenAI (OPENAI_API_KEY 필요)
    TTS=espeak python3 make-korean-sounds.py         # 오프라인 (발음 어색함)

만들어지는 것 (/var/lib/asterisk/sounds/custom/bank/)
    p-*        새벽 오전 오후 저녁 밤 정오 자정
    h-1~h-12   한시 ~ 열두시          m-0~m-59   정각, 일분 ~ 오십구분
    d-1~d-23   한 시간 ~ 스물세 시간  w-1~w-7    월요일 ~ 일요일
    n-1~n-9    첫번째 ~ 아홉번째      t-set      알람 설정하였습니다
    g-*        인사와 안내 문구

이렇게 조각으로 만들어 두면 전화가 올 때 이어서 재생만 하면 됩니다.
Asterisk 가 원래 숫자를 읽는 방식과 같습니다 (digits/1, digits/2 ...).
"""
from __future__ import annotations

import os
import subprocess
import sys
import wave
from pathlib import Path

SOUNDS = Path(os.getenv("SOUNDS_DIR", "/var/lib/asterisk/sounds/custom"))
BANK = SOUNDS / "bank"
TMP = Path(os.getenv("TMP_DIR", "/tmp"))
TTS = os.getenv("TTS", "gtts")

# OpenAI 를 쓸 때만 의미가 있습니다
TTS_MODEL = os.getenv("TTS_MODEL", "gpt-4o-mini-tts")
TTS_VOICE = os.getenv("TTS_VOICE", "cedar")   # 공식 문서 기준 최고 품질(marin/cedar)
TTS_INSTRUCTIONS = os.getenv(
    "TTS_INSTRUCTIONS",
    "한국어 전화 안내 방송입니다. 평소 말하기의 약 90퍼센트 속도로, "
    "처음부터 끝까지 같은 속도를 유지하고 문장 끝을 흐리거나 빨라지지 "
    "않게 또박또박 읽어 주세요. "
    "전화기 스피커는 음질이 좁고 어르신도 들으시니, 자음을 특히 분명하게 "
    "발음하고 웅얼거리지 마세요. "
    "숫자·시각·요일은 한 음절씩 또렷하게 끊어 읽고, '공'은 짧고 분명하게, "
    "'일곱 시 반' 같은 표현은 서두르지 말고 천천히 읽어 주세요. "
    "차분하고 친절한 톤을 유지하되 과장이나 감정은 절제하고, "
    "쉼표에서는 반 박자 충분히 쉬었다가 이어 주세요.")

HOUR = {1: "한", 2: "두", 3: "세", 4: "네", 5: "다섯", 6: "여섯",
        7: "일곱", 8: "여덟", 9: "아홉", 10: "열", 11: "열한", 12: "열두"}
ONES = ["", "일", "이", "삼", "사", "오", "육", "칠", "팔", "구"]

# "몇 시간 뒤" 를 말할 때 쓰는 고유어 수사. 20 은 '스물' 이 아니라 '스무 시간'.
# 1번(몇 분 후)에서 최대 1439분(=23시간 59분)까지 받으므로 23까지 필요합니다.
DUR_HOUR = {1: "한", 2: "두", 3: "세", 4: "네", 5: "다섯", 6: "여섯", 7: "일곱",
            8: "여덟", 9: "아홉", 10: "열", 11: "열한", 12: "열두", 13: "열세",
            14: "열네", 15: "열다섯", 16: "열여섯", 17: "열일곱", 18: "열여덟",
            19: "열아홉", 20: "스무", 21: "스물한", 22: "스물두", 23: "스물세"}

DAYS = {1: "월요일", 2: "화요일", 3: "수요일", 4: "목요일",
        5: "금요일", 6: "토요일", 7: "일요일"}

GREETINGS = {
    "g-hello":     "안녕하세요.",
    # "알람 전화입니다" 를 cedar 가 "알람 저머입니다" 로 읽었습니다.
    # '서비스' 는 첫 음절 '서'가 전화 음질에서 약해 흐릿하게 들립니다.
    # 실제 발음대로 '써비스' 로 적으면 된소리가 또렷하게 살아납니다.
    "g-intro":     "시간 알림 써비스입니다.",

    # --- 메뉴 -----------------------------------------------------------
    # 메뉴는 한 항목씩 읽어 주며 화면도 같이 넘깁니다(다이얼플랜이 순서대로 재생).
    # 목적을 먼저, 번호를 끝에. "~시려면 N번" 으로 어미를 맞춰 리듬을 고릅니다.
    # 목록을 사번으로 옮겨 1·2·3·4 로 이어지게 했습니다.
    "g-menu-1":    "몇 분 뒤에 알람을 받으시려면 일번,",
    "g-menu-2":    "시간을 정해 두시려면 이번,",
    "g-menu-3":    "반복 알람을 맞추시려면 삼번,",
    "g-menu-4":    "예약 목록을 확인하시려면 사번을 눌러 주세요.",

    # --- 입력 안내 -------------------------------------------------------
    # 오후 시각을 24시간제로 넣어야 한다는 걸 아무 데서도 안 알려 줬었습니다.
    # 오전 예시만 있으면 저녁 일곱시를 0700 으로 누르고 고칠 방법을 모릅니다.
    # 매번 다 듣기엔 길어서 둘로 나눴습니다.
    # 처음에는 짧은 것만, 못 알아들으면 두 번째 시도에서 자세한 것을 냅니다.
    # 숫자는 "공, 칠, 삼, 공" 처럼 쉼표로 끊지 않고 "공칠삼공" 으로 붙여 읽습니다.
    # 전화번호를 부를 때처럼 들려서 더 짧고 자연스럽습니다.
    "g-enter":     "시간을 네 자리로 눌러 주세요. "
                   "오전 일곱시 반은 공칠삼공, "
                   "저녁 일곱시는 일구공공입니다.",
    "g-enter2":    "앞의 두 자리가 시, 뒤의 두 자리가 분입니다. "
                   "오전 일곱 시 삼십 분이면 공칠삼공. "
                   "오후에는 열두 시간을 더해 주세요. "
                   "오후 한 시는 일삼공공, 저녁 일곱 시는 일구공공, "
                   "밤 열 시는 이이공공입니다. "
                   "처음으로 돌아가시려면 별표를 눌러 주세요.",
    # 우물 정자를 안 눌러도 됩니다. 숫자만 누르고 손을 떼면 됩니다.
    # (Read 는 시간이 지나면 그때까지 누른 숫자를 그대로 씁니다 — 실측 확인)
    "g-enter-min": "몇 분 뒤에 알람을 맞춰 드릴까요? "
                   "분 단위로 숫자만 눌러 주세요. "
                   "삼십 분 뒤면 삼공입니다.",
    # 3번 반복은 2단 메뉴. 1단계도 메인 메뉴처럼 한 항목씩 읽으며 화면을 넘깁니다.
    "g-rep-1":     "평일 반복은 일번,",
    "g-rep-2":     "주말 반복은 이번,",
    "g-rep-3":     "요일별 반복은 삼번,",
    "g-rep-4":     "매일 반복은 사번을 눌러 주세요.",
    #   2단계: 요일별을 골랐을 때. 요일을 하나씩 읽어 주며 화면도 같이 넘깁니다.
    #     (다이얼플랜이 g-day1 재생 → 화면 "월요일 1번" → g-day2 … 순서로 진행)
    "g-day1":      "월요일은 일번,",
    "g-day2":      "화요일은 이번,",
    "g-day3":      "수요일은 삼번,",
    "g-day4":      "목요일은 사번,",
    "g-day5":      "금요일은 오번,",
    "g-day6":      "토요일은 육번,",
    "g-day7":      "일요일은 칠번,",
    # 요일별 화면 마지막에 함께 안내: 매일은 구번
    "g-day9":      "매일은 구번입니다.",
    # 먼저 예약하고 나서 고칠 기회를 줍니다.
    # "…으로 예약했습니다" 를 "…알람 설정하였습니다" 로 바꾸면 조사가 필요 없어져
    # 정오/정각 같은 예외 처리도 사라집니다.
    "g-fix":       "수정하려면 영번을 눌러 주세요.",
    "g-setdone":   "설정되었습니다. 감사합니다.",

    # --- 마무리 ----------------------------------------------------------
    "g-thanks":    "감사합니다.",
    "g-bye":       "종료하겠습니다.",
    "g-back":      "처음으로 돌아갑니다.",

    # --- 오류: 종류마다 다르게 들려야 원인을 압니다 ------------------------
    "g-invalid":   "잘못 입력하셨습니다.",
    "g-retry":     "다시 입력해 주세요.",
    "g-timeout":   "입력이 없습니다. 다시 안내해 드리겠습니다.",
    "g-nosuch":    "그 번호는 없습니다.",
    "g-error":     "처리 중 문제가 생겼습니다. 잠시 후 다시 시도해 주세요.",
    "g-full":      "예약이 가득 찼습니다. "
                   "예약 목록을 들려 드릴 테니 먼저 하나를 삭제해 주세요.",
    "g-dup":       "이미 예약되어 있습니다.",

    # --- 목록 (한 건씩 듣고 수정/삭제/다음) -------------------------------
    "g-list":      "예약된 알람입니다.",
    "g-item-ask":  "수정하려면 일번, 삭제하려면 이번을 눌러 주세요. "
                   "다음 예약을 보시려면 잠시 기다려 주세요.",
    "g-edit":      "지웠습니다. 다시 설정해 주세요.",
    "g-deleted":   "삭제했습니다. 잠시 기다려 주세요.",
    "g-none":      "예약된 알람이 없습니다.",

    # --- 반복 -------------------------------------------------------------
    "g-weekday":   "평일",
    "g-weekend":   "주말",
    "g-everyday":  "매일",
    "g-isnida":    "입니다.",
    "g-fromnext":  "부터 시작합니다.",

    # --- 남은 시간 --------------------------------------------------------
    # '약' 은 뺐습니다. 뒤 조각과 붙어 "약한 시간"(弱) 으로 들렸고,
    # 분 단위까지 정확한 숫자에 '약' 을 붙이는 것도 어색합니다.
    "g-after":     "후에 알람이 울립니다.",
    "g-soon":      "잠시 후에 알람이 울립니다.",
    "g-today":     "오늘",
    "g-tomorrow":  "내일",

    # --- 시간 알림 전화 ----------------------------------------------------
    # 걸려오는 알람은 '현재 시각'을 알려 주는 안내입니다.
    #   WK_SEQ = g-hello + g-intro + g-nowtime + [시각] + g-isnida
    #            = "안녕하세요. 알림 써비스입니다. 현재 시각은 …입니다."
    #   끝인사 = g-goodday = "좋은 하루 되세요."
    "g-nowtime":   "현재 시각은",
    "g-goodday":   "좋은 하루 되세요.",
}

PERIODS = {
    "p-dawn":  "새벽",
    "p-am":    "오전",
    "p-pm":    "오후",
    "p-eve":   "저녁",
    "p-night": "밤",
    "p-noon":  "정오",
    "p-mid":   "자정",
}


def sino(n: int) -> str:
    """1~59 -> 한자어 수사. 40 -> 사십, 45 -> 사십오, 10 -> 십"""
    t, o = divmod(n, 10)
    s = ("십" if t == 1 else ONES[t] + "십") if t else ""
    return (s + ONES[o]) if o else s


def targets() -> list[tuple[Path, str]]:
    out: list[tuple[Path, str]] = [(BANK / k, v) for k, v in PERIODS.items()]
    out += [(BANK / f"h-{h}", HOUR[h] + " 시") for h in range(1, 13)]
    out.append((BANK / "m-0", "정각"))
    # 시각을 말할 때 30분은 '삼십 분' 보다 '반' 이 자연스럽습니다.
    # 소요시간("삼십 분 후에")에는 그대로 m-30 을 쓰므로 따로 둡니다.
    out.append((BANK / "m-half", "반"))
    out += [(BANK / f"m-{m}", sino(m) + " 분") for m in range(1, 60)]
    # 예약 확정 꼬리말. 조사가 없어 정오/정각 예외 처리가 필요 없습니다.
    out.append((BANK / "t-set", "알람 설정하였습니다."))
    # "십 분 뒤", "한 시간 삼십 분 뒤"
    out.append((BANK / "g-later", "뒤"))
    out += [(BANK / f"d-{h}", DUR_HOUR[h] + " 시간") for h in sorted(DUR_HOUR)]
    # 쉼표를 넣지 않습니다. "토요일부터 시작합니다" 에서 깨집니다.
    # 나열 사이 간격은 day_pieces() 의 무음이 담당합니다.
    out += [(BANK / f"w-{d}", DAYS[d]) for d in sorted(DAYS)]
    # 목록 번호. "일번," 처럼 쉼표를 넣어 다음 항목과 붙지 않게 합니다.
    # '이번,' 은 '이번(this time)' 으로 읽혀 목록 항목을 통째로 오해하게 만듭니다.
    # 서수를 쓰면 DTMF 번호와 그대로 맞으면서 뜻이 흔들리지 않습니다.
    ORD = ["", "첫", "두", "세", "네", "다섯", "여섯", "일곱", "여덟", "아홉"]
    out += [(BANK / f"n-{i}", ORD[i] + " 번째,") for i in range(1, 10)]
    out += [(BANK / k, v) for k, v in GREETINGS.items()]
    out.append((BANK / "sil-250", "(무음 0.25초)"))
    # 통화가 막 연결된 직후에는 전화기가 RTP 를 아직 재생하지 못합니다.
    # 첫 소리 앞에 이 무음을 깔아 "안녕하세요"의 첫 음절이 잘리는 걸 막습니다.
    out.append((BANK / "sil-500", "(무음 0.5초)"))
    return out


def make_silence16(dst: Path, ms: int = 250) -> None:
    import struct
    import wave
    n = int(16000 * ms / 1000)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(struct.pack("<%dh" % n, *([0] * n)))


def make_silence(dst: Path, ms: int = 250) -> None:
    """조각 사이에 넣을 짧은 무음.

    Playback(a&b&c) 는 사이에 아무 것도 안 넣습니다. 그래서
    "사십분삭제했습니다", "정오이 시각이", "월요일수요일금요일" 처럼
    말이 붙어 버립니다. 절이 끝나는 자리에 이 무음을 끼웁니다.
    """
    import struct
    import wave
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(8000)
        w.writeframes(struct.pack("<%dh" % int(8000 * ms / 1000),
                                  *([0] * int(8000 * ms / 1000))))


# 양끝 무음만 -50dB 로 정리해 조각을 바짝 붙입니다 (안쪽은 안 건드립니다).
# 조각 사이 간격은 sil-* 무음이 담당하므로 여기서 여백을 없애야 리듬이 고릅니다.
SILENCE_TRIM = (
    "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,"
    "areverse,"
    "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.05,"
    "areverse"
)
# 모든 조각을 같은 평균 레벨로 맞출 목표치.
TARGET_RMS_DB = -20.0    # 조각들의 평균 음량을 여기로 통일
PEAK_CEIL_DB = -1.0      # 이보다 크게는 안 올려서 클리핑(찌그러짐)을 막음


def _measure_gain_db(wav: Path) -> float:
    """volumedetect 로 평균/최대 음량을 재서 '고정 이득'을 계산합니다.

    loudnorm 같은 동적 압축은 조각 안에서 소리가 커졌다 작아졌다(펌핑)
    하므로 안 씁니다. 조각마다 상수 이득만 한 번 걸어 전 조각을 같은
    크기로 맞춥니다. 최대 음량이 천장을 넘지 않게 이득을 제한합니다.
    """
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(wav),
                        "-af", "volumedetect", "-f", "null", "-"],
                       capture_output=True, text=True)
    mean = peak = None
    for line in r.stderr.splitlines():
        if "mean_volume:" in line:
            try: mean = float(line.split("mean_volume:")[1].split("dB")[0])
            except ValueError: pass
        elif "max_volume:" in line:
            try: peak = float(line.split("max_volume:")[1].split("dB")[0])
            except ValueError: pass
    if mean is None:
        return 0.0
    gain = TARGET_RMS_DB - mean
    if peak is not None:
        gain = min(gain, PEAK_CEIL_DB - peak)   # 클리핑 방지
    return gain


def _norm_pass(input_args: list[str], rate: int, dst: Path) -> None:
    """무음 정리 + 리샘플 → 음량 측정 → 고정 이득 적용 (2단계)."""
    pre = Path(str(dst) + ".pre.wav")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *input_args,
                    "-ac", "1", "-af", SILENCE_TRIM, "-ar", str(rate),
                    "-acodec", "pcm_s16le", "-f", "wav", str(pre)], check=True)
    gain = _measure_gain_db(pre)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(pre),
                    "-af", f"volume={gain:.2f}dB",
                    "-acodec", "pcm_s16le", "-f", "wav", str(dst)], check=True)
    pre.unlink(missing_ok=True)


def to_asterisk_wav(src: Path, dst: Path) -> None:
    """8kHz(.wav) 와 16kHz(.wav16) 두 벌을 만듭니다.

    전화기가 G.722(16kHz)로 붙으면 8kHz 파일은 조각마다 리샘플링을 거칩니다.
    조각을 수십 개 이어 붙이는 구조라 그 경계마다 소리가 뭉개져서
    말이 겹치거나 섞이는 것처럼 들립니다.
    16kHz 판을 같이 두면 Asterisk 가 그쪽을 골라 변환 없이 내보냅니다.
    (Asterisk 포맷 표: slin16 <-> wav16)
    """
    _norm_pass(["-i", str(src)], 8000, dst)
    _norm_pass(["-i", str(src)], 16000, dst.with_suffix(".wav16"))


def say(text: str, base: Path) -> None:
    dst = base.with_suffix(".wav")
    if base.name.startswith("sil-"):
        ms = int(base.name.split("-")[1])
        make_silence(dst, ms)
        make_silence16(dst.with_suffix(".wav16"), ms)
        return
    if TTS == "gtts":
        from gtts import gTTS
        mp3 = TMP / (base.name + ".mp3")
        gTTS(text=text, lang="ko").save(str(mp3))
        to_asterisk_wav(mp3, dst)
        mp3.unlink(missing_ok=True)
    elif TTS == "openai":
        from openai import OpenAI
        raw = TMP / (base.name + ".pcm")
        kw = {"model": TTS_MODEL, "voice": TTS_VOICE,
              "input": text, "response_format": "pcm"}
        # gpt-4o-mini-tts 는 instructions 로 말투/속도를 지시할 수 있습니다.
        # 알람 안내는 또박또박 천천히가 맞습니다.
        if TTS_INSTRUCTIONS and "mini-tts" in TTS_MODEL:
            kw["instructions"] = TTS_INSTRUCTIONS
        r = OpenAI().audio.speech.create(**kw)
        raw.write_bytes(r.read() if hasattr(r, "read") else r.content)
        # OpenAI pcm 은 24kHz / 16bit / mono raw 입니다
        for rate, out in ((8000, dst), (16000, dst.with_suffix(".wav16"))):
            _norm_pass(["-f", "s16le", "-ar", "24000", "-ac", "1", "-i", str(raw)],
                       rate, out)
        raw.unlink(missing_ok=True)
    elif TTS == "espeak":
        tmp = TMP / (base.name + ".espeak.wav")
        subprocess.run(["espeak-ng", "-v", "ko", "-s", "125", "-w", str(tmp), text],
                       check=True)
        to_asterisk_wav(tmp, dst)
        tmp.unlink(missing_ok=True)
    else:
        raise SystemExit(f"TTS 백엔드를 모르겠습니다: {TTS} (gtts|openai|espeak)")


def seconds(p: Path) -> float:
    with wave.open(str(p)) as w:
        return w.getnframes() / float(w.getframerate())


def preflight() -> None:
    """한 개만 먼저 만들어 봅니다. 키나 목소리 이름이 틀렸으면
    전부 실패하며 과금되기 전에 여기서 멈춥니다."""
    if TTS == "openai" and not os.getenv("OPENAI_API_KEY"):
        raise SystemExit(
            "OPENAI_API_KEY 가 없습니다.\n"
            "  sudo OPENAI_API_KEY=sk-... TTS=openai python3 make-korean-sounds.py")
    probe = TMP / "kv-probe"
    try:
        say("확인", probe)
        n = seconds(probe.with_suffix(".wav"))
    except Exception as e:                          # noqa: BLE001
        raise SystemExit(f"\n[X] TTS 시험 실패 — 여기서 멈춥니다.\n    {type(e).__name__}: {e}\n"
                         f"    백엔드={TTS} 모델={TTS_MODEL} 목소리={TTS_VOICE}")
    finally:
        probe.with_suffix(".wav").unlink(missing_ok=True)
    if n < 0.15:
        raise SystemExit(f"[X] 시험 음성이 {n:.2f}초뿐입니다. 합성이 제대로 안 됐습니다.")
    print(f"  시험 합성 OK ({n:.2f}초)\n")


def main() -> int:
    BANK.mkdir(parents=True, exist_ok=True)
    todo = targets()
    force = "--force" in sys.argv
    made = skipped = 0
    fail: list[str] = []

    print(f"TTS 백엔드: {TTS}   대상: {len(todo)}개")
    if TTS == "openai":
        print(f"모델: {TTS_MODEL}   목소리: {TTS_VOICE}")
    preflight()
    for i, (base, text) in enumerate(todo, 1):
        dst = base.with_suffix(".wav")
        w16 = dst.with_suffix(".wav16")
        if dst.exists() and dst.stat().st_size > 200 \
                and w16.exists() and w16.stat().st_size > 200 and not force:
            skipped += 1
            continue
        sys.stdout.write(f"\r[{i}/{len(todo)}] {base.name:12s} {text[:24]:26s}")
        sys.stdout.flush()
        try:
            say(text, base)
            if not dst.exists() or dst.stat().st_size <= 200:
                raise RuntimeError("파일이 비었습니다")
            made += 1
        except Exception as e:                      # noqa: BLE001
            fail.append(f"{base.name}: {e}")
    sys.stdout.write("\r" + " " * 70 + "\r")

    try:
        uid = __import__("pwd").getpwnam("asterisk").pw_uid
        for p in list(BANK.glob("*.wav")) + list(BANK.glob("*.wav16")):
            os.chown(p, uid, -1)
        os.chown(BANK, uid, -1)
    except (KeyError, PermissionError):
        pass

    print(f"새로 만듦 : {made}개")
    print(f"이미 있음 : {skipped}개   (--force 로 다시 만듭니다)")

    # 빠진 조각 검사 — 하나만 없어도 그 시각 안내가 조용해집니다
    need = [b.name for b, _ in todo]
    have = {p.stem for p in BANK.glob("*.wav")}
    missing = [n for n in need if n not in have]
    short = [p.name for p in BANK.glob("*.wav")
             if not p.name.startswith("sil-") and seconds(p) < 0.15]

    if fail:
        print(f"\n실패 {len(fail)}개:")
        for f in fail[:10]:
            print("  " + f)
    if missing:
        print(f"\n[!] 빠진 파일 {len(missing)}개: {missing[:10]}")
    if short:
        print(f"\n[!] 너무 짧은 파일 {len(short)}개 (합성 실패 의심): {short[:10]}")
    if not (fail or missing or short):
        print(f"\n조각 {len(need)}개 전부 정상  ->  {SOUNDS}")
        print("\n07:40 알람 안내를 미리 들어보려면:")
        print("  sudo asterisk -rx 'dialplan show wakeup-call'")
    return 1 if (fail or missing) else 0


if __name__ == "__main__":
    sys.exit(main())
