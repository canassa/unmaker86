import struct, sys
from decode2 import parse, walk

def names(h):
    b=h.raw; o=h.name_pool_abs; out={}
    idx=1
    end=o+h.names_pool_size
    cur=o
    while cur<end and idx<=h.names_count:
        s=bytearray()
        while cur<end and b[cur]!=0:
            s.append(b[cur]); cur+=1
        cur+=1
        out[idx]=s.decode('latin1'); idx+=1
    return out

for path in (sys.argv[1:] if __name__=='__main__' else []):
    h=parse(path); walk(h)
    nm=names(h)
    print('==',path,'names=%d=='%h.names_count)
    # print names of interest
    for i,s in nm.items():
        if any(k in s for k in ('Base','Derived','Color','Big','Small','who','fa','fb','fc','fz','padd','isr','cadd','esp','csp','ssp','finc','dummy','square','Point','Rect','this','Z','main')):
            print('  #%d = %r'%(i,s))
