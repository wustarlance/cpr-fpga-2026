#!/usr/bin/env python3
"""Build editable vector cards, compatible BMPs and a regular-file SD image.

This tool never opens physical drives. The .img is an ordinary output file.
"""
import argparse
import hashlib
import html
import json
import math
import struct
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

PROJECT=Path(__file__).resolve().parents[1]
BG='#102030'; PANEL='#142b3b'; INK='#f3f7fa'; MUTED='#b6c9d5'; ACCENT='#58e0bc'; EDGE='#284859'


class Card:
    def __init__(self,font_path,font_index=0):
        self.scale=3
        self.image=Image.new('RGB',(1056,1200),BG)
        self.draw=ImageDraw.Draw(self.image)
        self.font_path=font_path; self.font_index=font_index
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
    def _sample(self,segs,steps=20):
        """三次贝塞尔采样：返回 (多边形点列表, SVG path 的 d 串)。
        PIL 没有贝塞尔，只能按 steps 采样成折线，再填/描；SVG 侧保留原始曲线。"""
        poly=[]; d=[]; cur=None
        for seg in segs:
            if seg[0]=='M':
                cur=(seg[1],seg[2]); poly.append(cur); d.append(f'M{cur[0]} {cur[1]}')
            else:
                c1=(seg[1],seg[2]); c2=(seg[3],seg[4]); end=(seg[5],seg[6])
                for i in range(1,steps+1):
                    t=i/steps; mt=1-t
                    poly.append((mt**3*cur[0]+3*mt*mt*t*c1[0]+3*mt*t*t*c2[0]+t**3*end[0],
                                 mt**3*cur[1]+3*mt*mt*t*c1[1]+3*mt*t*t*c2[1]+t**3*end[1]))
                d.append(f'C{c1[0]} {c1[1]} {c2[0]} {c2[1]} {end[0]} {end[1]}')
                cur=end
        return poly,' '.join(d)

    def smooth(self,segs,fill,outline=None,steps=20):
        """闭合的平滑轮廓（填充）。"""
        poly,d=self._sample(segs,steps)
        pts=[(int(x*self.scale),int(y*self.scale)) for x,y in poly]
        self.draw.polygon(pts,fill=fill)
        if outline:
            self.draw.line(pts+[pts[0]],fill=outline,width=self.scale,joint='curve')
        self.svg.append(f'<path d="{d} Z" fill="{fill}" stroke="{outline or "none"}" stroke-width="1"/>')

    def stroke(self,segs,fill,width=1,steps=20):
        """只描线（不填充）。"""
        poly,d=self._sample(segs,steps)
        self.draw.line([(int(x*self.scale),int(y*self.scale)) for x,y in poly],
                       fill=fill,width=width*self.scale,joint='curve')
        self.svg.append(f'<path d="{d}" fill="none" stroke="{fill}" stroke-width="{width}" stroke-linecap="round"/>')

    def text(self,x,y,text,size=14,fill=INK):
        font=ImageFont.truetype(str(self.font_path),size*self.scale,index=self.font_index)
        assert x + self.draw.textlength(text,font=font)/self.scale <= 340, (text,'horizontal overflow')
        self.draw.text((x*self.scale,y*self.scale),text,font=font,fill=fill,anchor='lt')
        self.svg.append(f'<text x="{x}" y="{y}" dominant-baseline="text-before-edge" font-family="Noto Sans CJK SC,Microsoft YaHei,sans-serif" font-size="{size}" fill="{fill}">{html.escape(text)}</text>')
    def arrow_curve(self,segs,fill=ACCENT,width=2,head=8):
        """沿贝塞尔曲线描线，并在末端按末段切线方向画箭头（用于"回路"这类弯箭头）。"""
        self.stroke(segs,fill,width)
        pts,_=self._sample(segs,24)
        (x1,y1),(x0,y0)=pts[-1],pts[-4]
        ang=math.atan2(y1-y0,x1-x0)
        self.polygon([(x1,y1),
                      (x1-head*math.cos(ang-0.5),y1-head*math.sin(ang-0.5)),
                      (x1-head*math.cos(ang+0.5),y1-head*math.sin(ang+0.5))],fill)

    def arrow(self,p0,p1,fill=ACCENT,width=3,head=7):
        """单向箭头：线段 + 三角形箭头（head = 箭头长度，逻辑像素）。"""
        x0,y0=p0; x1,y1=p1
        ang=math.atan2(y1-y0,x1-x0)
        self.line([p0,(x1-head*0.8*math.cos(ang),y1-head*0.8*math.sin(ang))],fill,width)
        self.polygon([(x1,y1),
                      (x1-head*math.cos(ang-0.45),y1-head*math.sin(ang-0.45)),
                      (x1-head*math.cos(ang+0.45),y1-head*math.sin(ang+0.45))],fill)

    def text_center(self,x,y,text,size=11,fill=INK):
        """按字形墨迹包围盒把文字居中到 (x,y)。text() 用的是 anchor='lt'（行框左上角），
        圆圈里的序号会因此偏高几像素——这里改成量出墨迹再平移，才是视觉居中。"""
        s=self.scale
        font=ImageFont.truetype(str(self.font_path),size*s,index=self.font_index)
        l,t,r,b=self.draw.textbbox((0,0),text,font=font)   # 物理像素，相对绘制原点
        self.draw.text((x*s-(l+r)/2,y*s-(t+b)/2),text,font=font,fill=fill)
        assert x+(r-l)/2/s <= 340,(text,'horizontal overflow')
        self.svg.append(f'<text x="{x}" y="{y}" text-anchor="middle" dominant-baseline="central" font-family="Noto Sans CJK SC,Microsoft YaHei,sans-serif" font-size="{size}" fill="{fill}">{html.escape(text)}</text>')

    def torso(self,cx=112):
        """正面人体图标（纯矢量，无外部素材）：头 + 颈 + 圆肩收腰躯干 + 手臂 + 腿。
        关键技巧：手臂和腿各画成一条圆头粗线，与躯干之间留出约 3px 背景色的缝，
        这样才一眼认得出是人；早先"圆头 + 六边形躯干 + 两条直线腿"像几何拼图，
        把手臂并入轮廓又像一件大衣。"""
        BODY='#436879'; SKIN='#bfd4df'; HZ='#9fbccc'; y0=84
        for s_ in (-1,1):
            # 腿（先画，上端被躯干压住）
            self.line([(cx+s_*11,y0+92),(cx+s_*12,y0+112)],BODY,13)
            self.ellipse((cx+s_*12-6,y0+112-6,12,12),fill=BODY)
            # 手臂：与躯干之间留背景缝，末端圆头当作手
            self.line([(cx+s_*29,y0+47),(cx+s_*27,y0+88)],BODY,9)
            self.ellipse((cx+s_*29-4,y0+47-4,8,8),fill=BODY)
            self.ellipse((cx+s_*27-5,y0+88-5,10,10),fill=BODY)
        # 躯干：圆肩 → 收腰 → 髋
        self.smooth([('M',cx-6,y0+32),
                     ('C',cx-6,y0+39, cx-15,y0+38, cx-22,y0+44),
                     ('C',cx-24,y0+50, cx-21,y0+62, cx-18,y0+72),
                     ('C',cx-17,y0+82, cx-19,y0+88, cx-20,y0+93),
                     ('C',cx-20,y0+96, cx-13,y0+96, cx-8,y0+96),
                     ('C',cx-3,y0+96, cx+3,y0+96, cx+8,y0+96),
                     ('C',cx+13,y0+96, cx+20,y0+96, cx+20,y0+93),
                     ('C',cx+19,y0+88, cx+17,y0+82, cx+18,y0+72),
                     ('C',cx+21,y0+62, cx+24,y0+50, cx+22,y0+44),
                     ('C',cx+15,y0+38, cx+6,y0+39, cx+6,y0+32)],fill=BODY)
        # 颈 + 头
        self.box((cx-5,y0+24,10,12),fill=SKIN,r=2)
        self.ellipse((cx-11,y0+3,22,24),fill=SKIN)
        # 胸骨中线（卡片 2 靠它定位；不画锁骨横线，避免像准星）
        self.stroke([('M',cx,y0+46),('C',cx+1,y0+60, cx+1,y0+76, cx,y0+88)],HZ,1)

    def finish(self):
        return self.image,'\n'.join(self.svg+['</svg>'])


def make_card(index,content,font):
    c=Card(font)
    c.text(16,12,f'成人心肺复苏  /  教程 {index+1:02d} · 04',11,ACCENT)
    c.text(16,32,content['title'],25)
    c.text(16,63,content['tag'],13,MUTED)
    c.box((16,86,320,120),r=12,outline=EDGE)
    if index==0:
        # 三步判断流程（借鉴 optimized_v2 的信息层次）：三块 chip 把面板填满，
        # 上下各留 26px 一致；故意不编号，避免和下面步骤的 ①②③④ 形成两套编号，
        # 顺序由箭头表达。chip 内：主标签 16px / 副说明 11px，成对垂直居中。
        for i,(label,sub) in enumerate((('确认安全','观察环境'),('查反应','拍肩呼喊'),('看呼吸','最多 10 秒'))):
            x=41+i*96
            c.box((x,118,78,56),fill='#1b3a4d',r=9)
            c.text_center(x+39,137,label,16)
            c.text_center(x+39,156,sub,11,MUTED)
        # 12～18 px 间隙使用 chevron，保留低分辨率下的可辨识宽度。
        for x0 in (124,220):
            c.line([(x0,138),(x0+8,146),(x0,154)],ACCENT,3)
    elif index==1:
        c.torso()
        c.ellipse((100,148,24,20),fill='#f4b38b')
        c.box((101,152,22,8),fill='#ffcfad',r=3)
        c.arrow((112,130),(112,144),ACCENT,3,6)            # 按压方向（指向手）
        c.line([(126,166),(146,178)],ACCENT,1)
        c.text(148,174,'胸骨下半部',11,MUTED)
        c.text(212,92,'100–120',22,ACCENT)                 # 频率
        c.text(212,117,'次 / 分',11,MUTED)
        c.text(212,136,'5–6 cm',20,ACCENT)                 # 深度
        c.text(212,162,'成人按压深度',11,MUTED)
    elif index==2:
        c.ellipse((40,105,76,76),fill='#244e5b')
        c.text_center(78,132,'30',32,ACCENT)
        c.text_center(78,161,'按压',14)
        c.ellipse((179,105,76,76),fill='#244e5b')
        c.text_center(217,132,'2',32,ACCENT)
        c.text_center(217,161,'通气',14)
        c.arrow((129,144),(163,144),ACCENT,3,8)
        # 回路箭头：通气后回到按压（借鉴 optimized_v2 的"重复循环"），用曲线避免折角
        c.arrow_curve([('M',204,183),('C',178,201, 124,201, 99,187)],ACCENT,2,9)
        c.text(264,138,'重复循环',13)
    else:
        c.torso()
        # Front view: the patient's right is on the viewer's left.
        c.box((92,130,14,18),fill='#fff0b8',r=3)
        c.box((117,150,14,18),fill='#fff0b8',r=3)
        c.line([(103,132),(163,103),(179,103)],ACCENT,1)
        c.text(183,96,'右锁骨下',14)
        c.line([(131,158),(173,158),(181,158)],ACCENT,1)
        c.text(185,146,'左胸侧方',14)
        c.text(183,174,'避开起搏器凸起',12,MUTED)
    for n,text in enumerate(content['steps']):
        y=222+n*27
        c.ellipse((16,y,17,17),fill='#244e5b')
        c.text_center(16+8.5,y+8.5,str(n+1),11,ACCENT)
        c.text(41,y,text,13)
    c.box((16,339,320,29),fill='#18493f',r=7)
    c.text(26,345,content['note'],13,ACCENT)
    c.text(16,379,'成人培训示意 · 请结合规范实操教学 · 急救请拨 120',11,MUTED)
    return c.finish()


def build(font,output,font_index=0):
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
    parser.add_argument('--font-index',type=int,default=0,help='字体集合(.ttc)里的 face 序号；Noto Sans CJK 的 SC 是 2')
    args=parser.parse_args()
    build(args.font,args.output,args.font_index)
