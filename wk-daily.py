#!/usr/bin/env python3
"""반복 알림 규칙을 오늘치 call file 로 펼칩니다.

    wk-daily.py           오늘 것을 만든다 (systemd timer 가 매일 00:05 과 부팅 시 실행)
    wk-daily.py --list    등록된 반복 규칙 보기
    wk-daily.py --del ID  규칙 하나 지우기
    wk-daily.py --dry     만들지 않고 무엇을 만들지만 보기
    wk-daily.py --check   안내 음성 조각이 다 있는지 검사
    wk-daily.py --prune   지난 call file 청소 (부팅 때 asterisk 보다 먼저)

왜 이렇게 하나
  call file 은 한 번 쓰고 사라집니다. 반복을 만들려면 누군가 매일 새로 깔아야 합니다.
  "알람이 울릴 때 다음 주 것을 예약" 하는 방식은 한 번이라도 실패하면 사슬이 끊깁니다.
  규칙을 파일에 두고 매일 아침 펼치는 쪽이 서버가 꺼졌다 켜져도 스스로 복구됩니다.

  중복 방지: 같은 규칙으로 오늘 이미 만든 파일이 있으면 건너뜁니다.
  (규칙 등록 시점에 오늘 것을 미리 깔아 두기 때문에 이 검사가 필요합니다)
"""
from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/var/lib/asterisk/agi-bin")

# wakeup.agi 는 확장자가 .py 가 아니라 그냥 import 되지 않습니다.
_AGI_PATHS = ["/var/lib/asterisk/agi-bin/wakeup.agi",
              os.path.join(os.path.dirname(os.path.abspath(__file__)), "wakeup.agi")]
wk = None
for _p in _AGI_PATHS:
    if os.path.isfile(_p):
        import importlib.util
        _spec = importlib.util.spec_from_loader("wk", loader=None)
        wk = importlib.util.module_from_spec(_spec)
        wk.__file__ = _p
        exec(compile(open(_p, encoding="utf-8").read(), _p, "exec"), wk.__dict__)
        break
if wk is None:
    sys.exit("wakeup.agi 를 찾지 못했습니다")


def today_tag(rule: dict, day: datetime) -> str:
    return f"rep{rule['id']}"


def already_made(rule: dict, target: datetime) -> bool:
    """오늘 같은 규칙으로 만든 call file 이 이미 있는지."""
    pat = f"wakeup-{rule['ext']}-{target:%H%M}-rep{rule['id']}-*.call"
    if any(wk.SPOOL.glob(pat)):
        return True
    # 이미 발사되어 outgoing_done 으로 옮겨진 것도 오늘 것이면 다시 만들지 않습니다
    done = wk.SPOOL.parent / "outgoing_done"
    if done.is_dir():
        for p in done.glob(pat):
            try:
                if datetime.fromtimestamp(p.stat().st_mtime).date() == target.date():
                    return True
            except OSError:
                pass
    return False


def main() -> int:
    args = sys.argv[1:]
    rules = wk.load_rules()

    if "--list" in args:
        if not rules:
            print("등록된 반복 알림이 없습니다.")
            return 0
        print(f"{'ID':>3}  {'내선':<6} {'요일':<24} {'시각':<6} 등록일")
        for r in rules:
            print(f"{r['id']:>3}  {str(r['ext']):<6} "
                  f"{wk.day_text(r['days']):<24} "
                  f"{r['hh']:02d}:{r['mm']:02d}  {r.get('created', '')}")
        return 0

    if "--prune" in args:
        n = wk.prune()
        print(f"지난 call file {n}개를 지웠습니다.")
        return 0

    if "--del" in args:
        try:
            rid = int(args[args.index("--del") + 1])
        except (IndexError, ValueError):
            print("사용법: wk-daily.py --del <ID>", file=sys.stderr)
            return 2
        # 전화 쪽과 같은 잠금을 씁니다. 안 그러면 지운 규칙이 되살아납니다.
        with wk.rules_lock():
            try:
                rules = wk.load_rules(strict=True)
            except wk.RulesUnreadable as e:
                print(f"규칙 파일을 읽지 못했습니다: {e}", file=sys.stderr)
                return 2
            keep = [r for r in rules if r.get("id") != rid]
            if len(keep) == len(rules):
                print(f"ID {rid} 를 찾지 못했습니다.")
                return 1
            wk.save_rules(keep)
        for p in wk.SPOOL.glob(f"wakeup-*-rep{rid}-*.call"):
            try:
                p.unlink()
            except OSError:
                pass
        print(f"규칙 {rid} 을 지웠습니다.")
        return 0

    if "--check" in args:
        # 필요한 조각 목록은 make-korean-sounds.py 의 targets() 가 유일한 출처입니다.
        # 여기서 따로 나열하면 조각을 추가·변경할 때마다 조용히 어긋납니다.
        import importlib.util
        ms = None
        for p in ["/usr/local/bin/make-korean-sounds.py",
                  os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "make-korean-sounds.py")]:
            if os.path.isfile(p):
                spec = importlib.util.spec_from_file_location("mks", p)
                ms = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(ms)
                break
        if ms is None:
            print("make-korean-sounds.py 를 찾지 못해 조각 검사를 건너뜁니다")
            return 0
        need = {b.name for b, _ in ms.targets()}
        have = {p.stem for p in wk.SOUNDS_DIR.glob("*.wav")}
        missing = sorted(need - have)
        extra = sorted(have - need)
        print(f"필요 {len(need)}개 / 있음 {len(have)}개")
        if missing:
            print(f"[!] 빠진 조각 {len(missing)}개: {missing}")
            print("    sudo TTS=openai ... make-korean-sounds.py 를 다시 실행하세요")
        else:
            print("빠진 조각 없음")
        if extra:
            print(f"(안 쓰는 파일 {len(extra)}개: {extra[:8]}{' ...' if len(extra) > 8 else ''})")
        return 1 if missing else 0

    dry = "--dry" in args
    now = datetime.now()
    wd = now.isoweekday()
    made = skipped = past = 0

    for r in rules:
        if wd not in r.get("days", []):
            continue
        target = now.replace(hour=r["hh"], minute=r["mm"], second=0, microsecond=0)
        if target <= now + timedelta(seconds=30):
            past += 1
            continue
        if already_made(r, target):
            skipped += 1
            continue
        if dry:
            print(f"  만들 예정: 내선 {r['ext']} {target:%H:%M} "
                  f"({wk.day_text(r['days'])})")
            made += 1
            continue
        try:
            p = wk.make_call_file(str(r["ext"]), target, tag=f"rep{r['id']}")
            wk.log(f"DAILY ext={r['ext']} rule={r['id']} at={target:%F %H:%M} "
                   f"file={p.name}")
            made += 1
        except OSError as e:
            wk.log(f"DAILY-FAIL rule={r['id']}: {e}")

    msg = (f"{now:%F} ({wk.DAY_TEXT[wd]}) 반복 규칙 {len(rules)}개 중 "
           f"오늘 해당 {made + skipped + past}개 -> "
           f"새로 만듦 {made}, 이미 있음 {skipped}, 시각 지남 {past}")
    print(msg)
    if not dry:
        wk.log("DAILY " + msg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
