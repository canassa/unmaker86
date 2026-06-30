import tdinfo_structs as t, struct
data = open('TEST.EXE','rb').read()
exe = t.DOS_MZ_EXE_STRUCT.parse(data)
h = exe.tdinfo_header
# recompute extra-info offset (header start)
ubl = h_used = struct.unpack_from('<H', data, 2)[0]
pages = struct.unpack_from('<H', data, 4)[0]
used = 512 if ubl==0 else ubl
base = pages*512 - (512-used)
# header size: 2+1+1+4 + 13*2 + 14 + 2 + extension_size
hsz = 2+1+1+4 + 13*2 + 14 + 2 + h.extension_size
off = base + hsz
off += h.symbols_count*9          # symbol records
mod_off = off; off += h.modules_count*18
sf_off = off;  off += h.source_files_count*6
ln_off = off;  off += h.line_numbers_count*4
print("base(header)=0x%x hsz=%d -> symbols@0x%x modules@0x%x srcfiles@0x%x lines@0x%x" % (base,hsz,base+hsz,mod_off,sf_off,ln_off))

# code addr of _add/_main for correlation
names = exe.name_pool
faddr = {}
for s in exe.symbol_records:
    nm = names[s.index-1] if 0<s.index<=len(names) else ''
    if nm in ('_add','_main'): faddr[nm]=(s.segment,s.offset)
print("func code addrs:", faddr)

print("\n--- SOURCE_FILE records (%d x 6 bytes) raw+decoded ---" % h.source_files_count)
for i in range(h.source_files_count):
    rec = data[sf_off+i*6: sf_off+i*6+6]
    a,b,c = struct.unpack('<HHH', rec)
    print("  raw=%s  as 3xWORD: name?=%d  w2=%d(0x%x)  w3=%d" % (rec.hex(), a,b,b,c))

print("\n--- LINE_NUMBER table (%d x 4 bytes) ---" % h.line_numbers_count)
print("  TEST.C executable lines are ~4-8 (add) and 11-17 (main)")
for i in range(h.line_numbers_count):
    rec = data[ln_off+i*4: ln_off+i*4+4]
    le_off_line = struct.unpack('<HH', rec)   # (word0, word1)
    print("  [%2d] raw=%s   A(w0=%d w1=%d)   interp: {line=%d off=0x%04x} OR {off=0x%04x line=%d}" %
          (i, rec.hex(), le_off_line[0], le_off_line[1], le_off_line[0], le_off_line[1], le_off_line[0], le_off_line[1]))

# correlation records (8 bytes) come AFTER scopes+segments; locate
off2 = ln_off
off2 += h.scopes_count*12
off2 += h.segments_count*16
corr_off = off2
print("\n--- CORRELATION records (%d x 8 bytes) @0x%x ---" % (h.correlations_count, corr_off))
for i in range(h.correlations_count):
    rec = data[corr_off+i*8: corr_off+i*8+8]
    ws = struct.unpack('<HHHH', rec)
    print("  raw=%s  4xWORD=%s" % (rec.hex(), ws))
