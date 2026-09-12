#!/usr/bin/env python3
"""Decode a PoB2 export code (raw pasted code, or the base64 blob fetched from
poe.ninja's /poe2/pob/raw/<id> endpoint) into build XML.

Usage: decode_pob.py <input_file> <output_xml_file>
"""
import base64
import sys
import zlib


def decode(code: str) -> bytes:
    b = code.strip().replace("-", "+").replace("_", "/")
    b += "=" * (-len(b) % 4)
    raw = base64.b64decode(b)
    return zlib.decompress(raw)


if __name__ == "__main__":
    in_path, out_path = sys.argv[1], sys.argv[2]
    with open(in_path) as f:
        code = f.read()
    xml = decode(code)
    with open(out_path, "wb") as f:
        f.write(xml)
    print(len(xml))
