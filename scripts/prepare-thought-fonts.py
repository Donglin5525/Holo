#!/usr/bin/env python3
"""从官方源字库生成随包字体：保留简繁常用字，缺字由系统按字形回退。

用法：python3 scripts/prepare-thought-fonts.py /path/to/official-font-downloads
目录需含 serif-vf.ttf、hand-regular.ttf、hand-medium.ttf 与两份 *-OFL.txt。
需要 fontTools；源文件与许可来源见输出目录 SOURCES.json。
"""
from pathlib import Path
import hashlib
import json
import sys
from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

root = Path(__file__).resolve().parents[1]
source = Path(sys.argv[1])
destination = root / 'Holo/Holo APP/Holo/Holo/Resources/ThoughtFonts'
destination.mkdir(parents=True, exist_ok=True)

# 不按示例文章裁字；保留简体 GB2312 与繁体 Big5 常用字一级区。
characters = set(range(0x20, 0x250)) | set(range(0x2000, 0x2100))
characters |= set(range(0x3000, 0x3100)) | set(range(0xFF00, 0xFFF0))
for lead in range(0xA1, 0xF8):
    for trail in range(0xA1, 0xFF):
        try:
            characters.update(map(ord, bytes([lead, trail]).decode('gb2312')))
        except UnicodeDecodeError:
            pass
for code in range(0xA440, 0xC67F):
    try:
        characters.update(map(ord, code.to_bytes(2, 'big').decode('big5')))
    except UnicodeDecodeError:
        pass

specs = [
    ('serif-vf.ttf', 'HoloNoteSerif', 'Regular', 400),
    ('serif-vf.ttf', 'HoloNoteSerif', 'Bold', 700),
    ('hand-regular.ttf', 'HoloNoteHand', 'Regular', None),
    ('hand-medium.ttf', 'HoloNoteHand', 'Bold', None),
]
results = []
for filename, family, weight, axis in specs:
    font = TTFont(source / filename)
    if axis is not None:
        font = instantiateVariableFont(font, {'wght': axis}, inplace=True)
    options = subset.Options()
    options.name_IDs = ['*']
    options.name_legacy = True
    options.name_languages = ['*']
    options.layout_features = ['*']
    options.notdef_outline = True
    processor = subset.Subsetter(options=options)
    processor.populate(unicodes=characters)
    processor.subset(font)
    postscript = family + '-' + weight
    # 子集版本更换主字体名；上游版权与许可字段仍保留。
    values = {1: family, 2: weight, 3: postscript+'-Holo-1', 4: family+' '+weight,
              6: postscript, 16: family, 17: weight, 18: family+' '+weight}
    for record in font['name'].names:
        if record.nameID in values:
            record.string = values[record.nameID].encode(record.getEncoding(), errors='replace')
    for key, value in values.items():
        font['name'].setName(value, key, 3, 1, 0x409)
    font['OS/2'].usWeightClass = 700 if weight == 'Bold' else 400
    font['OS/2'].fsSelection &= ~(1 << 6)
    if weight == 'Bold':
        font['OS/2'].fsSelection |= 1 << 5
        font['head'].macStyle |= 1
    else:
        font['OS/2'].fsSelection = (font['OS/2'].fsSelection & ~(1 << 5)) | (1 << 6)
        font['head'].macStyle &= ~1
    output = destination / (postscript+'.ttf')
    font.save(output)
    results.append({'file': output.name, 'glyphs':len(font.getBestCmap()),
                    'bytes':output.stat().st_size,
                    'sha256':hashlib.sha256(output.read_bytes()).hexdigest()})

for prefix in ('serif', 'hand'):
    (destination / (prefix+'-OFL.txt')).write_bytes((source / (prefix+'-OFL.txt')).read_bytes())
manifest = {
    'license': 'SIL Open Font License 1.1; modified subset names HoloNoteSerif / HoloNoteHand',
    'serif': 'https://github.com/google/fonts/tree/main/ofl/notoserifsc',
    'hand': 'https://github.com/lxgw/LxgwWenKai-Lite',
    'sourceSHA256': {name:hashlib.sha256((source/name).read_bytes()).hexdigest()
                     for name in ('serif-vf.ttf','hand-regular.ttf','hand-medium.ttf')},
    'coverage': 'GB2312 + Big5 frequent ideographs + Latin/punctuation; system glyph fallback for other text',
    'fonts':results,
}
(destination/'SOURCES.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
print(json.dumps(results,indent=2))
