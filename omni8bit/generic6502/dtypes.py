# generic6502 input template locations
import numpy as np

VIDEO_WIDTH = 40
VIDEO_HEIGHT = 24

VIDEO_SIZE = VIDEO_WIDTH * VIDEO_HEIGHT
AUDIO_SIZE = 2048
STATESAV_MAX_SIZE = 80000

INPUT_DTYPE = np.dtype([
    ("keychar", np.uint8),
    ("keycode", np.uint8),
])

OUTPUT_DTYPE = np.dtype([
    ("frame_number", np.uint32),
    ("state", np.uint8, STATESAV_MAX_SIZE),
    ("video", np.uint8, VIDEO_SIZE),
    ("audio", np.uint8, AUDIO_SIZE),
])

STATESAV_DTYPE = np.dtype([
    ("total_cycles", np.uint64),
    ("PC", '<u2'),
    ("A", np.uint8),
    ("X", np.uint8),
    ("Y", np.uint8),
    ("SP", np.uint8),
    ("P", np.uint8),
    ("breakpoint_hit", np.uint8),
    ("memory", np.uint8, 1<<16),
    ])

CPU_DTYPE = np.dtype([
    ("PC", '<u2'),
    ("A", np.uint8),
    ("X", np.uint8),
    ("Y", np.uint8),
    ("SP", np.uint8),
    ("P", np.uint8),
    ])
