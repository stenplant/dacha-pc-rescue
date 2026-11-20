"""Insert an NvmExpressDxe FFS file into Gigabyte GA-Z77-D3H (AMI Aptio IV) BIOS without moving other modules.

The module goes into the free space of the nested DXE volume inside FV_MAIN_NESTED. The LZMA section is
recompressed with the same parameters; the shorter result is followed by a pad file in the format Gigabyte
uses at this spot, so microcode and the PEI module S3Restore keep their addresses. Everything outside the
FV_MAIN_NESTED slot stays byte-identical to the input image.

usage: build_mod.py <original_image> <module.ffs> <output_image> <lzma.exe> <workdir>
"""
import sys, os, struct, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ffs_lib import Volume, sum8, guid

NESTED = 'AE717C2F-1A42-4F2B-8861-78B79CA07E07'
PAD_GUID = bytes.fromhex('856553e40979604ab5c6ecdea6ebfb54')   # pad-file GUID used by Gigabyte in these images

src, modp, dst, lzma_exe, work = sys.argv[1:6]
img = open(src, 'rb').read(); mod = open(modp, 'rb').read()
assert len(img) == 0x800000


def ffs_header_fix(buf, off, size):
    """Recompute header and data checksums of the FFS file at buf[off:off+size]."""
    attrs = buf[off+0x13]
    buf[off+0x10] = 0; buf[off+0x11] = 0
    state = buf[off+0x17]; buf[off+0x17] = 0
    buf[off+0x10] = (-sum8(buf[off:off+0x18])) & 0xFF
    buf[off+0x17] = state
    buf[off+0x11] = ((-sum8(buf[off+0x18:off+size])) & 0xFF) if attrs & 0x40 else 0xAA


# 1. locate the outer volume and FV_MAIN_NESTED
vol_off = None
o = 0x200000
while o < len(img):
    if img[o+0x28:o+0x2C] == b'_FVH':
        v = Volume(img[o:o+struct.unpack_from('<Q', img, o+0x20)[0]])
        fl, free = v.files()
        if fl and fl[0]['guid'] == NESTED:
            vol_off, vol, files, vol_free = o, v, fl, free
            break
        o += v.fv_length
    else:
        o += 0x1000
assert vol_off is not None, 'FV_MAIN_NESTED not found'
f0 = files[0]; f_off = vol_off + f0['off']; f_size = f0['size']
next_real = [f for f in files[1:] if f['type'] != 0xF0][0]      # next non-pad file (microcode)
next_off = vol_off + next_real['off']
assert f0['type'] == 0x0B and f0['attrs'] == 0x40 and f0['hdr_ok'] and f0['data_ok']
sec = f_off + 0x18
sec_size = int.from_bytes(img[sec:sec+3], 'little')
assert img[sec+3] == 0x01 and sec_size == f_size - 0x18, 'unexpected section layout'
unc_len, ctype = struct.unpack_from('<IB', img, sec+4)
assert ctype == 0x02, 'not AMI LZMA'
comp = img[sec+9:sec+sec_size]
assert comp[:5] == bytes.fromhex('5d00008000') and struct.unpack_from('<Q', comp, 5)[0] == unc_len
print('FV_MAIN_NESTED: file at %#x size %#x, next real file at %#x, LZMA body %d bytes, unpacked %#x'
      % (f_off, f_size, next_off, len(comp), unc_len))


def run(*a):
    r = subprocess.run(list(a), capture_output=True)
    assert r.returncode == 0, (a, r.stdout, r.stderr)


def p(n):
    return os.path.join(work, n)


open(p('nested_orig.lzma'), 'wb').write(comp)
run(lzma_exe, 'd', p('nested_orig.lzma'), p('nested_orig.unc'))
unc = bytearray(open(p('nested_orig.unc'), 'rb').read())
assert len(unc) == unc_len

# 2. nested volume: section type 0x17 (4-byte header) + FV
vs = int.from_bytes(unc[0:3], 'little')
assert unc[3] == 0x17
inner = Volume(bytes(unc[4:vs]))
assert inner.fv_length == vs - 4
ifiles, ifree = inner.files()
assert all(f['hdr_ok'] and f['data_ok'] for f in ifiles)
assert guid(mod[:16]) not in [f['guid'] for f in ifiles], 'NVMe module already present'
assert int.from_bytes(mod[0x14:0x17], 'little') == len(mod) and mod[0x12] == 0x07 and mod[0x17] == 0xF8
room = inner.fv_length - ifree
assert bytes(unc[4+ifree:vs]) == b'\xff' * room
print('nested volume: %d files, last %s at %#x, free %#x bytes; module %s needs %#x'
      % (len(ifiles), ifiles[-1]['guid'], ifiles[-1]['off'], room, guid(mod[:16]), len(mod)))
assert len(mod) <= room, 'module does not fit into the nested volume free space'
unc[4+ifree:4+ifree+len(mod)] = mod
i2, ifree2 = Volume(bytes(unc[4:vs])).files()
assert len(i2) == len(ifiles) + 1 and all(f['hdr_ok'] and f['data_ok'] for f in i2) and i2[-1]['off'] == ifree
print('module placed at nested offset %#x, free left %#x' % (ifree, inner.fv_length - ifree2))
open(p('nested_mod.unc'), 'wb').write(unc)

# 3. recompress
run(lzma_exe, 'e', p('nested_mod.unc'), p('nested_mod.lzma'), '-a1', '-d23', '-fb273', '-lc3', '-lp0', '-pb2', '-mfbt4', '-mt1')
ncomp = open(p('nested_mod.lzma'), 'rb').read()
assert ncomp[:13] == comp[:13], 'LZMA header differs from the original one'
run(lzma_exe, 'd', p('nested_mod.lzma'), p('nested_mod.chk'))
assert open(p('nested_mod.chk'), 'rb').read() == bytes(unc), 'round-trip failed'
new_sec = 9 + len(ncomp); new_size = 0x18 + new_sec
print('LZMA body: %d -> %d bytes; file size %#x -> %#x' % (len(comp), len(ncomp), f_size, new_size))

# 4. rebuild the file and pad the rest of the slot
out = bytearray(img)
region = bytearray(b'\xff' * (next_off - f_off))
assert new_size <= len(region), 'recompressed file is larger than the original slot - layout cannot be preserved'
region[:0x18] = img[f_off:f_off+0x18]
region[0x14:0x17] = new_size.to_bytes(3, 'little')
region[0x18:0x1B] = new_sec.to_bytes(3, 'little'); region[0x1B] = 0x01
struct.pack_into('<IB', region, 0x1C, unc_len, 0x02)
region[0x21:0x21+len(ncomp)] = ncomp
ffs_header_fix(region, 0, new_size)
pad_off = (new_size + 7) & ~7
gap = len(region) - pad_off
assert gap == 0 or gap >= 0x18, 'gap %d too small for a pad file' % gap
if gap:
    region[pad_off:pad_off+16] = PAD_GUID
    region[pad_off+0x12] = 0xF0; region[pad_off+0x13] = 0x00
    region[pad_off+0x14:pad_off+0x17] = gap.to_bytes(3, 'little'); region[pad_off+0x17] = 0xF8
    ffs_header_fix(region, pad_off, gap)
    print('pad file at %#x size %#x' % (f_off + pad_off, gap))
out[f_off:next_off] = region

# 5. verify
assert len(out) == len(img)
assert out[:f_off] == img[:f_off] and out[next_off:] == img[next_off:], 'bytes outside FV_MAIN_NESTED slot changed'
v2 = Volume(bytes(out[vol_off:vol_off+vol.fv_length])); fl2, free2 = v2.files()
assert all(f['hdr_ok'] and f['data_ok'] for f in fl2) and free2 == vol_free


def real(lst):
    return [(f['off'], f['size'], f['guid']) for f in lst if f['type'] != 0xF0][1:]


assert real(fl2) == real(files)
print('outer volume files after mod:')
for f in fl2:
    print('   %#x size %#x %s type %#x' % (vol_off + f['off'], f['size'], f['guid'], f['type']))
open(dst, 'wb').write(out)
print('changed range: [%#x, %#x); everything else is byte-identical to the original. Written %s' % (f_off, next_off, dst))
