import struct, sys
from decode2 import parse, walk, u8, u16, s16, u32
from names import names

TIDN={0:'void',4:'schar',5:'sint',6:'slong',7:'squad',8:'uchar',9:'uint',10:'ulong',
 0xB:'uquad',0xC:'pchar',0xD:'float',0xE:'tpreal',0xF:'double',0x10:'ldouble',
 0x15:'nearp',0x16:'farp',0x17:'seg',0x1A:'array',0x1E:'struct',0x1F:'union',
 0x22:'enum',0x23:'func',0x28:'bool',0x2D:'specialfunc',0x2E:'class'}

def tname(i): return TIDN.get(i,'?%02x'%i)

def modules(h, nm):
    b=h.raw; o=h.header_end + h.symbols_count*9
    print(' MODULES:')
    for i in range(h.modules_count):
        r=o+i*16
        name=u16(b,r); lang=u8(b,r+2); mm=u8(b,r+3)
        f4=u16(b,r+4); c6=u16(b,r+6); f8=u16(b,r+8); cA=u16(b,r+0xA); fC=u16(b,r+0xC); cE=u16(b,r+0xE)
        print('  mod%d name=%r lang=0x%02x mmbyte=0x%02x (mm=%d underbars=%d) symIdx=%d symCnt=%d srcIdx=%d srcCnt=%d corrIdx=%d corrCnt=%d'%(
            i+1, nm.get(name,'?'), lang, mm, mm&7, (mm>>3)&1, f4,c6,f8,cA,fC,cE))

def srcfiles(h, nm):
    b=h.raw; o=h.header_end + h.symbols_count*9 + h.modules_count*16
    print(' SRCFILES:')
    for i in range(h.srcfiles_count):
        r=o+i*6; name=u16(b,r); ts=u32(b,r+2)
        print('  src%d name=%r ts=0x%08x'%(i+1, nm.get(name,'?'), ts))

def correlations(h):
    b=h.raw
    o=h.header_end + h.symbols_count*9 + h.modules_count*16 + h.srcfiles_count*6 + h.lines_count*4 + h.scopes_count*12 + h.segments_count*16
    print(' CORRELATIONS:')
    for i in range(h.correlations_count):
        r=o+i*8
        print('  corr%d seg=%d src=%d lineFirst=%d lineCnt=%d'%(i+1,u16(b,r),u16(b,r+2),u16(b,r+4),u16(b,r+6)))

def types(h, nm, lo=1, hi=None):
    b=h.raw
    o=h.header_end + h.symbols_count*9 + h.modules_count*16 + h.srcfiles_count*6 + h.lines_count*4 + h.scopes_count*12 + h.segments_count*16 + h.correlations_count*8
    h.types_off=o
    if hi is None: hi=h.types_count
    print(' TYPES [%d..%d]:'%(lo,hi))
    for i in range(lo-1, hi):
        r=o+i*8; tid=u8(b,r); name=u16(b,r+1); size=u16(b,r+3); cls=u8(b,r+5); mt=u16(b,r+7)
        print('  t%-3d id=0x%02x(%-10s) name=%-10r size=%-4d class=0x%02x member_type=%d'%(
            i+1, tid, tname(tid), nm.get(name,'') if name else '', size, cls, mt))

def members(h, nm, lo=1, hi=None):
    b=h.raw
    o=h.header_end + h.symbols_count*9 + h.modules_count*16 + h.srcfiles_count*6 + h.lines_count*4 + h.scopes_count*12 + h.segments_count*16 + h.correlations_count*8 + h.types_count*8
    if hi is None: hi=h.members_count
    print(' MEMBERS [%d..%d]:'%(lo,hi))
    for i in range(lo-1, hi):
        r=o+i*5; fl=u8(b,r); name=u16(b,r+1); typ=u16(b,r+3); sval=s16(b,r+3)
        print('  m%-3d flags=0x%02x name=%-12r type/val=%d (signed %d)'%(i+1, fl, nm.get(name,'') if name else '', typ, sval))

cmd=sys.argv[1]
for path in sys.argv[2:]:
    h=parse(path); walk(h); nm=names(h)
    print('='*60); print(path)
    if cmd=='mod': modules(h,nm)
    elif cmd=='src': srcfiles(h,nm); correlations(h)
    elif cmd=='types': types(h,nm)
    elif cmd=='members': members(h,nm)
    elif cmd=='all': modules(h,nm); types(h,nm); members(h,nm)
