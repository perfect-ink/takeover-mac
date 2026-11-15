"""Builds the app icon from design/icon-original.png (the original detailed vault).

Makes the door a true circle (the ring on the hinge side is rebuilt by mirroring
the right half), removes the latch bar on the right for a slightly simpler look,
moves the hinges out to the door edge, then lays the vault on the blue squircle.

    python3 design/build_icon.py      # needs Pillow and numpy; run from the repo root
"""
import os
os.chdir(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = "../Takeover/Assets.xcassets/AppIcon.appiconset"

from PIL import Image, ImageDraw, ImageFilter
import numpy as np, math
src=Image.open('icon-original.png').convert('RGBA')
A=np.array(src).astype(float)
H,W=A.shape[:2]
CX,CY=515.0,505.0
yy,xx=np.mgrid[0:H,0:W].astype(float)
R=np.hypot(xx-CX,yy-CY); T=np.degrees(np.arctan2(yy-CY,xx-CX))  # -180..180, 0=right, 90=down

def sample(img,x,y):
    # bilinear
    x=np.clip(x,0,W-1.001); y=np.clip(y,0,H-1.001)
    x0=np.floor(x).astype(int); y0=np.floor(y).astype(int); fx=(x-x0)[...,None]; fy=(y-y0)[...,None]
    return (img[y0,x0]*(1-fx)*(1-fy)+img[y0,x0+1]*fx*(1-fy)+img[y0+1,x0]*(1-fx)*fy+img[y0+1,x0+1]*fx*fy)

def rot_sample(img,deg):
    t=np.radians(T+deg)
    return sample(img,CX+R*np.cos(t),CY+R*np.sin(t))

def smooth(v,e0,e1):  # 0 at e0 ->1 at e1
    return np.clip((v-e0)/(e1-e0),0,1)

B=A.copy()
# 1. remove the right latch: face sector and ring sector copied from +90 deg (bottom)
rot=rot_sample(A,90)
face_w=(1-smooth(np.abs(T),36,44))*smooth(R,160,170)*(1-smooth(R,262,268))
ring_w=(1-smooth(np.abs(T),14,20))*smooth(R,258,266)
w=np.maximum(face_w,ring_w)[...,None]
B=B*(1-w)+rot*w
# 2. left half of ring: mirror of right half (x -> 2CX - x)
mir=sample(B,2*CX-xx,yy)
OUT=366.0
lw=(smooth(np.abs(T),92,102))*smooth(R,166,176)
lw=lw[...,None]
B=B*(1-lw)+mir*lw
# 3. cut a clean round door
door_a=(1-smooth(R,OUT-1.5,OUT+1.5))
B[...,3]=255*door_a
door=Image.fromarray(B.clip(0,255).astype(np.uint8))

# 4. hinge layer from original
M=Image.new('L',(W,H),0); d=ImageDraw.Draw(M)
d.rounded_rectangle((142,252,240,392),8,fill=255)
d.rounded_rectangle((142,612,240,770),8,fill=255)
d.rectangle((158,392,224,612),fill=255)
d.rectangle((226,290,333,390),fill=255)
d.rectangle((226,617,333,720),fill=255)
r,g,b,a=[A[...,i] for i in range(4)]
metal=((a>0)&((b-r)<74)).astype(np.uint8)*255
hm=np.minimum(np.array(M),metal)
hinge=src.copy(); hinge.putalpha(Image.fromarray(hm).filter(ImageFilter.GaussianBlur(0.7)))
hinge=hinge.crop((140,250,336,772))  # top-left (140,250)

# 5. assemble at 1024 scale: door + hinge; door left edge at CX-OUT=149. move hinge so barrel center sits on door edge
asm=Image.new('RGBA',(1200,1024),(0,0,0,0))
ox=150  # shift everything right so we have room on the left
asm.alpha_composite(door,(ox,0))
# barrel center orig x=191; want at door left edge (149) + 10
hx=ox+ (149+12) - (191-140)
# plates must reach onto the door: they are 107px long from barrel right edge; fine
asm.alpha_composite(hinge,(hx,250))
asm=asm.crop(asm.getbbox())
vault=asm
SS=2048; s=SS/1024

body=824*s; inset=(SS-body)/2
# gradient
stops=[(0.0,(0.239,0.706,0.894)),(0.34,(0.130,0.502,0.847)),(0.68,(0.043,0.282,0.596)),(1.0,(0.016,0.090,0.298))]
t=np.clip((np.arange(SS)-inset)/body,0,1)
cols=np.zeros((SS,3))
for i in range(3):
    cols[:,i]=np.interp(t,[p for p,_ in stops],[c[i] for _,c in stops])*255
g=np.repeat(cols[:,None,:],SS,axis=1)
# gloss: top 48% of body, white 0.30 -> 0
gl=np.clip(1-(np.arange(SS)-inset)/(body*0.48),0,1)*0.30
gl[np.arange(SS)<inset]=0
g=g*(1-gl[:,None,None])+255*gl[:,None,None]
bg=Image.fromarray(g.astype(np.uint8)).convert('RGBA')
mask=Image.new('L',(SS,SS),0)
ImageDraw.Draw(mask).rounded_rectangle((inset,inset,inset+body,inset+body),radius=body*0.225,fill=255)
out=Image.new('RGBA',(SS,SS),(0,0,0,0)); out.paste(bg,(0,0),mask)
# vault
tw=body*0.90; sc=tw/vault.width
v=vault.resize((round(vault.width*sc),round(vault.height*sc)),Image.LANCZOS)
ox=round((SS-v.width)/2); oy=round((SS-v.height)/2+body*0.015)
sh=Image.new('RGBA',(SS,SS),(0,0,0,0))
a=v.split()[3].point(lambda p:p*0.55)
blk=Image.new('RGBA',v.size,(2,12,40,255)); blk.putalpha(a)
sh.alpha_composite(blk,(ox,oy+int(18*s)))
sh=sh.filter(ImageFilter.GaussianBlur(16*s))
clip=Image.new('RGBA',(SS,SS),(0,0,0,0)); clip.paste(sh,(0,0),mask)
out.alpha_composite(clip)
out.alpha_composite(v,(ox,oy))

for n in [1024,512,256,128,64,32,16]:
    out.resize((n,n),Image.LANCZOS).save(f'{ICON_DIR}/icon_{n}.png')
