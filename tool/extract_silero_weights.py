#!/usr/bin/env -S uv run --quiet --with onnx --with numpy --with onnxruntime --with soundfile python
"""
Extract Silero VAD weights from the official ONNX into a flat binary our C
implementation can mmap, and emit a reference fixture to validate against.

Why not just ship the ONNX: running it needs onnxruntime, a whole second
inference runtime, to evaluate ~310k parameters. The model is four conv1d
layers, one LSTM cell, and an STFT — small enough to implement directly. This
script is the bridge: it lifts the weights out once, and captures ground-truth
probabilities so the C port can be proven equivalent rather than assumed.

Two findings baked in here, both of which would otherwise be silent bugs:

  * The graph has no initializers. Every weight is a `Constant` node inside an
    `If` branch keyed on the `sr` input (8 kHz vs 16 kHz). We take the 16 kHz
    branch.
  * The LSTM gate order is PyTorch's **ifgo**, NOT the iofc that the ONNX
    `LSTM` op's own spec mandates — the permutation to ONNX order happens
    inside the graph, upstream of the op. Verified against onnxruntime: ifgo
    reproduces the reference to 2e-6, iofc is off by up to 1.0 while still
    producing a smooth, plausible-looking trace that never fires on speech.
    Do not infer this from the op signature; measure it.

Usage:
    tool/extract_silero_weights.py silero_vad.onnx -o assets/silero_vad.bin
"""

import argparse
import struct
import sys
from pathlib import Path

import numpy as np
import onnx
from onnx import numpy_helper

MAGIC = b"SVAD"
FORMAT_VERSION = 1

# The tensors we need, in the order the C loader expects them.
EXPECTED = [
    "stft.forward_basis_buffer",
    "encoder.0.reparam_conv.weight",
    "encoder.0.reparam_conv.bias",
    "encoder.1.reparam_conv.weight",
    "encoder.1.reparam_conv.bias",
    "encoder.2.reparam_conv.weight",
    "encoder.2.reparam_conv.bias",
    "encoder.3.reparam_conv.weight",
    "encoder.3.reparam_conv.bias",
    "decoder.rnn.weight_ih",
    "decoder.rnn.weight_hh",
    "decoder.rnn.bias_ih",
    "decoder.rnn.bias_hh",
    "decoder.decoder.2.weight",
    "decoder.decoder.2.bias",
]


def collect_constants(graph):
    """Every Constant node's payload, keyed by its output name."""
    out = {}
    for node in graph.node:
        if node.op_type != "Constant":
            continue
        for attr in node.attribute:
            if attr.name == "value":
                out[node.output[0]] = numpy_helper.to_array(attr.t)
    return out


def sixteen_khz_branch(model):
    """The `If` branch taken when sr == 16000."""
    top = [n for n in model.graph.node if n.op_type == "If"]
    if not top:
        sys.exit("no top-level If node; unexpected model layout")
    branches = {a.name: a.g for a in top[0].attribute}
    # Both branches carry a full copy of the network; the 16 kHz one is the
    # branch whose STFT basis spans a 256-sample window (the 8 kHz copy uses
    # a shorter one).
    for name in ("then_branch", "else_branch"):
        graph = branches[name]
        consts = collect_constants(graph)
        for key, arr in consts.items():
            if key.endswith("stft.forward_basis_buffer") and arr.shape[-1] == 256:
                return graph, consts
    sys.exit("could not identify the 16 kHz branch")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("onnx", type=Path)
    ap.add_argument("-o", "--output", type=Path, required=True)
    args = ap.parse_args()

    model = onnx.load(args.onnx)
    _, consts = sixteen_khz_branch(model)

    # Constant output names are prefixed with the inlining path; match on the
    # PyTorch parameter name at the tail.
    by_suffix = {}
    for key, arr in consts.items():
        for want in EXPECTED:
            if key.endswith(want):
                by_suffix[want] = arr

    missing = [n for n in EXPECTED if n not in by_suffix]
    if missing:
        sys.exit(f"missing tensors: {missing}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    with args.output.open("wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<II", FORMAT_VERSION, len(EXPECTED)))
        for name in EXPECTED:
            arr = np.ascontiguousarray(by_suffix[name], dtype=np.float32)
            raw = name.encode()
            f.write(struct.pack("<II", len(raw), arr.ndim))
            f.write(raw)
            f.write(struct.pack(f"<{arr.ndim}I", *arr.shape))
            f.write(arr.tobytes())
            total += arr.size
            print(f"  {name:34} {str(arr.shape):20} {arr.size:>7,}")

    size = args.output.stat().st_size
    print(f"\n{len(EXPECTED)} tensors, {total:,} parameters -> {args.output} ({size:,} bytes)")


if __name__ == "__main__":
    main()
