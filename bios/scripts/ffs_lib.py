"""Minimal UEFI FFSv2 volume parser: volume header, file walk, checksum checks."""
import struct, uuid

def guid(b): return str(uuid.UUID(bytes_le=bytes(b))).upper()
def sum8(b): return sum(b) & 0xFF
def sum16(b):
    return sum(struct.unpack('<%dH' % (len(b)//2), b)) & 0xFFFF

class Volume:
    def __init__(self, data):
        self.data = data
        assert data[0x28:0x2C] == b'_FVH', 'no _FVH'
        self.fs_guid = guid(data[0x10:0x20])
        self.fv_length, = struct.unpack_from('<Q', data, 0x20)
        self.attrs, self.hdr_len, self.checksum, self.ext_off, _, self.rev = struct.unpack_from('<IHHHBB', data, 0x2C)
        self.erase = 0xFF if self.attrs & 0x800 else 0x00
        self.blocks = []
        o = 0x38
        while True:
            n, l = struct.unpack_from('<II', data, o); o += 8
            if n == 0 and l == 0: break
            self.blocks.append((n, l))
        assert o == self.hdr_len, (o, self.hdr_len)
        assert sum16(data[:self.hdr_len]) == 0, 'FV header checksum bad'
        assert sum(n*l for n, l in self.blocks) == self.fv_length
    def files(self):
        """-> list of dict(off,size,guid,type,attrs,state,hdr_ok,data_ok), free_off"""
        d = self.data; o = self.hdr_len; out = []
        end = min(self.fv_length, len(d))
        while o + 0x18 <= end:
            o = (o + 7) & ~7
            h = d[o:o+0x18]
            if h == bytes([self.erase])*0x18: break
            size = int.from_bytes(h[0x14:0x17], 'little')
            ftype, attrs, state = h[0x12], h[0x13], h[0x17]
            hh = bytearray(h); hh[0x11] = 0; hh[0x17] = 0   # data checksum and state excluded
            hdr_ok = sum8(hh) == 0
            if attrs & 0x40:
                data_ok = (sum8(d[o+0x18:o+size]) + h[0x11]) & 0xFF == 0
            else:
                data_ok = h[0x11] == 0xAA
            out.append(dict(off=o, size=size, guid=guid(h[:16]), type=ftype, attrs=attrs, state=state, hdr_ok=hdr_ok, data_ok=data_ok))
            assert size >= 0x18, 'bad file size at %x' % o
            o += size
        return out, o
