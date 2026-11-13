"""读取 TextractorCLI 的输出，挑出游戏正文那条文本线程，发到 GalTranslator 的字幕窗。

用法: TextractorCLI.exe ... | python3 textractor_bridge.py <GalTranslator 地址> <源语言>

TextractorCLI 每句输出一行：
    [句柄:进程号:地址:上下文:上下文2:钩子名:钩子代码] 文本
同一个游戏会有很多条线程（界面、系统、重复绘制……），正文线程通常是
出现日文最多的那条，这里按出现次数挑选。
"""
import collections
import json
import re
import sys
import urllib.request

URL, LANG = sys.argv[1], sys.argv[2]
JP = re.compile(r"[぀-ヿ一-鿿]")
LINE = re.compile(r"^\[([^\]]*)\]\s?(.*)$")
SKIP = {"Console", "Clipboard"}


def lines():
    """TextractorCLI 可能输出 UTF-16LE，也可能是多字节编码，自动判断。"""
    buf = sys.stdin.buffer
    head = buf.peek(256)[:256]
    if head.count(b"\x00") > len(head) // 4:
        acc = bytearray()
        while True:
            two = buf.read(2)
            if len(two) < 2:
                break
            if two == b"\n\x00":
                yield acc.decode("utf-16-le", "replace").rstrip("\r")
                acc.clear()
            else:
                acc += two
        return
    for raw in buf:
        for enc in ("utf-8", "cp932"):
            try:
                yield raw.decode(enc).rstrip("\r\n")
                break
            except UnicodeDecodeError:
                continue
        else:
            yield raw.decode("utf-8", "replace").rstrip("\r\n")


def post(text):
    body = json.dumps({"text": text, "from": LANG}).encode("utf-8")
    req = urllib.request.Request(
        URL + "/overlay", data=body, headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=120).read()
    except Exception as e:  # 翻译失败不影响游戏
        print("发送失败:", e, file=sys.stderr, flush=True)


def main():
    score = collections.Counter()
    for line in lines():
        m = LINE.match(line)
        if not m:
            print(line, file=sys.stderr, flush=True)  # CLI 自己的提示信息
            continue
        ctx, text = m.group(1), m.group(2).strip()
        parts = ctx.split(":")
        name = parts[5] if len(parts) > 5 else ""
        if name in SKIP or not text or not JP.search(text) or len(text) > 500:
            continue
        key = ":".join(parts[2:])  # 去掉句柄和进程号，按钩子位置区分线程
        score[key] += 1
        best = score.most_common(1)[0][0]
        if key == best and score[key] >= 2:
            post(text)


if __name__ == "__main__":
    main()
