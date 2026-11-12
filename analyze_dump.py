import sys, pathlib, struct
sys.path.insert(0, str(pathlib.Path(__file__).parent / "pytools"))
from minidump.minidumpfile import MinidumpFile

path = sys.argv[1]
mf = MinidumpFile.parse(path)
reader = mf.get_reader()

mods = sorted(mf.modules.modules, key=lambda m: m.baseaddress)

def module_of(addr):
    for m in mods:
        if m.baseaddress <= addr < m.baseaddress + m.size:
            return f"{pathlib.Path(m.name).name}+0x{addr - m.baseaddress:X}"
    return f"0x{addr:X}"

exc = mf.exception.exception_records[0]
rec = exc.ExceptionRecord
print("thread", exc.ThreadId)
print("code", hex(rec.ExceptionCode_raw), rec.ExceptionCode)
print("address", module_of(rec.ExceptionAddress))
print("params", [hex(p) for p in rec.ExceptionInformation[: rec.NumberParameters]])

ctx_thread = None
for t in mf.threads.threads:
    if t.ThreadId == exc.ThreadId:
        ctx_thread = t
        break

if ctx_thread:
    stack_lo = ctx_thread.Stack.StartOfMemoryRange
    stack_hi = stack_lo + ctx_thread.Stack.MemoryLocation.DataSize
    try:
        rsp = exc.ThreadContext and None
    except Exception:
        pass
    data = reader.read(stack_lo, stack_hi - stack_lo)
    print("stack scan (return-address candidates in known modules):")
    seen = 0
    for i in range(0, len(data) - 8, 8):
        v = struct.unpack_from("<Q", data, i)[0]
        name = module_of(v)
        if not name.startswith("0x"):
            print("  ", name)
            seen += 1
            if seen >= 40:
                break
