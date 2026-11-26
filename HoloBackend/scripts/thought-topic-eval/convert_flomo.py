#!/usr/bin/env python3
# flomo 导出包 → 想法主题归类评测数据集（中间格式见本目录 README.md）。
#
# 用法（路径作参数传入；不要在解压目录里运行）：
#   python3 -I convert_flomo.py --raw-dir <含 flomo-*/notes.html 的目录> --out <数据集.json>
#           --name 数据集名 [--topics category|tag]
#
# 四条处理规则：
#   1. 标签就是分类：每个标签对应一个主题，笔记的标签就是它的现状归属与正确答案。
#   2. 正文里的 #标签 从正文删掉——标签是答案，不能留在题面里。
#   3. 按创建时间排序，最近三分之一记为 holdout，其余为 dev；没有标签或删掉标签后没有正文的
#      笔记只当语料（参与召回、当代表例），不参与评测。
#   4. 标签识别不看前面有没有空格：中文笔记里标签常紧贴正文（「……吧#Think/碎碎念」）。
#
# --topics category（默认）：标签树归并到「类别层」——去掉纯命名空间的根（think / area），
#   二级标签各成一个归档类别，更深的标签并入它的二级父标签。目录规模接近 Holo 里的真实分类设置。
# --topics tag：每个实际用过的标签各成一个主题，层级双向继承（打了 a/b/c 的笔记同时属于
#   a/b/c、a/b）。用来对照「分类很多」时的表现。

import argparse
import hashlib
import json
import re
import uuid
from collections import Counter
from datetime import datetime
from html.parser import HTMLParser
from pathlib import Path

MEMO = re.compile(r'<div class="time">(.*?)</div>\s*<div class="content">(.*?)</div>\s*<div class="files">', re.S)
# 标签 = # 后面到空白为止的一串；网址锚点（/#）与实体（&#）不算
TAG_TOKEN = re.compile(r"(?<![/&#])#([^\s#]+)")
# 只起归类作用、自身没有含义的根标签，不作为主题
NAMESPACE_ROOTS = {"think", "area"}


class NoteText(HTMLParser):
    """正文 HTML → 纯文本。

    导出文件在块级标签之间夹着排版用的空白，块级标签的边界才是真边界；
    列表可能嵌在没闭合的段落里、也可能多层嵌套，所以按「容器栈」攒：
    最底层放段落（段落之间空一行），列表里的各项之间只换行，嵌套列表缩进四格。
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        # 每层容器 = [说明, 行列表]；说明：None=最底层 / 列表 / {"marker": 列表项前缀}
        self.stack = [[None, []]]
        self.buffer = []

    def flush(self):
        text = "".join(self.buffer).strip()
        self.buffer = []
        if text:
            self.stack[-1][1].append(text)

    def close_item(self):
        kind, lines = self.stack.pop()
        if lines:
            self.stack[-1][1].append(kind["marker"] + "\n".join(lines))

    def close_list(self):
        kind, lines = self.stack.pop()
        if not lines:
            return
        body = "\n".join(lines)
        if isinstance(self.stack[-1][0], dict):  # 嵌在列表项里
            body = "\n".join("    " + line for line in body.split("\n"))
        self.stack[-1][1].append(body)

    def handle_starttag(self, tag, attrs):
        if tag == "br":
            self.buffer.append("\n")
        elif tag in ("ul", "ol"):
            self.flush()
            self.stack.append([{"ordered": tag == "ol", "count": 0}, []])
        elif tag == "li":
            # 上一个列表项没闭合就直接开了下一项：先把它收掉
            self.flush()
            if isinstance(self.stack[-1][0], dict) and "marker" in self.stack[-1][0]:
                self.close_item()
            frame = next((layer[0] for layer in reversed(self.stack) if isinstance(layer[0], dict) and "ordered" in layer[0]), None)
            marker = "- "
            if frame is not None:
                frame["count"] += 1
                marker = "%d. " % frame["count"] if frame["ordered"] else "- "
            self.stack.append([{"marker": marker}, []])
        elif tag in ("p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"):
            self.flush()

    def handle_endtag(self, tag):
        if tag == "li":
            self.flush()
            if isinstance(self.stack[-1][0], dict) and "marker" in self.stack[-1][0]:
                self.close_item()
        elif tag in ("ul", "ol"):
            self.flush()
            if isinstance(self.stack[-1][0], dict) and "ordered" in self.stack[-1][0]:
                self.close_list()
        elif tag in ("p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre"):
            self.flush()

    def handle_data(self, data):
        self.buffer.append(data)

    def result(self):
        self.flush()
        while len(self.stack) > 1:
            self.close_item() if "marker" in self.stack[-1][0] else self.close_list()
        return tidy("\n\n".join(self.stack[0][1]))


def tidy(text):
    text = re.sub(r"[ \t]+\n", "\n", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def to_text(content_html):
    parser = NoteText()
    parser.feed(content_html)
    return parser.result()


def tag_stripper(tags):
    """只删数据里确实出现过的标签写法，正文里别的 # 不受影响。"""
    alternatives = "|".join(re.escape(tag) for tag in sorted(tags, key=len, reverse=True))
    pattern = re.compile(r"(?<![/&#])#(?:%s)(?=\s|$)" % alternatives, re.I)
    return lambda text: tidy(pattern.sub("", text))


def memberships(tags, granularity):
    """一条笔记属于哪些主题（入参是小写标签）。
    category：归并到二级；tag：逐级向上继承；none：不带任何标签（交给 Holo 自己整理）。"""
    if granularity == "none":
        return set()
    keys = set()
    for tag in tags:
        parts = tag.split("/")
        if granularity == "category":
            keys.add("/".join(parts[:2]))
        else:
            keys.update("/".join(parts[:depth]) for depth in range(1, len(parts) + 1))
    return keys - NAMESPACE_ROOTS


def stable_uuid(*parts):
    """由内容稳定推导 UUID：同一份数据重跑得到同一批 id（现状落库按 UUID 字母序截断，id 必须可复现）。"""
    digest = bytearray(hashlib.sha256("\u0000".join(parts).encode("utf-8")).digest()[:16])
    digest[6] = (digest[6] & 0x0F) | 0x40
    digest[8] = (digest[8] & 0x3F) | 0x80
    return str(uuid.UUID(bytes=bytes(digest)))


def iso_time(text):
    return datetime.strptime(text, "%Y-%m-%d %H:%M:%S").strftime("%Y-%m-%dT%H:%M:%S+08:00")


def load_notes(raw_dir):
    """读全部导出包；包与包之间有重复笔记，按「时间 + 去空白正文」去重。"""
    notes, seen = [], set()
    for path in sorted(raw_dir.glob("flomo-*/notes.html")):
        _, _, body = path.read_text(encoding="utf-8").partition('<div class="memos">')
        for time_text, content_html in MEMO.findall(body):
            text = to_text(content_html)
            key = (time_text.strip(), re.sub(r"\s+", "", text))
            if key in seen:
                continue
            seen.add(key)
            # 同一个标签有 think / Think 两种写法：归属按小写算，标题取最常见的原写法
            raw_tags = [m.group(1) for m in TAG_TOKEN.finditer(text)]
            by_key = {}
            for raw in raw_tags:
                by_key.setdefault(raw.lower(), Counter())[raw] += 1
            notes.append({
                "time": time_text.strip(),
                "text": text,
                "spellings": by_key,
            })
    notes.sort(key=lambda note: note["time"])
    return notes


def selftest():
    """转换逻辑自查（零数据、零网络）：python3 -I convert_flomo.py --selftest"""
    cases = [
        ("段落之间的排版空白不算内容", "<p>A</p>\n      <p>B</p>", "A\n\nB"),
        ("软换行保留", "<p>A<br>B</p>", "A\nB"),
        ("列表嵌在没闭合的段落里", "<p>intro<ul>\n        <li>x</li>\n        <li>y</li>\n      </ul>", "intro\n\n- x\n- y"),
        ("多层嵌套列表", "<ol><li><p>a</p><ol><li><p>a1</p></li></ol></li><li><p>b</p></li></ol>", "1. a\n    1. a1\n2. b"),
        ("列表项没闭合", "<ul><li>a<li>b</ul>", "- a\n- b"),
        ("实体与行内样式只留文字", "<p>x &amp; y <strong>z</strong></p>", "x & y z"),
    ]
    strip = tag_stripper(["think/碎碎念"])
    cases += [
        ("标签紧贴正文也被删掉", "……吧#Think/碎碎念", "……吧"),
        ("标签在开头", "#Think/碎碎念\n\n正文", "正文"),
        ("不是标签的 # 保留", "C# 语言 https://a.b/#x", "C# 语言 https://a.b/#x"),
    ]
    for name, source, expected in cases:
        actual = strip(source) if "标签" in name or "#" in source else to_text(source)
        assert actual == expected, "%s：\n得到 %r\n期望 %r" % (name, actual, expected)
        print("✓ %s" % name)
    assert memberships(["think/读书如抽丝/阿米巴经营", "健身", "think"], "category") == {"think/读书如抽丝", "健身"}
    assert memberships(["think/a/b"], "tag") == {"think/a/b", "think/a"}
    print("✓ 主题归属：归并到二级 / 逐级继承；命名空间根不成主题")
    print("转换自查通过 %d 项" % (len(cases) + 1))


def main():
    parser = argparse.ArgumentParser(description="flomo 导出包 → 想法主题归类评测数据集")
    parser.add_argument("--raw-dir")
    parser.add_argument("--out")
    parser.add_argument("--name")
    parser.add_argument("--topics", choices=["category", "tag", "none"], default="category")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.selftest:
        selftest()
        return
    if not (args.raw_dir and args.out and args.name):
        parser.error("需要 --raw-dir、--out、--name")

    notes = load_notes(Path(args.raw_dir))
    strip_tags = tag_stripper({key for note in notes for key in note["spellings"]})
    for note in notes:
        note["topics"] = memberships(note["spellings"], args.topics)
        note["plain"] = strip_tags(note["text"])
    # 删掉标签后没有正文的（纯图片 / 语音笔记）没法参与文本评测，整条不进数据集
    dropped_empty = sum(1 for note in notes if not note["plain"])
    notes = [note for note in notes if note["plain"]]

    # 主题显示名：直接打过的，取最常见的原写法；只作为上级出现的，就用小写标签本身
    spellings_by_topic = {}
    for note in notes:
        for key, spellings in note["spellings"].items():
            shown = spellings.most_common(1)[0][0]
            if args.topics == "category" and len(shown.split("/")) >= 2:
                shown = "/".join(shown.split("/")[:2])
            spellings_by_topic.setdefault(shown.lower(), Counter()).update({shown: spellings.total()})

    def title_of(key):
        return spellings_by_topic.get(key, Counter({key: 1})).most_common(1)[0][0]

    # 主题目录：出现过的每个主题 → 最早一条成员笔记的时间
    catalog = {}
    for note in notes:
        for key in note["topics"]:
            catalog[key] = min(catalog.get(key, note["time"]), note["time"])

    # 可评测 = 有主题归属 + 删掉标签后还有正文；按时间取最近三分之一作 holdout
    evaluable = [note for note in notes if note["topics"] and note["plain"]]
    holdout_from = len(evaluable) - len(evaluable) // 3
    split_at = evaluable[holdout_from]["time"] if holdout_from < len(evaluable) else None

    topics = [
        {"id": stable_uuid("flomo-topic", key), "title": title_of(key), "status": "classification", "createdAt": iso_time(created)}
        for key, created in sorted(catalog.items())
    ]
    thoughts = []
    for note in notes:
        topic_ids = [stable_uuid("flomo-topic", key) for key in sorted(note["topics"])]
        labelled = bool(note["topics"] and note["plain"])
        split = None
        if labelled:
            split = "holdout" if split_at is not None and note["time"] >= split_at else "dev"
        thoughts.append({
            "id": stable_uuid("flomo-note", note["time"], re.sub(r"\s+", "", note["text"])),
            "text": note["plain"],
            "createdAt": iso_time(note["time"]),
            # 现状归属照写：别的笔记评测时，这条是各主题的成员（当代表例、算成员数）
            "links": [{"topicId": topic_id, "source": "user", "state": "active"} for topic_id in topic_ids],
            "split": split,
            "gold": {"topicIds": topic_ids, "unsure": False} if labelled else None,
            "flomo": {"tags": sorted(note["topics"])},
        })

    dataset = {"formatVersion": 1, "name": args.name, "topics": topics, "thoughts": thoughts}
    Path(args.out).write_text(json.dumps(dataset, ensure_ascii=False, indent=1), encoding="utf-8")

    member_count = {title_of(key): sum(1 for note in notes if key in note["topics"]) for key in catalog}
    splits = {name: sum(1 for thought in thoughts if thought["split"] == name) for name in ("dev", "holdout")}
    print("数据集 %s（口径 %s）已写出" % (args.name, args.topics))
    print("  笔记 %d 条（去重后）| 主题 %d 个" % (len(thoughts), len(topics)))
    if args.topics == "none":
        print("  无标签模式：全部 %d 条只当原文语料，不设主题、不带答案（交给 Holo 自己整理）" % len(thoughts))
    else:
        print("  可评测 %d 条：dev %d / holdout %d（holdout 从 %s 起）" % (sum(splits.values()), splits["dev"], splits["holdout"], split_at or "无"))
    print("  只当语料 %d 条（有标签但只剩标签本身等，不打正确答案: %d；无有效标签: %d）" % (
        len(thoughts) - sum(splits.values()),
        sum(1 for thought in thoughts if thought["flomo"]["tags"] and thought["gold"] is None),
        sum(1 for thought in thoughts if not thought["flomo"]["tags"])))
    print("  另有 %d 条删掉标签后没有正文（纯图片 / 语音），未进数据集" % dropped_empty)
    leftovers = Counter(token[:20] for thought in thoughts for token in re.findall(r"(?<![/&#])#[^\s#]+", thought["text"]))
    print("  正文里还留着的 # 开头的词: %s" % (dict(leftovers) if leftovers else "无"))
    print("  主题按成员数（每次送判最多取前 9 个）：")
    for title, count in sorted(member_count.items(), key=lambda item: (-item[1], item[0])):
        print("   %4d  %s" % (count, title[:30]))


if __name__ == "__main__":
    main()
