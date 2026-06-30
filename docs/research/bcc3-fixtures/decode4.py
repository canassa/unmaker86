import sys
from decode2 import parse, walk, u8, u16, u32

def trailing(h):
    b=h.raw; o=h.after_members
    def rd(n): return [u16(b,o+i*2) for i in range(n)]
    print(' TRAILING layout from 0x%x to name pool 0x%x (len %d):'%(o,h.name_pool_abs,h.trailing_len))
    # class: 11 bytes each
    print('  [class %d x11]'%h.class_entries)
    for i in range(h.class_entries):
        r=o; o+=11
        print('     cls%d parentIdx=%d parentCnt=%d memberIdx=%d nameIdx=%d vptr=%d info=0x%02x'%(
            i+1,u16(b,r),u16(b,r+2),u16(b,r+4),u16(b,r+6),u16(b,r+8),u8(b,r+10)))
    print('  [parent %d x2] @0x%x: %s'%(h.parent_entries,o,[u16(b,o+i*2) for i in range(h.parent_entries)])); o+=h.parent_entries*2
    print('  [scope_class %d x4] @0x%x:'%(h.scope_class_entries,o))
    for i in range(h.scope_class_entries):
        r=o; o+=4; print('     scls%d classIdx=%d classCnt=%d'%(i+1,u16(b,r),u16(b,r+2)))
    print('  [module_class %d x4] @0x%x:'%(h.module_class_entries,o))
    for i in range(h.module_class_entries):
        r=o; o+=4; print('     mcls%d classIdx=%d classCnt=%d'%(i+1,u16(b,r),u16(b,r+2)))
    print('  [cov_map %d x2 (per segment)] @0x%x: %s'%(h.segments_count,o,[u16(b,o+i*2) for i in range(h.segments_count)])); o+=h.segments_count*2
    print('  [cov_offsets %d x2] @0x%x: %s'%(h.coverage_count,o,['0x%x'%u16(b,o+i*2) for i in range(h.coverage_count)])); o+=h.coverage_count*2
    print('  [module_opt %d x4] @0x%x: %s'%(h.modules_count,o,['0x%x'%u32(b,o+i*4) for i in range(h.modules_count)])); o+=h.modules_count*4
    print('  END @0x%x  name_pool @0x%x  residual=%d'%(o,h.name_pool_abs,h.name_pool_abs-o))

for path in sys.argv[1:]:
    h=parse(path); walk(h)
    print('='*60); print(path,'scopes=%d segs=%d mods=%d cov=%d'%(h.scopes_count,h.segments_count,h.modules_count,h.coverage_count))
    trailing(h)
