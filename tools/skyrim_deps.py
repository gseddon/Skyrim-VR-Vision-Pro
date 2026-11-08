#!/usr/bin/env python3
"""Read-only PE import, delay import, export and TLS inventory."""
import hashlib
import collections
import json
import struct
import sys
from pathlib import Path

class PE:
    def __init__(self, path):
        self.path = Path(path); self.b = self.path.read_bytes()
        self.u16 = lambda o: struct.unpack_from('<H', self.b, o)[0]
        self.u32 = lambda o: struct.unpack_from('<I', self.b, o)[0]
        self.u64 = lambda o: struct.unpack_from('<Q', self.b, o)[0]
        p = self.u32(0x3c)
        if self.b[:2] != b'MZ' or self.b[p:p+4] != b'PE\0\0': raise ValueError('not PE')
        self.machine = self.u16(p+4); self.n = self.u16(p+6); opt = p+24
        self.bits = {0x10b:32, 0x20b:64}[self.u16(opt)]
        self.image_base = self.u64(opt+24) if self.bits == 64 else self.u32(opt+28)
        self.entry = self.u32(opt+16)
        dirs = opt + (112 if self.bits == 64 else 96)
        self.dirs = [struct.unpack_from('<II', self.b, dirs+8*i) for i in range(16)]
        self.sec = []
        for i in range(self.n):
            o = opt+self.u16(p+20)+40*i
            self.sec.append(struct.unpack_from('<IIII', self.b, o+8))
    def off(self, rva):
        for vs, va, rawsize, raw in self.sec:
            if va <= rva < va+rawsize and raw+rva-va < len(self.b): return raw+rva-va
        raise ValueError(f'unbacked RVA {rva:x}')
    def string(self, rva):
        o=self.off(rva); end=self.b.index(b'\0',o)
        return self.b[o:end].decode('ascii', 'replace')
    def thunk(self, rva):
        step=self.bits//8; read=self.u64 if step==8 else self.u32; out=[]
        for i in range(100000):
            v=read(self.off(rva+i*step))
            if not v: return out
            out.append('#'+str(v & 0xffff) if v & (1 << (self.bits-1)) else self.string(v+2))
        raise ValueError('unterminated thunks')
    def imports(self, delay=False):
        rva,size=self.dirs[13 if delay else 1]; out=[]
        if not rva or not size: return out
        width=32 if delay else 20
        for i in range(size//width):
            o=self.off(rva+i*width)
            v=struct.unpack_from('<'+('I'*(width//4)),self.b,o)
            if not any(v): break
            if delay:
                attrs,name,_,iat,intab,*_=v
                if not attrs & 1: name-=self.image_base; intab-=self.image_base; iat-=self.image_base
                table=intab or iat
            else:
                table,_,_,name,iat=v; table=table or iat
            out.append({'dll':self.string(name).lower(), 'symbols':self.thunk(table)})
        return out
    def exports(self):
        rva,size=self.dirs[0]
        if not rva or not size: return []
        o=self.off(rva); base,nfunc,nname,funcs,names,ords=struct.unpack_from('<IIIIII',self.b,o+16)
        out=['#'+str(base+i) for i in range(nfunc) if self.u32(self.off(funcs+4*i))]
        out.extend(self.string(self.u32(self.off(names+4*i))) for i in range(nname))
        return out
    def info(self):
        tls=self.dirs[9][0]; callbacks=0
        if tls:
            o=self.off(tls); cb=(self.u64(o+24) if self.bits==64 else self.u32(o+12))
            if cb:
                rv=cb-self.image_base; step=self.bits//8; read=self.u64 if step==8 else self.u32
                while callbacks<1024 and read(self.off(rv+step*callbacks)): callbacks+=1
        return {'path':str(self.path), 'sha256':hashlib.sha256(self.b).hexdigest(), 'bits':self.bits,'machine':hex(self.machine),'image_base':hex(self.image_base),'entry_rva':hex(self.entry),'tls_directory':bool(tls),'tls_callbacks':callbacks,'imports':self.imports(),'delay_imports':self.imports(True),'exports':self.exports()}

def main():
    args=sys.argv[1:]; export_file=None
    if args and args[0]=='--native-exports':
        export_file=args[1]; args=args[2:]
    images=[PE(p).info() for p in args]
    if export_file:
        native=collections.defaultdict(set)
        for line in Path(export_file).read_text().splitlines():
            fields=line.split('\t')
            if len(fields)==2: native[fields[0].lower()].add(fields[1])
        candidates={Path(x['path']).name.lower():x for x in images}
        for image in images:
            for imp in image['imports']+image['delay_imports']:
                dll=imp['dll']
                canonical='ucrtbase.dll' if dll.startswith('api-ms-win-crt-') else ('kernel32.dll' if dll.startswith('api-ms-win-core-') else dll)
                if canonical in native:
                    imp['comparison_source']='native '+canonical; available=native[canonical]
                elif dll in candidates:
                    imp['comparison_source']='candidate '+candidates[dll]['path']; available=set(candidates[dll]['exports'])
                else:
                    imp['comparison_source']='no supplied candidate or native exports'; available=set()
                imp['missing_symbols']=[x for x in imp['symbols'] if x not in available]
    print(json.dumps(images,indent=2))
if __name__=='__main__': main()
