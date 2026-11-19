#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成测试用 vCard 并 PUT 到 CardDAV 地址簿。

用途：为 SyncCalendar 的 CardDAV 联系人同步提供真实测试数据。
生成的联系人覆盖多种边界情况（中文名、西文名、无 FN、多电话、多邮箱、
带逗号分号换行的备注、item1. 分组前缀等），用来验证客户端的解析与回写。

用法：
    python make_contacts.py            # 生成并上传
    python make_contacts.py --dry-run  # 只打印，不上传
    python make_contacts.py --count 8  # 指定条数
"""
import base64
import random
import sys
import urllib.request
import urllib.error
import uuid

URL = os.environ.get("CARDDAV_URL", "https://your-nas/carddav/<user>/<addressbook-id>/")
USER = os.environ.get("CARDDAV_USER", "")
PWD = os.environ.get("CARDDAV_PASS", "")

AUTH = base64.b64encode(f"{USER}:{PWD}".encode()).decode()

# ── 固定样本：刻意覆盖各种格式差异，不随机，便于回归对比 ──
SAMPLES = [
    {
        "uid": "test-zhang-san-001",
        "fn": "张三",
        "n": "张;三;;;",
        "org": "渤海环境研究院",
        "title": "研究员",
        "tels": [("CELL", "13800138001")],
        "emails": [("WORK", "zhangsan@example.com")],
        "note": "主要负责近岸水质监测。",
        "desc": "纯中文名 + 单个手机 + 公司",
    },
    {
        "uid": "test-li-si-002",
        "fn": "李四",
        "n": "李;四;;;",
        "org": "海洋大学",
        "title": "",
        "tels": [("CELL", "13900139002"), ("WORK", "0532-88886666")],
        "emails": [("WORK", "lisi@ouc.edu.cn"), ("HOME", "lisi@qq.com")],
        "note": "两个电话两个邮箱，验证多值权威替换",
        "desc": "多电话 + 多邮箱",
    },
    {
        "uid": "test-john-smith-003",
        "fn": "John Smith",
        "n": "Smith;John;;;",
        "org": "Ocean Data Lab",
        "title": "Engineer",
        "tels": [("CELL", "+86 137 0013 7003")],
        "emails": [("WORK", "john.smith@example.org")],
        "note": "",
        "desc": "西文名，验证 joinName 用空格连接",
    },
    {
        "uid": "test-no-fn-004",
        # 🔴 实测：群晖不接受**没有 FN** 的 vCard（PUT 返回 500）。
        #    RFC 6350 里 FN 是必填（MUST），服务端拒收是对的。
        #    这里保留写 FN 但让 FN 与 N 的拼装结果不同，
        #    以验证客户端"FN 优先"的取值顺序。
        "fn": "王小明（FN优先）",
        "n": "王;小明;;;",
        "org": "验证 FN 与 N 的优先级",
        "title": "",
        "tels": [("CELL", "13600136004")],
        "emails": [],
        "note": "",
        "desc": "FN 优先于 N（无 FN 的卡片群晖会 500 拒收）",
    },
    {
        "uid": "test-special-chars-005",
        "fn": "赵六",
        "n": "赵;六;;;",
        "org": "含,逗号;分号的公司",
        "title": "",
        "tels": [("CELL", "13500135005")],
        "emails": [("WORK", "zhaoliu@example.com")],
        # 备注里有逗号、分号、换行 → 验证转义/反转义往返
        "note": "备注含逗号, 分号; 还有\n第二行内容",
        "desc": "特殊字符转义（逗号/分号/换行）",
    },
    {
        "uid": "test-item-group-006",
        "fn": "孙七",
        "n": "孙;七;;;",
        "org": "群晖风格分组",
        "title": "",
        "tels": [("CELL", "13300133006")],
        "emails": [],
        "note": "",
        "desc": "用 item1. 分组前缀（群晖导出常见）",
        "use_item_group": True,
    },
    {
        "uid": "test-long-note-007",
        "fn": "周八",
        "n": "周;八;;;",
        "org": "长文本折行测试",
        "title": "",
        "tels": [("CELL", "13200132007")],
        "emails": [],
        # 超过 75 字节，服务端/客户端都必须折行
        "note": "这是一段很长的备注，用来验证折行展开是否正确。"
                "如果客户端没有正确展开续行，那么这段文字会被解析成多个残片，"
                "从而在联系人详情里看到一堆断掉的片段。中文按三字节算，"
                "所以这段早就超过七十五字节了。",
        "desc": "超长备注，验证折行/展开",
    },
    {
        "uid": "test-minimal-008",
        "fn": "只有一个名字",
        "n": ";;;;".replace(";;;;", ";只有;一个名字;;"),
        "org": "",
        "title": "",
        "tels": [],
        "emails": [],
        "note": "",
        "desc": "只有名字，无电话无邮箱",
    },
]


def escape(v):
    """vCard 值转义"""
    return (v.replace("\\", "\\\\")
             .replace("\n", "\\n")
             .replace("\r", "")
             .replace(",", "\\,")
             .replace(";", "\\;"))


def fold(line, limit=75):
    """按字节折行，续行以单个空格开头"""
    b = line.encode("utf-8")
    if len(b) <= limit:
        return line
    out = []
    cur = b""
    first = True
    for ch in line:
        cb = ch.encode("utf-8")
        cap = limit if first else limit - 1
        if len(cur) + len(cb) > cap and cur:
            out.append(("" if first else " ") + cur.decode("utf-8"))
            cur = b""
            first = False
        cur += cb
    if cur:
        out.append(("" if first else " ") + cur.decode("utf-8"))
    return "\r\n".join(out)


def build(s):
    lines = ["BEGIN:VCARD", "VERSION:3.0", f"UID:{s['uid']}"]
    if s["fn"]:
        lines.append(f"FN:{escape(s['fn'])}")
    lines.append(f"N:{s['n']}")
    if s["org"]:
        lines.append(f"ORG:{escape(s['org'])}")
    if s["title"]:
        lines.append(f"TITLE:{escape(s['title'])}")
    for i, (t, v) in enumerate(s["tels"]):
        prefix = f"item{i+1}." if s.get("use_item_group") else ""
        if s.get("use_item_group"):
            lines.append(f"{prefix}TEL;TYPE={t}:{escape(v)}")
            lines.append(f"{prefix}X-ABLabel:_$!<{t}>!$_")
        else:
            lines.append(f"TEL;TYPE={t}:{escape(v)}")
    for t, v in s["emails"]:
        lines.append(f"EMAIL;TYPE={t};TYPE=INTERNET:{escape(v)}")
    if s["note"]:
        lines.append(f"NOTE:{escape(s['note'])}")
    lines.append("REV:2026-11-11T00:30:00Z")
    lines.append("END:VCARD")
    return "\r\n".join(fold(l) for l in lines)


def put(uid, body):
    u = URL + uid + ".vcf"
    data = body.encode("utf-8")
    req = urllib.request.Request(u, data=data, method="PUT")
    req.add_header("Authorization", "Basic " + AUTH)
    req.add_header("Content-Type", "text/vcard; charset=utf-8")
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return r.status, r.headers.get("ETag", "")
    except urllib.error.HTTPError as e:
        return e.code, (e.read()[:200].decode("utf-8", "replace"))


def main():
    dry = "--dry-run" in sys.argv
    n = len(SAMPLES)
    if "--count" in sys.argv:
        n = int(sys.argv[sys.argv.index("--count") + 1])

    todo = SAMPLES[:n]
    print(f"准备写入 {len(todo)} 位联系人 → {URL}\n")
    ok = 0
    for s in todo:
        body = build(s)
        if dry:
            print(f"--- {s['uid']}  ({s['desc']}) ---")
            print(body)
            print()
            continue
        code, etag = put(s["uid"], body)
        mark = "✅" if code in (201, 204) else "❌"
        print(f"{mark} {code}  {s['fn'] or s['uid']:20} {etag[:20]:22} {s['desc']}")
        if code in (201, 204):
            ok += 1
    if not dry:
        print(f"\n成功 {ok}/{len(todo)}")


if __name__ == "__main__":
    main()