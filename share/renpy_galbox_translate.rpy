# GalBox 机翻：把对白和选项送到本机 GalTranslator 翻译。
# 由 gal translate <名字> on 生成，gal translate <名字> off 会删除本文件和字体。
# 兼容 Ren'Py 6/7（Python 2）和 Ren'Py 8（Python 3）。

init 999 python:
    try:
        from urllib.request import urlopen as _gb_urlopen
        from urllib.parse import quote as _gb_quote
    except ImportError:
        from urllib2 import urlopen as _gb_urlopen
        from urllib import quote as _gb_quote

    _gb_cache = {}

    def _gb_translate(s):
        if not s or not s.strip():
            return s
        if s in _gb_cache:
            return _gb_cache[s]
        try:
            raw = s if isinstance(s, bytes) else s.encode("utf-8")
            u = "@URL@/translate?from=@FROM@&to=zh-CN&text=" + _gb_quote(raw)
            r = _gb_urlopen(u, timeout=90).read().decode("utf-8")
        except Exception:
            # 翻译服务不可用时显示原文，不影响游戏
            return s
        _gb_cache[s] = r
        return r

    _gb_prev_filter = config.say_menu_text_filter

    def _gb_filter(s):
        if _gb_prev_filter is not None:
            s = _gb_prev_filter(s)
        return _gb_translate(s)

    config.say_menu_text_filter = _gb_filter

    # 原字体多半没有简体中文字形，全部替换成游戏目录里的 galbox_cjk.ttc
    _gb_font = "0@galbox_cjk.ttc"
    _gb_fonts = set(["DejaVuSans.ttf", "DejaVuSans-Bold.ttf", "SourceHanSansLite.ttf"])
    for _gb_f in renpy.list_files():
        if _gb_f.lower().endswith((".ttf", ".otf", ".ttc")) and "galbox_cjk" not in _gb_f:
            _gb_fonts.add(_gb_f)
    for _gb_f in _gb_fonts:
        for _gb_b in (False, True):
            for _gb_i in (False, True):
                config.font_replacement_map[(_gb_f, _gb_b, _gb_i)] = (_gb_font, _gb_b, _gb_i)
