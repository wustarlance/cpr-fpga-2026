#!/usr/bin/env python3
"""Build editable vector cards, compatible BMPs and a regular-file SD image.

This tool never opens physical drives. The .img is an ordinary output file.
"""
import argparse
import hashlib
import html
import json
import struct
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

PROJECT=Path(__file__).resolve().parents[1]
BG='#102030'; PANEL='#142b3b'; INK='#f3f7fa'; MUTED='#b6c9d5'; ACCENT='#58e0bc'; EDGE='#284859'


class Card:
    def __init__(self,font_path):
        self.scale=3
        self.image=Image.new('RGB',(1056,1200),BG)
        self.draw=ImageDraw.Draw(self.image)
        self.font_path=font_path
        self.svg=[f'<svg xmlns="http://www.w3.org/2000/svg" width="1056" height="1200" viewBox="0 0 352 400"><rect width="352" height="400" fill="{BG}"/>']
    def box(self,xy,fill=PANEL,outline=None,r=0):
        x,y,w,h=xy; s=self.scale
        self.draw.rounded_rectangle((x*s,y*s,(x+w)*s,(y+h)*s),radius=r*s,fill=fill,outline=outline,width=s)
        self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{outline or "none"}"/>')
    def line(self,points,fill=ACCENT,width=2):
        self.draw.line([(int(x*self.scale),int(y*self.scale)) for x,y in points],fill=fill,width=width*self.scale,joint='curve')
        self.svg.append('<polyline points="'+' '.join(f'{x},{y}' for x,y in points)+f'" fill="none" stroke="{fill}" stroke-width="{width}" stroke-linejoin="round" stroke-linecap="round"/>')
    def ellipse(self,xy,fill=ACCENT,outline=None):
        x,y,w,h=xy;s=self.scale
        self.draw.ellipse((x*s,y*s,(x+w)*s,(y+h)*s),fill=fill,outline=outline,width=s)
        self.svg.append(f'<ellipse cx="{x+w/2}" cy="{y+h/2}" rx="{w/2}" ry="{h/2}" fill="{fill}" stroke="{outline or "none"}"/>')
    def polygon(self,points,fill,outline=None):
        self.draw.polygon([(int(x*self.scale),int(y*self.scale)) for x,y in points],fill=fill)
        if outline:self.line(points+[points[0]],outline,1)
        self.svg.append('<polygon points="'+' '.join(f'{x},{y}' for x,y in points)+f'" fill="{fill}" stroke="{outline or "none"}"/>')
    def text(self,x,y,text,size=14,fill=INK):
        font=ImageFont.truetype(str(self.font_path),size*self.scale)
        assert x + self.draw.textlength(text,font=font)/self.scale <= 340, (text,'horizontal overflow')
        self.draw.text((x*self.scale,y*self.scale),text,font=font,fill=fill,anchor='lt')
        self.svg.append(f'<text x="{x}" y="{y}" dominant-baseline="text-before-edge" font-family="Noto Sans CJK SC,Microsoft YaHei,sans-serif" font-size="{size}" fill="{fill}">{html.escape(text)}</text>')
    def torso(self,cx=112):
        self.ellipse((cx-13,88,26,28),fill='#bfd4df')
        self.polygon([(cx-10,117),(cx+10,117),(cx+34,131),(cx+29,183),(cx-29,183),(cx-34,131)],fill='#436879',outline='#bfd4df')
        self.line([(cx-22,184),(cx-26,196)],'#bfd4df',3)
        self.line([(cx+22,184),(cx+26,196)],'#bfd4df',3)
    def finish(self):
        return self.image,'\n'.join(self.svg+['</svg>'])


def make_card(index,content,font):
    c=Card(font)
    c.text(16,12,f'成人心肺复苏  /  教程 {index+1:02d} · 04',11,ACCENT)
    c.text(16,32,content['title'],25)
    c.text(16,63,content['tag'],13,MUTED)
    c.box((16,86,320,120),r=12,outline=EDGE)
    if index==0:
        c.box((39,102,65,88),fill='#203f50',r=9,outline='#87a8b9')
        c.box((46,111,51,52),fill='#102030',r=3)
        c.text(51,125,'120',23,ACCENT)
        c.ellipse((66,174,10,10),fill='#87a8b9')
        c.text(124,108,'无反应',21)
        c.text(124,140,'立即呼救 · 取 AED',15,ACCENT)
        c.text(124,171,'免提通话，接受指导',13,MUTED)
    elif index==1:
        c.torso()
        c.line([(112,130),(112,172)],'#82a8b8',2)
        c.ellipse((100,148,24,20),fill='#f4b38b')
        c.box((101,152,22,8),fill='#ffcfad',r=3)
        c.line([(125,157),(158,137),(177,137)],ACCENT,2)
        c.text(180,112,'胸骨下半部',16)
        c.text(180,148,'100–120',23,ACCENT)
        c.text(180,181,'次 / 分',13,MUTED)
    elif index==2:
        c.ellipse((40,105,76,76),fill='#244e5b')
        c.text(59,117,'30',32,ACCENT)
        c.text(60,157,'按压',14)
        c.line([(129,144),(163,144)],ACCENT,3)
        c.line([(155,137),(163,144),(155,151)],ACCENT,3)
        c.ellipse((179,105,76,76),fill='#244e5b')
        c.text(208,117,'2',32,ACCENT)
        c.text(200,157,'通气',14)
        c.text(272,115,'受训者',14)
        c.text(272,142,'循环',14,MUTED)
        c.text(272,169,'进行',14,MUTED)
    else:
        c.torso()
        # Front view: the patient's right is on the viewer's left.
        c.box((85,131,17,22),fill='#fff0b8',r=3)
        c.box((137,160,17,22),fill='#fff0b8',r=3)
        c.line([(94,131),(163,103),(179,103)],ACCENT,1)
        c.text(183,96,'右锁骨下',14)
        c.line([(154,173),(173,158),(181,158)],ACCENT,1)
        c.text(185,146,'左胸侧方',14)
        c.text(183,174,'以贴片图示为准',12,MUTED)
    for n,text in enumerate(content['steps']):
        y=222+n*27
        c.ellipse((16,y,17,17),fill='#244e5b')
        c.text(21,y+1,str(n+1),11,ACCENT)
        c.text(41,y,text,13)
    c.box((16,339,320,29),fill='#18493f',r=7)
    c.text(26,345,content['note'],13,ACCENT)
    c.text(16,379,'成人培训示意 · 请结合规范实操教学',11,MUTED)
    return c.finish()


def build(font,output):
    if output.exists():
        raise ValueError('Output already exists; choose a new directory to preserve reviewed assets')
    output.mkdir(parents=True)
    data=json.loads((PROJECT/'assets/content.zh-CN.json').read_text(encoding='utf-8'))
    for directory in ('masters','bmp_training_safe','bmp_viewer'):(output/directory).mkdir()
    records=[]; packed=bytearray(); previews=[]
    for index,card in enumerate(data['cards']):
        master,svg=make_card(index,card,font)
        (output/'masters'/f'{card["file"]}.svg').write_text(svg,encoding='utf-8')
        master.save(output/'masters'/f'{card["file"]}.png')
        native=master.resize((352,400),Image.Resampling.LANCZOS)
        previews.append(native)
        for variant,x in (('bmp_training_safe',16),('bmp_viewer',144)):
            canvas=Image.new('RGB',(640,480),BG)
            canvas.paste(native,(x,32))
            canvas.save(output/variant/f'{card["file"]}.bmp')
        raw=(output/'bmp_training_safe'/f'{card["file"]}.bmp').read_bytes()
        assert struct.unpack_from('<iiHHI',raw,18)==(640,480,1,24,0)
        sector=len(packed)//512
        packed.extend(raw)
        padding=(-len(packed))%512
        packed.extend(bytes(padding))
        records.append({'index_zero_based':index,'title':card['title'],'file':f'bmp_training_safe/{card["file"]}.bmp',
                        'start_sector':sector,'bytes':len(raw),'padding_bytes':padding,'sha256':hashlib.sha256(raw).hexdigest()})
    with (output/'cpr-tutorials-training-safe.img').open('xb') as f:f.write(packed)
    manifest={'source_content_sha256':hashlib.sha256((PROJECT/'assets/content.zh-CN.json').read_bytes()).hexdigest(),
              'font_sha256':hashlib.sha256(font.read_bytes()).hexdigest(),'training_rectangle':[16,32,352,400],
              'raster_format':'640x480 bottom-up RGB24 BI_RGB, BMP data offset 54',
              'image_is_regular_file':True,'sd_or_flash_written':False,'cards':records,
              'image_bytes':len(packed),'image_sha256':hashlib.sha256(packed).hexdigest(),
              'sources':data['sources'],'artwork':'Original vector schematics; no AHA/RCUK artwork copied.'}
    (output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
    overview=Image.new('RGB',(352*4+24*5,450),'#0b1520')
    for i,p in enumerate(previews):overview.paste(p,(24+i*376,24))
    overview.save(output/'four-cards-preview.png')
    print(f'Built four cards and {len(packed)}-byte regular-file image: {output}')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--font',required=True,type=Path)
    parser.add_argument('--output',type=Path,default=PROJECT/'assets/tutorials')
    args=parser.parse_args()
    build(args.font,args.output)
