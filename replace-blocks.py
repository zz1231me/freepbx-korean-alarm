#!/usr/bin/env python3
"""extensions_custom.conf 의 알림전화 부분을 통째로 갈아끼웁니다.

    replace-blocks.py <대상.conf> <새내용.conf>

두 가지 방법으로 옛것을 걷어냅니다.
  1) ';;; ===== WAKEUP-KOREAN BEGIN ... END' 표시 구간이 있으면 그 구간을 통째로.
     (예전 판에는 이 표시가 없어서 헤더 주석이 매번 쌓였습니다)
  2) 표시가 없으면 알려진 컨텍스트 이름으로 지웁니다.

#include / #exec 은 컨텍스트가 아니라 파일 전체에 걸리는 지시자입니다.
지워지는 구간 안에 있으면 같이 지우고(원래 우리 것이므로), 밖에 있으면 남깁니다.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

BEGIN = ";;; ===== WAKEUP-KOREAN BEGIN"
END = ";;; ===== WAKEUP-KOREAN END"
DROP = {"wakeup-book", "wakeup-call", "wakeup-cancel", "wakeup-list",
        "wk-time", "wk-after", "wk-rep", "wk-lib"}


def strip_marked(lines: list[str]) -> tuple[list[str], int]:
    out, n, inside = [], 0, False
    for ln in lines:
        if ln.startswith(BEGIN):
            inside = True
            n += 1
            continue
        if ln.startswith(END):
            inside = False
            continue
        if not inside:
            out.append(ln)
    return out, n


def strip_contexts(lines: list[str]) -> tuple[list[str], list[str]]:
    out, cur, removed = [], None, []
    for ln in lines:
        m = re.match(r"\s*\[([^\]]+)\]", ln)
        if m:
            cur = m.group(1).strip()
            if cur in DROP:
                removed.append(cur)
        if cur in DROP:
            continue
        if ln.lstrip().startswith("#"):   # 우리 구간 밖의 #include 는 남긴다
            out.append(ln)
            continue
        out.append(ln)
    return out, removed


def main() -> int:
    if len(sys.argv) < 3:
        print("사용법: replace-blocks.py <대상.conf> <새내용.conf>", file=sys.stderr)
        return 2
    conf, new = Path(sys.argv[1]), Path(sys.argv[2])
    if not new.is_file():
        print(f"새 내용 파일이 없습니다: {new}", file=sys.stderr)
        return 2
    if not conf.exists():
        conf.write_text("", encoding="utf-8")

    lines = conf.read_text(encoding="utf-8").splitlines(keepends=True)
    lines, marked = strip_marked(lines)
    lines, removed = strip_contexts(lines)

    body = new.read_text(encoding="utf-8")
    conf.write_text("".join(lines).rstrip() + "\n\n" + body, encoding="utf-8")

    if marked:
        print(f"  옛 알림전화 구간 {marked}개를 걷어냈습니다")
    if removed:
        print(f"  옛 컨텍스트 제거: {', '.join(sorted(set(removed)))}")
    if not marked and not removed:
        print("  지울 옛것 없음 (처음 설치)")
    added = sorted(set(re.findall(r"^\[([^\]]+)\]", body, re.M)))
    print(f"  넣은 컨텍스트 {len(added)}개: {', '.join(added)}")

    # 다른 파일에 남아 있는 옛 진입점을 알려 줍니다 (지우지는 않습니다)
    stale = []
    for other in conf.parent.glob("extensions*.conf"):
        if other == conf:
            continue
        try:
            txt = other.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for ctx in ("wakeup-cancel", "wakeup-book", "wakeup-list"):
            for m in re.finditer(rf"^\s*exten\s*=>.*{ctx}.*$", txt, re.M):
                stale.append(f"{other.name}: {m.group(0).strip()}")
    if stale:
        print("\n  [!] 다른 파일에 옛 진입점이 남아 있습니다. 직접 확인하세요:")
        for s in stale[:10]:
            print("      " + s)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:      # head 등으로 잘라 볼 때
        sys.exit(0)
