#!/usr/bin/env python3
"""Own procedural diagnostic pixels/maps/lettering; stdlib only. Repository LICENSE.
No source photographs, engine data, fonts or external input. --check writes nothing.
"""
import argparse
import json
import math
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1] / 'Test-Wallpaper'
W, H = 960, 540
# Independently drawn 5x7 bitmap capitals, just for fixture labels.
FONT = {
'A':['01110','10001','10001','11111','10001','10001','10001'],
'B':['11110','10001','10001','11110','10001','10001','11110'],
'C':['01111','10000','10000','10000','10000','10000','01111'],
'D':['11110','10001','10001','10001','10001','10001','11110'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'F':['11111','10000','10000','11110','10000','10000','10000'],
'G':['01111','10000','10000','10111','10001','10001','01111'],
'H':['10001','10001','10001','11111','10001','10001','10001'],
'I':['11111','00100','00100','00100','00100','00100','11111'],
'L':['10000','10000','10000','10000','10000','10000','11111'],
'M':['10001','11011','10101','10101','10001','10001','10001'],
'N':['10001','11001','10101','10011','10001','10001','10001'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'T':['11111','00100','00100','00100','00100','00100','00100'],
'U':['10001','10001','10001','10001','10001','10001','01110'],
'V':['10001','10001','10001','10001','10001','01010','00100'],
'W':['10001','10001','10001','10101','10101','11011','10001'],
'X':['10001','10001','01010','00100','01010','10001','10001'],
'Y':['10001','10001','01010','00100','00100','00100','00100'],
'0':['01110','10001','10011','10101','11001','10001','01110'],
'1':['00100','01100','00100','00100','00100','00100','01110'],
'2':['01110','10001','00001','00010','00100','01000','11111'],
'5':['11111','10000','10000','11110','00001','10001','01110'],
'+':['00000','00100','00100','11111','00100','00100','00000'],
'-':['00000','00000','00000','11111','00000','00000','00000'],
'.':['00000','00000','00000','00000','00000','00110','00110'],
'/':['00001','00001','00010','00100','01000','10000','10000'],
' ':['00000']*7,
}


def text(pixels, width, x, y, value, scale=2):
    for c in value:
        for yy, row in enumerate(FONT[c]):
            for xx, bit in enumerate(row):
                if bit == '1':
                    for dy in range(scale):
                        for dx in range(scale):
                            p = ((y+yy*scale+dy)*width+x+xx*scale+dx)*4
                            pixels[p:p+4] = bytes([233, 241, 250, 255])
        x += 6*scale


def png(pixels, width, height):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    rows = b''.join(b'\0'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,9))+chunk(b'IEND',b'')


def texture(width, height):
    pixels = bytearray(width*height*4)
    for y in range(height):
        for x in range(width):
            grain = ((x*73856093) ^ (y*19349663) ^ ((x*y+17)*83492791)) & 0xffffffff
            grain = (grain ^ (grain >> 13))*1274126177 & 0xffffffff
            level = 30+(grain >> 24)//3
            color = [level//2,level+20,level+45,255]
            if x % 32 < 2 or y % 28 < 2: color = [100,160,180,255]
            if (x % 47-23)**2+(y % 43-21)**2 < 10: color = [235,190,80,255]
            p=(y*width+x)*4; pixels[p:p+4]=bytes(color)
    return pixels


def encode(v):
    return max(0,min(255,round(128+v*(128 if v < 0 else 127))))


def flow_effect():
    return {'type':'flow','flowMap':{'format':'wss-flow-rgba8','version':1,'asset':'assets/flow.png'},'speed':40,'strength':18}


def scene(title, layers):
    return json.dumps({'format':'wss-scene','version':1,'title':title,'canvas':{'width':1920,'height':1080},'layers':layers},indent=2).encode()+b'\n'


def assets():
    image=texture(W,H); flow=bytearray([128,128,0,255])*(W*H)
    regions=[(15,50,225,140,'RIGHT +X',(1,0)),(250,50,225,140,'LEFT -X',(-1,0)),
             (485,50,225,140,'DOWN +Y',(0,1)),(720,50,225,140,'UP -Y',(0,-1)),
             (15,210,300,135,'DIAGONAL',(.707,.707)),(330,210,300,135,'CURVE',None),
             (645,210,300,135,'0.25 / 0.5 / 1',(1,0)),(15,365,300,135,'SOFT EDGE',(0,1)),
             (330,365,300,135,'NEUTRAL',(0,0)),(645,365,300,135,'COVERAGE',(1,0))]
    text(image,W,15,12,'WSS FLOW V1',3)
    for x0,y0,width,height,label,vec in regions:
        for y in range(y0,y0+height):
            for x in range(x0,x0+width):
                p=(y*W+x)*4
                if y < y0+24: image[p:p+4]=bytes([17,23,32,255]); continue
                v=vec
                if v is None:
                    angle=(x-x0)/width*math.pi*.8
                    v=(math.cos(angle),math.sin(angle))
                magnitude = [.25,.5,1][min(2,(x-x0)*3//width)] if label.startswith('0.25') else 1
                edge=min(x-x0,width-1-(x-x0),y-y0-24,y0+height-1-y)
                coverage=max(0,min(1,edge/8))
                if label=='SOFT EDGE': magnitude *= max(0,min(1,edge/28))
                if label=='COVERAGE': coverage *= (x-x0)/width
                flow[p:p+4]=bytes([encode(v[0]*magnitude),encode(v[1]*magnitude),0,round(255*coverage)])
        text(image,W,x0+6,y0+5,label)
    base={'image':'assets/background.png','transform':{'center':[960,540],'size':[1920,1080]},'composition':'replace','effects':[flow_effect()]}
    files={'WSS-Flow-v1/assets/background.png':png(image,W,H),'WSS-Flow-v1/assets/flow.png':png(flow,W,H),
           'WSS-Flow-v1/scene.wss.json':scene('WSS Flow v1 - directions and coverage',[base])}
    # A second own scene compares identical image/map/time, Flow and Flow -> Ripple.
    backdrop=bytearray([12,18,28,255])*(W*H)
    text(backdrop,W,15,12,'FLOW / FLOW + RIPPLE',3)
    text(backdrop,W,25,47,'FLOW',2); text(backdrop,W,505,47,'FLOW + RIPPLE',2)
    size=432; tile=texture(size,size); tilemap=bytearray()
    for y in range(size):
        for x in range(size):
            angle=(x/size)*math.pi*.6+.3
            coverage=max(0,min(1,min(x,y,size-1-x,size-1-y)/16))
            tilemap.extend([encode(math.cos(angle)),encode(math.sin(angle)),0,round(coverage*255)])
    layers=[{'image':'assets/background.png','transform':{'center':[960,540],'size':[1920,1080]},'composition':'replace'}]
    for cx,chain in [(480,False),(1440,True)]:
        effects=[flow_effect()]
        if chain: effects.append({'type':'ripple','amplitude':8,'wavelength':90,'stretch':1.4,'direction':180,'travelSpeed':18,'evolutionRate':.15,'seed':31337})
        layers.append({'image':'assets/tile.png','transform':{'center':[cx,510],'size':[864,864]},'effects':effects})
    files.update({'WSS-Flow-Ripple-v1/assets/background.png':png(backdrop,W,H),
                  'WSS-Flow-Ripple-v1/assets/tile.png':png(tile,size,size),
                  'WSS-Flow-Ripple-v1/assets/flow.png':png(tilemap,size,size),
                  'WSS-Flow-Ripple-v1/scene.wss.json':scene('WSS Flow plus Ripple v1 - side by side',layers)})
    return files


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');check=parser.parse_args().check
    for name,data in assets().items():
        path=ROOT/name
        if check:
            if path.read_bytes()!=data: raise SystemExit('Fixture differs: '+str(path))
        else:
            path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        print(('Verified ' if check else 'Generated ')+str(path))


if __name__=='__main__': main()
