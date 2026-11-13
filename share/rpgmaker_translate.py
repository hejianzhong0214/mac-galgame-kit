"""RPG Maker MV/MZ 整包机翻。

用法: python3 rpgmaker_translate.py on|off <游戏目录> <源语言> <GalTranslator 地址>

on : 第一次运行时把 data 目录备份到 data_galbox_original，然后从备份读取原文，
     把对白、选项、名字、物品说明、系统用语等送到 GalTranslator 批量翻译，写回 data。
off: 用备份恢复 data，删除备份。
"""
import json
import os
import re
import shutil
import sys
import urllib.request

BACKUP_NAME = "data_galbox_original"
WORTH = re.compile(r"[぀-ヿ㐀-鿿A-Za-z]")

# 数据库文件里需要翻译的字段
DB_FIELDS = {
    "Actors.json": ["name", "nickname", "profile"],
    "Classes.json": ["name"],
    "Skills.json": ["name", "description", "message1", "message2"],
    "Items.json": ["name", "description"],
    "Weapons.json": ["name", "description"],
    "Armors.json": ["name", "description"],
    "Enemies.json": ["name"],
    "States.json": ["name", "message1", "message2", "message3", "message4"],
}


def find_data(game):
    for d in ("www/data", "data"):
        p = os.path.join(game, d)
        if os.path.isfile(os.path.join(p, "System.json")):
            return p
    sys.exit("找不到 data/System.json，这不是 RPG Maker MV/MZ 游戏")


def worth(s):
    return isinstance(s, str) and s.strip() and WORTH.search(s)


class Pass:
    """第一遍收集原文（collect=True），第二遍用译文替换。"""

    def __init__(self, table=None):
        self.collect = table is None
        self.table = table or {}
        self.texts = []
        self.seen = set()

    def t(self, s):
        if not worth(s):
            return s
        if self.collect:
            if s not in self.seen:
                self.seen.add(s)
                self.texts.append(s)
            return s
        return self.table.get(s, s)

    def lines(self, lines):
        """连续的对白行合成一段翻译，再按原行数拆回去。"""
        block = "\n".join(lines)
        out = self.t(block)
        if self.collect:
            return lines
        parts = out.split("\n")
        n = len(lines)
        if len(parts) > n:
            parts = parts[: n - 1] + ["".join(parts[n - 1:])]
        parts += [""] * (n - len(parts))
        return parts

    def event_list(self, cmds):
        if not isinstance(cmds, list):
            return
        i = 0
        while i < len(cmds):
            c = cmds[i]
            code = c.get("code")
            p = c.get("parameters", [])
            if code in (401, 405):
                j = i
                while j < len(cmds) and cmds[j].get("code") == code:
                    j += 1
                lines = [cmds[k]["parameters"][0] for k in range(i, j)]
                new = self.lines(lines)
                for k, line in zip(range(i, j), new):
                    cmds[k]["parameters"][0] = line
                i = j
                continue
            if code == 102 and p and isinstance(p[0], list):
                p[0] = [self.t(x) for x in p[0]]
            elif code == 402 and len(p) > 1:
                p[1] = self.t(p[1])
            elif code == 101 and len(p) > 4:
                p[4] = self.t(p[4])  # MZ 的说话人名字
            elif code in (320, 324, 325) and len(p) > 1:
                p[1] = self.t(p[1])
            i += 1

    def file(self, name, data):
        if name.startswith("Map") and name[3:6].isdigit():
            if isinstance(data.get("displayName"), str):
                data["displayName"] = self.t(data["displayName"])
            for ev in data.get("events") or []:
                for page in (ev or {}).get("pages") or []:
                    self.event_list(page.get("list"))
        elif name == "CommonEvents.json":
            for ev in data:
                if ev:
                    self.event_list(ev.get("list"))
        elif name == "Troops.json":
            for tr in data:
                for page in (tr or {}).get("pages") or []:
                    self.event_list(page.get("list"))
        elif name in DB_FIELDS:
            for row in data:
                if not row:
                    continue
                for k in DB_FIELDS[name]:
                    if isinstance(row.get(k), str):
                        row[k] = self.t(row[k])
        elif name == "System.json":
            for k in ("gameTitle", "currencyUnit"):
                if isinstance(data.get(k), str):
                    data[k] = self.t(data[k])
            for k in ("elements", "skillTypes", "weaponTypes", "armorTypes", "equipTypes"):
                if isinstance(data.get(k), list):
                    data[k] = [self.t(x) for x in data[k]]
            terms = data.get("terms") or {}
            for k in ("basic", "commands", "params"):
                if isinstance(terms.get(k), list):
                    terms[k] = [self.t(x) if x else x for x in terms[k]]
            if isinstance(terms.get("messages"), dict):
                for k, v in terms["messages"].items():
                    terms["messages"][k] = self.t(v)


def translate_all(texts, src, url):
    table = {}
    step = 120
    for start in range(0, len(texts), step):
        chunk = texts[start:start + step]
        body = json.dumps({"from": src, "to": "zh-CN", "texts": chunk}).encode("utf-8")
        req = urllib.request.Request(
            url + "/batch", data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as r:
            res = json.loads(r.read().decode("utf-8"))["translations"]
        table.update(zip(chunk, res))
        print("已翻译 %d / %d" % (min(start + step, len(texts)), len(texts)), flush=True)
    return table


def load(path):
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def main():
    act, game, src, url = sys.argv[1:5]
    data = find_data(game)
    backup = os.path.join(os.path.dirname(data), BACKUP_NAME)

    if act == "off":
        if not os.path.isdir(backup):
            print("没有备份，data 目录没有被改过")
            return
        for f in os.listdir(backup):
            shutil.copy2(os.path.join(backup, f), os.path.join(data, f))
        shutil.rmtree(backup)
        print("已恢复原始 data")
        return

    if not os.path.isdir(backup):
        shutil.copytree(data, backup)
        print("已备份原始 data 到", backup)

    names = sorted(f for f in os.listdir(backup) if f.endswith(".json"))
    collector = Pass()
    for n in names:
        collector.file(n, load(os.path.join(backup, n)))
    print("共 %d 条不同的文本需要翻译" % len(collector.texts), flush=True)

    table = translate_all(collector.texts, src, url)

    writer = Pass(table)
    for n in names:
        d = load(os.path.join(backup, n))
        writer.file(n, d)
        with open(os.path.join(data, n), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, separators=(",", ":"))
    print("已写入译文。关闭机翻会恢复原文")


if __name__ == "__main__":
    main()
