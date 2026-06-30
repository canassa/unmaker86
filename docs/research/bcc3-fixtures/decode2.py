import struct, sys

def u8(b,o):  return b[o]
def u16(b,o): return struct.unpack_from('<H', b, o)[0]
def s16(b,o): return struct.unpack_from('<h', b, o)[0]
def u32(b,o): return struct.unpack_from('<I', b, o)[0]

def trailer_off(b):
    used = u16(b,2); pages = u16(b,4)
    if used == 0: used = 512
    return pages*512 - (512-used)

class H: pass

def parse(path):
    b = open(path,'rb').read()
    t = trailer_off(b)
    h = H(); h.raw=b; h.t=t
    assert u16(b,t)==0x52FB, "bad magic at %x"%t
    h.names_pool_size=u32(b,t+4); h.names_count=u16(b,t+8)
    h.types_count=u16(b,t+0xA); h.members_count=u16(b,t+0xC)
    h.symbols_count=u16(b,t+0xE); h.globals_count=u16(b,t+0x10)
    h.modules_count=u16(b,t+0x12); h.locals_count=u16(b,t+0x14)
    h.scopes_count=u16(b,t+0x16); h.lines_count=u16(b,t+0x18)
    h.srcfiles_count=u16(b,t+0x1A); h.segments_count=u16(b,t+0x1C)
    h.correlations_count=u16(b,t+0x1E); h.image_size=u32(b,t+0x20)
    h.extension_size=u16(b,t+0x2E)
    # ext header
    e=t+0x30
    h.class_entries=u16(b,e+0); h.parent_entries=u16(b,e+2)
    h.global_classes=u16(b,e+4); h.f0x36=u16(b,e+6)
    h.scope_class_entries=u16(b,e+8); h.module_class_entries=u16(b,e+0xA)
    h.coverage_count=u16(b,e+0xC); h.name_pool_offset=u32(b,e+0xE)
    h.browser_entries=u16(b,e+0x12); h.opt_sym_entries=u16(b,e+0x14)
    h.debug_flags=u16(b,e+0x16); h.ref_info_size=u32(b,e+0x18)
    h.header_end = t+0x30+h.extension_size
    h.name_pool_abs = h.header_end + h.name_pool_offset
    return h

def walk(h):
    b=h.raw; o=h.header_end
    secs=[]
    def take(n,name):
        nonlocal o
        secs.append((name,o,n)); o+=n
    take(h.symbols_count*9,'symbols')
    take(h.modules_count*16,'modules')
    take(h.srcfiles_count*6,'srcfiles')
    take(h.lines_count*4,'lines')
    take(h.scopes_count*12,'scopes')
    take(h.segments_count*16,'segments')
    take(h.correlations_count*8,'correlations')
    take(h.types_count*8,'types')
    take(h.members_count*5,'members')
    h.after_members=o
    h.trailing_len = h.name_pool_abs - o
    return secs

def hexdump(b, base, length):
    out=[]
    for i in range(0,length,16):
        row=b[base+i:base+i+16]
        hexs=' '.join('%02x'%c for c in row)
        out.append('%04x: %-48s' % (base+i, hexs))
    return '\n'.join(out)

for path in (sys.argv[1:] if __name__=='__main__' else []):
    h=parse(path); secs=walk(h)
    print('='*70)
    print(path, 'trailer=0x%x header_end=0x%x name_pool=0x%x file=0x%x'%(h.t,h.header_end,h.name_pool_abs,len(h.raw)))
    print(' counts: sym=%d glob=%d mod=%d scope=%d line=%d src=%d seg=%d corr=%d type=%d memb=%d'%(
        h.symbols_count,h.globals_count,h.modules_count,h.scopes_count,h.lines_count,
        h.srcfiles_count,h.segments_count,h.correlations_count,h.types_count,h.members_count))
    print(' ext: class=%d parent=%d global=%d f0x36=%d scope_cls=%d mod_cls=%d cover=%d browser=%d optsym=%d dbgflags=%d refinfo=%d'%(
        h.class_entries,h.parent_entries,h.global_classes,h.f0x36,h.scope_class_entries,
        h.module_class_entries,h.coverage_count,h.browser_entries,h.opt_sym_entries,h.debug_flags,h.ref_info_size))
    for name,off,n in secs:
        print('   %-13s @0x%04x len=%d end=0x%04x'%(name,off,n,off+n))
    print(' after_members=0x%x  trailing_len=%d (to name pool)'%(h.after_members,h.trailing_len))
    print(' TRAILING HEX:')
    print(hexdump(h.raw, h.after_members, h.trailing_len))
