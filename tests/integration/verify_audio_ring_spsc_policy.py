#!/usr/bin/env python3
from pathlib import Path
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: verify_audio_ring_spsc_policy.py <cpp> <hpp>", file=sys.stderr)
        return 2
    source = Path(sys.argv[1]).read_text()
    header = Path(sys.argv[2]).read_text()
    try:
        producer_start = source.index("bool Producer::OpenOrCreate")
        producer_end = source.index("std::uint64_t Producer::ConsumedFrames", producer_start)
    except ValueError as error:
        print(f"FAIL audio ring SPSC policy: missing producer boundary: {error}", file=sys.stderr)
        return 1
    producer_mutation = source[producer_start:producer_end]
    required = {
        "producer never writes consumer cursor": "read_index" not in producer_mutation,
        "atomic cross-process sample stores": "StoreSample" in producer_mutation
        and "__atomic_store_n" in source,
        "atomic cross-process sample loads": "LoadSample" in source
        and "__atomic_load_n" in source,
        "versioned atomic sample layout": "kSharedMemoryVersion = 3" in header
        and "sample_bits" in header,
    }
    failures = [name for name, passed in required.items() if not passed]
    if failures:
        print("FAIL audio ring SPSC policy: " + ", ".join(failures), file=sys.stderr)
        return 1
    print("PASS audio_ring_single_cursor_owner_and_atomic_samples")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
