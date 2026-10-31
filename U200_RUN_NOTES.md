# openTPU on the U200 — run notes (2026-10-31)

Tree: this repository (`$PWD`). Card: Alveo U200 `[0000:01:00.1]`, shell
`xilinx_u200_gen3x16_xdma_base_2`, XRT 2.18.179. Host Python: a venv with torch/transformers;
run with `PYTHONPATH=$PWD` so this tree's `opentpu` package is imported.

## Image

The image used here is the S=1 / TMEM 64K / pool-window build of this tree (`make core-moe`):
`OtpuCoreKernel.xclbin`, DATA_CLK 180 MHz, md5 `d19fb6a71c0e61e909b3f2f8cd414b64`. It is a
build artifact (`.gitignore`: `*.xclbin`, `build/`), so it is not part of the sources; rebuild it
with

```sh
source /path/to/Vitis/2024.2/settings64.sh
make core-moe          # OTPU_NS=1 OTPU_TMEM_WORDS=65536 boards/u200-vitis/build_core.sh
```

and load it with `OTPU_XCLBIN=boards/u200-vitis/build/OtpuCoreKernel.xclbin`.

`targets/u200-vitis-moe.toml` is the target the image's CFG_HASH (`4ffd1e17`) matches.

The checkpoints are not in the tree either (`.gitignore`: `models/`): put Qwen3-0.6B and
Qwen3.5-35B-A3B (with its `pool-mx1-fp4.bin`) under `models/` before the runs below.

Environment shared by the card runs:

```sh
export PYTHONPATH=$PWD
export OTPU_XCLBIN=$PWD/boards/u200-vitis/build/OtpuCoreKernel.xclbin
export OTPU_TARGET=targets/u200-vitis-moe.toml
export OTPU_PAIR=1 OTPU_DSTEP=1 OTPU_STREAM=1 OTPU_SEQ_WC=1
export OTPU_XRT_BO_GROUPS=0,1   # the xclbin's CONNECTIVITY lists 4 banks; an S=1 image uses 2
```

## Self-test (ALL PASS)

```sh
otpu-lock -- python -m opentpu.host.selftest --xclbin "$OTPU_XCLBIN"
```
link, config (S=1, 2×2048 MiB, core 180 MHz, DDR4-2400), calib, scrub, regs, addr, pattern,
**window**, **pool**, kernel, vops, stream, ecc — all pass.

## Qwen3-0.6B — PASS

```sh
otpu-lock -- python tools/validate.py --model qwen3 --backend board --against isa --tokens 16
```
- device (card) vs ISA: **same tokens 8/8 prompts, logits bit-exact over 128 steps, 0 ulp**
- device vs quantized golden (W+A): top-1 **93.8 %** (≥ 80 %), KL mean 4.43e-03 =
  **1.66×** the 1-ulp floor 2.67e-03 (limit 3×)
- exit status 0, `PASS`.

## Qwen3.5-35B-A3B — PASS (experts streamed and resident)

Streamed (32 slots/layer, 96 misses/token):

```sh
otpu-lock -- python tools/offload/moe_card.py models/Qwen3.5-35B-A3B \
  --card --experts 32 --pool models/Qwen3.5-35B-A3B/pool-mx1-fp4.bin \
  --cfg /tmp/card.pkl --no-pool-map -n 2 --check /tmp/q35-ref.json
```
tokens `[90700, 8340]`, match, prefill sha `18355b345b92cc82`, 137.8 MB/token, 4.8 tok/s device.

Resident (all 256 experts/layer in per-layer slots on the card, pool window):

```sh
otpu-lock -- python tools/offload/moe_card.py models/Qwen3.5-35B-A3B \
  --card --resident --experts 0 --pool models/Qwen3.5-35B-A3B/pool-mx1-fp4.bin \
  --cfg /tmp/card.pkl --no-pool-map -n 16 --check /tmp/q35-ref.json
```
- 5 BOs/channel = 9.0 GiB a channel (18 GiB), 90.9 % experts, layer 0 window `0x4080000000`
- **16/16 greedy tokens** match the reference `[90700, 8340, 25, 271, 16, 13, 220, 2972, 2014,
  53983, 279, 5952, 64700, 198, 262, 348]`
- prefill logits sha **`18355b345b92cc82`** (the ISA simulator's and the earlier successful
  card run's)
- **misses 0, 0 expert bytes/token** over PCIe
- **9.28–9.33 device tok/s**, MXU busy 93 % (MAC 70 %), DMA 21 %, VPU 11 %


