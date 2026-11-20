"""Check whether the XIP PEI module S3Restore was rebased correctly in a modified image.
Takes the PE from the original image, applies its relocations for the shift delta and compares with the mod.
Shows why a UEFITool 0.28 rebuild of this BIOS breaks S3 resume, and that build_mod.py does not move it."""
import sys, struct, re
orig = open(sys.argv[1], 'rb').read(); mod = open(sys.argv[2], 'rb').read()
G = bytes.fromhex('CC52D6EF990EF04096C0E08C089070FC')  # EFD652CC-0E99-40F0-96C0-E08C089070FC
def locate(d):
    offs = [m.start() for m in re.finditer(re.escape(G), d) if m.start() >= 0x240000 and m.start() % 8 == 0]
    assert len(offs) == 1, offs
    f = offs[0]; size = int.from_bytes(d[f+0x14:f+0x17], 'little'); o = f + 0x18
    while o < f + size:
        sl = int.from_bytes(d[o:o+3], 'little')
        if d[o+3] == 0x10: return f, o + 4, sl - 4
        o = (o + sl + 3) & ~3
fo, po, ps = locate(orig); fm, pm, ps2 = locate(mod); assert ps == ps2
base = 0x100000000 - len(orig); delta = pm - po
pe = bytearray(orig[po:po+ps]); new = mod[pm:pm+ps]
e = struct.unpack_from('<I', pe, 0x3C)[0]; assert pe[e:e+4] == b'PE\0\0'
nsec = struct.unpack_from('<H', pe, e+6)[0]; opt = e + 24; assert struct.unpack_from('<H', pe, opt)[0] == 0x10B
ib = struct.unpack_from('<I', pe, opt+28)[0]
print('file off orig %#x mod %#x, PE off orig %#x mod %#x, delta %#x' % (fo, fm, po, pm, delta))
print('ImageBase orig %#x (expected %#x), mod %#x (expected %#x)' % (ib, base+po, struct.unpack_from('<I', new, opt+28)[0], base+pm))
rva, rsz = struct.unpack_from('<II', pe, opt + 96 + 5*8)
print('reloc dir rva %#x size %#x' % (rva, rsz))
struct.pack_into('<I', pe, opt+28, ib + delta)
# RVA == file offset? check sections
secs = [struct.unpack_from('<8sIIII', pe, opt + struct.unpack_from('<H', pe, e+20)[0] + i*40) for i in range(nsec)]
def r2o(r):
    for n, vs, va, rs, rp in secs:
        if va <= r < va + max(vs, rs): return r - va + rp
    return r
n = 0; o = r2o(rva); end = o + rsz
while o < end:
    page, bs = struct.unpack_from('<II', pe, o)
    if bs == 0: break
    for i in range((bs - 8) // 2):
        ent = struct.unpack_from('<H', pe, o + 8 + 2*i)[0]; t = ent >> 12
        if t == 3:
            a = r2o(page + (ent & 0xFFF)); v = struct.unpack_from('<I', pe, a)[0]; struct.pack_into('<I', pe, a, (v + delta) & 0xFFFFFFFF); n += 1
        else: assert t == 0, t
    o += bs
print('relocations applied:', n, '| my rebased PE == PE in mod:', bytes(pe) == new, '| raw PE identical (no rebase):', orig[po:po+ps] == new)
