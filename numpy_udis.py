import numpy as np

import udis_fast



if __name__ == "__main__":
    import sys
    import argparse
    import importlib
    
    parser = argparse.ArgumentParser()
    parser.add_argument("-c", "--cpu", help="Specify CPU type (defaults to 6502)", default="6502")
    parser.add_argument("-u", "--undocumented", help="Allow undocumented opcodes", action="store_true")
    parser.add_argument("-x", "--hex", help="Disassemble a string version of hex digits")
    parser.add_argument("-f", "--fast", action="store_true", help="Use C code for disassembly generation", default=False)
    parser.add_argument("-s", "--show", action="store_true", help="Show disassembly", default=False)
    parser.add_argument("filenames", metavar="filenames", nargs='*',
                   help="Binary files(s) to disassemble")
    args = parser.parse_args()

    disasm = udis_fast.DisassemblerWrapper(args.cpu, args.fast)

    def process(binary, show=False):
        pc = 0;
        size = len(binary)
        last = pc + size
        i = 0
        incomplete = False
        count = 0
        while pc < last or incomplete:
            disasm.clear()
            next_pc, i = disasm.next_chunk(binary, pc, last, i)
            if next_pc == pc:
                incomplete = True
                break
            pc = next_pc

            count += disasm.rows
            if show:
                for r in range(disasm.rows):
                    line = disasm.storage[r]
                    if line.strip():
                        print line

        if show:
            addr = 0
            for w in disasm.labels:
                if w > 0:
                    print "label: %04x" % addr
                addr += 1

        print "total instructions: %d" % count

    if args.hex:
        try:
            binary = args.hex.decode("hex")
        except TypeError:
            print("Invalid hex digits!")
            sys.exit()
        binary = np.fromstring(binary, dtype=np.uint8)
        process(binary, args.show)
    else:
        for filename in args.filenames:
            with open(filename, 'rb') as fh:
                binary = fh.read()
            binary = np.fromstring(binary, dtype=np.uint8)
            process(binary, args.show)
