from libc.stdio cimport printf
import cython
import numpy as np
cimport numpy as np

from libudis.libudis cimport history_entry_t, emulator_history_t, parse_func_t, string_func_t

from libudis.declarations cimport find_parse_function, find_string_function

from omni8bit.disassembler.dtypes import HISTORY_ENTRY_DTYPE

cdef extern:
    string_func_t stringifier_map[]


cdef char *hexdigits_lower = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"
cdef char *hexdigits_upper = "000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F202122232425262728292A2B2C2D2E2F303132333435363738393A3B3C3D3E3F404142434445464748494A4B4C4D4E4F505152535455565758595A5B5C5D5E5F606162636465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F808182838485868788898A8B8C8D8E8F909192939495969798999A9B9C9D9E9FA0A1A2A3A4A5A6A7A8A9AAABACADAEAFB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0E1E2E3E4E5E6E7E8E9EAEBECEDEEEFF0F1F2F3F4F5F6F7F8F9FAFBFCFDFEFF"


cdef class TextStorage:
    cdef int max_lines
    cdef public int num_lines
    cdef public np.ndarray text_starts
    cdef np.uint16_t *text_starts_data
    cdef public np.ndarray line_lengths
    cdef np.uint16_t *line_lengths_data
    cdef public np.ndarray text_buffer
    cdef char *text_buffer_data
    cdef text_buffer_size
    cdef char *text_ptr
    cdef int text_index

    def __init__(self, max_lines):
        self.text_starts = np.zeros(max_lines, dtype=np.uint16)
        self.text_starts_data = <np.uint16_t *>self.text_starts.data
        self.line_lengths = np.zeros(max_lines, dtype=np.uint16)
        self.line_lengths_data = <np.uint16_t *>self.line_lengths.data
        self.text_buffer_size = max_lines * 256
        self.text_buffer = np.zeros(self.text_buffer_size + 1000, dtype=np.uint8)
        self.text_buffer_data = <char *>self.text_buffer.data
        self.max_lines = max_lines
        self.clear()

    def __len__(self):
        return self.num_lines

    def __getitem__(self, index):
        if isinstance(index, slice):
            lines = []
            for i in range(*index.indices(len(self))):
                start = self.text_starts[i]
                lines.append(self.text_buffer[start:start + self.line_lengths[i]].tostring())
            return lines
        elif isinstance(index, int):
            start = self.text_starts[index]
            return self.text_buffer[start:start + self.line_lengths[index]].tostring()
        else:
            raise TypeError(f"index must be int or slice, not {type(index)}")

    def __iter__(self):
        for i in range(self.num_lines):
            start = self.text_starts[i]
            yield self.text_buffer[start:start + self.line_lengths[i]].tostring()

    def clear(self):
        self.num_lines = 0
        self.text_index = 0
        self.text_ptr = self.text_buffer_data

    def store(self, count):
        self.text_starts_data[self.num_lines] = self.text_index
        self.line_lengths_data[self.num_lines] = count
        self.text_index += count
        self.text_ptr += count
        self.num_lines += 1


cdef class StringifiedDisassembly:
    cdef public int origin
    cdef public int last_pc
    cdef public int start_index
    cdef public np.ndarray labels
    cdef np.uint16_t *labels_data

    cdef public TextStorage disasm_text

    # internals
    cdef int mnemonic_case
    cdef char *hex_case

    def __init__(self, start_index, max_lines, labels, mnemonic_lower=True, hex_lower=True):
        self.start_index = start_index
        self.disasm_text = TextStorage(max_lines)
        self.mnemonic_case = 1 if mnemonic_lower else 0
        self.hex_case = hexdigits_lower if hex_lower else hexdigits_upper
        self.labels = labels
        self.labels_data = <np.uint16_t *>self.labels.data
        self.clear()
        # for disassembler_type in range(40):
        #     printf("stringifier[%d] = %lx\n", disassembler_type, stringifier_map[disassembler_type])

    def __len__(self):
        return self.disasm_text.num_lines

    def __getitem__(self, index):
        if isinstance(index, slice):
            lines = []
            for i in range(*index.indices(len(self))):
                lines.append(self.disasm_text[i])
            return lines
        elif isinstance(index, int):
            return self.disasm_text[index]

        else:
            raise TypeError(f"index must be int or slice, not {type(index)}")

    def __iter__(self):
        for i in range(len(self)):
            yield self.disasm_text[i]

    def clear(self):
        self.origin = 0
        self.last_pc = 0
        self.disasm_text.clear()

    cdef parse_history_entries(self, history_entry_t *h, int num_entries):
        if num_entries > self.disasm_text.max_lines:
            num_entries = self.disasm_text.max_lines
        cdef int count
        cdef string_func_t stringifier

        self.disasm_text.clear()
        while num_entries > 0:
            stringifier = stringifier_map[h.disassembler_type]
            # printf("disassembler: %d, stringifier: %lx\n", h.disassembler_type, stringifier)
            count = stringifier(h, self.disasm_text.text_ptr, self.hex_case, self.mnemonic_case, self.labels_data)
            self.disasm_text.store(count)
            num_entries -= 1
            h += 1


cdef class ParsedDisassembly:
    cdef history_entry_t *history_entries
    cdef public int max_entries
    cdef int entry_size
    cdef public np.ndarray raw_entries
    cdef int num_entries
    cdef public int origin
    cdef int last_pc
    cdef int current_pc
    cdef public np.ndarray labels
    cdef np.uint16_t *labels_data
    cdef public int num_bytes
    cdef np.uint32_t *index_to_row_data
    cdef public np.ndarray index_to_row
    cdef int index_index
    cdef int max_text_lines

    def __init__(self, max_entries, origin, num_bytes):
        self.max_entries = max_entries
        self.entry_size = sizeof(history_entry_t)
        self.raw_entries = np.zeros(max_entries * self.entry_size, dtype=np.uint8)
        self.history_entries = <history_entry_t *>self.raw_entries.data
        self.num_entries = 0
        self.origin = origin
        self.last_pc = origin
        self.current_pc = origin
        self.labels = np.zeros(256*256, dtype=np.uint16)
        self.labels_data = <np.uint16_t *>self.labels.data

        self.num_bytes = num_bytes
        self.index_to_row = np.zeros(num_bytes + 1, dtype=np.uint32)
        self.index_to_row_data = <np.uint32_t *>self.index_to_row.data
        self.index_index = 0

        self.max_text_lines = 256

    def __len__(self):
        return self.num_entries

    cdef parse_next(self, parse_func_t processor, unsigned char *src, int num_bytes):
        cdef history_entry_t *h = &self.history_entries[self.num_entries]
        cdef int last_pc = self.current_pc + num_bytes
        cdef np.uint32_t *index_list = self.index_to_row_data
        cdef int i
        while self.current_pc < last_pc and self.num_entries < self.max_entries:
            if num_bytes > 0:
                count = processor(h, src, self.current_pc, last_pc, self.labels_data)
                src += count
                num_bytes -= count
                self.current_pc += count
                for i in range(count):
                    index_list[self.index_index] = self.num_entries
                    self.index_index += 1
                self.num_entries += 1
                h += 1
            else:
                break

    cdef fix_offset_labels(self):
        # fast loop in C to check for references to addresses that are in the
        # middle of an instruction. If found, a label is generated at the first
        # byte of the instruction
        cdef int pc = self.origin
        cdef int i = self.num_bytes
        cdef np.uint16_t *labels = self.labels_data
        cdef np.uint32_t *index_to_row = self.index_to_row_data
        cdef int old_label

        #print "pc=%04x, last=%04x, i=%04x" % (pc, pc + i, i)
        while i > 0:
            i -= 1
            old_label = labels[pc + i]
            if old_label:
                #print "disasm_info: found label %04x, index_to_row[%04x]=%04x" % (pc + i, i, index_to_row[i])
                while index_to_row[i - 1] == index_to_row[i] and i > 1:
                    i -= 1
                #if labels[pc + i] == 0:
                #    print "  disasm_info: added label at %04x" % (pc + i)
                labels[pc + i] = old_label

    def parse_test(self, cpu_type, np.ndarray[np.uint8_t, ndim=1] src):
        cdef parse_func_t processor
        cdef char *c_cpu_type

        cpu_type_bytes = cpu_type.encode('utf-8')
        c_cpu_type = cpu_type_bytes
        processor = find_parse_function(c_cpu_type)
        # printf("processor = %lx\n", processor)
        self.parse_next(processor, <unsigned char *>src.data, len(src))

    def stringify(self, int index, int num_lines_requested, mnemonic_lower=True, hex_lower=True):
        cdef history_entry_t *h = &self.history_entries[index]
        output = StringifiedDisassembly(index, num_lines_requested, self.labels, mnemonic_lower, hex_lower)
        output.parse_history_entries(h, num_lines_requested)
        return output


cdef int data_style = 1

cdef class DisassemblyConfig:
    cdef np.uint8_t c_split_comments[8]
    cdef parse_func_t segment_parsers[8]

    def __init__(self, split_comments=[data_style]):
        for i in range(8):
            self.c_split_comments[i] = 1 if i in split_comments else 0
            self.segment_parsers[i] = NULL

    def register_parser(self, cpu, id):
        tmp_cpu = cpu.encode('utf-8')
        cdef char *search_name = tmp_cpu
        cdef parse_func_t f
        f = find_parse_function(search_name)
        if f != NULL:
            self.segment_parsers[id] = f
        else:
            raise RuntimeError(f"No disassembler available for {cpu}")
        # for i in range(8):
        #     printf("segment_parsers[%d] = %lx\n", i, self.segment_parsers[i])

    def get_parser(self, num_entries, origin, num_bytes):
        return ParsedDisassembly(num_entries, origin, num_bytes)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    def parse(self, segment, num_entries):
        cdef np.uint8_t s, s2
        cdef int user_bit_mask = 0x7
        cdef int comment_bit_mask = 0x40

        src_copy = segment.data.tobytes()
        cdef np.uint8_t *src = <np.uint8_t *>src_copy
        cdef np.ndarray style_copy = segment.get_comment_locations(user=user_bit_mask)
        cdef np.uint8_t *c_style = <np.uint8_t *>style_copy.data
        cdef num_bytes = len(style_copy)

        cdef int origin = segment.origin
        cdef int end_addr = origin + len(segment)
        cdef int pc = origin

        if num_bytes < 1:
            return self.get_parser(0, origin, 0)
        cdef ParsedDisassembly parsed = self.get_parser(num_entries, origin, num_bytes)

        cdef int first_index = 0
        cdef int base_style = c_style[0] & user_bit_mask
        cdef int start_index, end_index, chunk_type
        cdef history_entry_t *h = parsed.history_entries
        cdef int count
        cdef char *temp[256]
        # print "CYTHON FAST_GET_ENTIRE", style_copy
        ranges = []
        for end_index in range(1, num_bytes):
            s = style_copy[end_index]
            s2 = s & user_bit_mask
            # print "%04x" % i, s, s2,
            if s & comment_bit_mask:
                if s2 == base_style and not self.c_split_comments[s2]:
                    # print "same w/skippable comment"
                    continue
            elif s2 == base_style:
                # print "same"
                continue

            # process chuck here:
            start_index = first_index
            count = end_index - start_index
            chunk_type = base_style
            # print("break here -> %x:%x = %s" % (start_index, end_index, chunk_type))
            processor = self.segment_parsers[chunk_type]
            parsed.parse_next(processor, src, count)
            src += count
            first_index = end_index
            base_style = s2

        # process last chunk
        start_index = first_index
        end_index += 1  # i is last byte tested, need +1 to include it in the range
        count = end_index - start_index
        # print("final break here -> %x:%x = %s, count=%x" % (start_index, end_index, base_style, num_bytes))
        processor = self.segment_parsers[base_style]
        parsed.parse_next(processor, src, count)

        parsed.fix_offset_labels()

        return parsed


cdef class StringifiedHistory:
    cdef public int origin
    cdef public int last_pc
    cdef public int start_index
    cdef public np.ndarray labels
    cdef np.uint16_t *labels_data

    cdef public TextStorage history_text
    cdef public TextStorage result_text

    # internals
    cdef int mnemonic_case
    cdef char *hex_case

    def __init__(self, max_lines, mnemonic_lower=True, hex_lower=True):
        self.history_text = TextStorage(max_lines)
        self.result_text = TextStorage(max_lines)
        self.mnemonic_case = 1 if mnemonic_lower else 0
        self.hex_case = hexdigits_lower if hex_lower else hexdigits_upper
        self.clear()
        self.labels = np.zeros(256*256, dtype=np.uint16)
        self.labels_data = <np.uint16_t *>self.labels.data

    def __len__(self):
        return self.history_text.num_lines

    def __getitem__(self, index):
        if isinstance(index, slice):
            lines = []
            for i in range(*index.indices(len(self))):
                lines.append((self.history_text[i], self.result_text[i]
))
            return lines
        elif isinstance(index, int):
            return self.history_text[index], self.result_text[index]

        else:
            raise TypeError(f"index must be int or slice, not {type(index)}")

    def __iter__(self):
        for i in range(len(self)):
            yield self.history_text[i], self.result_text[i]

    def clear(self):
        self.history_text.clear()
        self.result_text.clear()

    cdef parse_history_entries(self, emulator_history_t *history, int index, int num_entries):
        if num_entries > self.history_text.max_lines:
            num_entries = self.history_text.max_lines
        cdef int count
        cdef int disassembler_type
        cdef string_func_t stringifier
        cdef history_entry_t *h

        self.clear()
        while num_entries > 0:
            h = &history.entries[index]
            disassembler_type = h.disassembler_type
            stringifier = stringifier_map[disassembler_type]
            # printf("disassembler: %d, stringifier: %lx\n", h.disassembler_type, stringifier)
            count = stringifier(h, self.history_text.text_ptr, self.hex_case, self.mnemonic_case, self.labels_data)
            self.history_text.store(count)

            if disassembler_type < 192:
                stringifier = stringifier_map[h.disassembler_type + 1]
            # printf("disassembler: %d, stringifier: %lx\n", h.disassembler_type, stringifier)
                count = stringifier(h, self.result_text.text_ptr, self.hex_case, self.mnemonic_case, self.labels_data)
            else:
                count = 0
            self.result_text.store(count)

            num_entries -= 1
            index += 1
            if index >= history.num_allocated_entries:
                index = 0

cdef class HistoryStorage:
    cdef public np.ndarray history_array
    cdef emulator_history_t *history
    cdef public np.ndarray entries

    def __init__(self, num_entries):
        self.history_array = np.zeros(sizeof(emulator_history_t), dtype=np.uint8)
        self.history = <emulator_history_t *>self.history_array.data
        printf("libudis: __init__: history_storage: %lx\n", <int>self.history)
        self.history.num_allocated_entries = num_entries
        self.entries = np.zeros(num_entries, dtype=HISTORY_ENTRY_DTYPE)
        self.history.entries = <history_entry_t *>self.entries.data
        self.clear()

    def __len__(self):
        return self.history.num_entries

    def __getitem__(self, index):
        cdef int wrapped

        if isinstance(index, slice):
            lines = []
            for i in range(*index.indices(len(self))):
                wrapped = (i + self.history.first_entry_index) % self.history.num_allocated_entries
                lines.append(self.entries[wrapped])
            return lines
        elif isinstance(index, int):
            wrapped = (index + self.history.first_entry_index) % self.history.num_allocated_entries
            return self.entries[wrapped]
        else:
            raise TypeError(f"index must be int or slice, not {type(index)}")

    def __iter__(self):
        for i in range(self.num_lines):
            yield self.entries[i]

    @property
    def first_entry_index(self):
        return self.history.first_entry_index

    @property
    def latest_entry_index(self):
        return self.history.latest_entry_index

    @property
    def next_entry_index(self):
        cdef np.int32_t last = self.history.latest_entry_index
        cdef np.int32_t mod = self.history.num_allocated_entries
        return ((last + 1) % mod)

    @property
    def cumulative_count(self):
        return self.history.cumulative_count

    def clear(self):
        self.history.first_entry_index = 0
        self.history.latest_entry_index = -1
        self.history.num_entries = 0
        self.history.cumulative_count = 0

    def summary(self):
        start = self.history.first_entry_index
        last = self.history.latest_entry_index
        mod = self.history.num_allocated_entries
        num = self.history.num_entries
        print(f"number of entries: {mod}, used: {num}, cumulative {self.history.cumulative_count}")
        print(f"start of ring: {start}, latest: {last}")
        print("summary:", self)
        printf("libudis: history_storage: %lx\n", <int>self.history)

    def debug_range(self, from_index):
        last = self.history.latest_entry_index
        mod = self.history.num_allocated_entries
        num = self.history.num_entries
        print(f"{mod} entries; {from_index} -> {last % mod}")
        cdef i = from_index % mod
        print(f"{i}: {self.entries[i]}")
        i = (from_index+1) % mod
        print(f"{i}: {self.entries[i]}")
        print("  ...")
        i = (last - 1) % mod
        print(f"{i}: {self.entries[i]}")
        i = last % mod
        print(f"{i}: {self.entries[i]}")

    def stringify(self, int index, int num_lines_requested, mnemonic_lower=True, hex_lower=True):
        output = StringifiedHistory(num_lines_requested, mnemonic_lower, hex_lower)
        index = (self.history.first_entry_index + index) % self.history.num_allocated_entries
        output.parse_history_entries(self.history, index, num_lines_requested)
        return output
