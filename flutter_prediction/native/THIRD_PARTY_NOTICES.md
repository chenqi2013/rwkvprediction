# RWKV7 porting prototype — third-party notices

The Flutter app's `lib/rwkv_forecast.dart` is a Dart port of the feature
processor below, and `native/rwkv_minute.cpp` is a new C++ CPU implementation of
the same pinned architecture and recurrence. Changes: Dart/C++ types, independent
window execution, bounded native file parsing, native BLAS/portable matrix
multiplication and CPU BF16-edge emulation. These ports do not include the
upstream CUDA kernels. The complete Apache-2.0 license is bundled as
`native/LICENSE-APACHE-2.0`; the MIT notice below is retained in this file.

`rwkv7_features.py` is vendored from:

- https://huggingface.co/Caizus/rwkv7-ashare-1min-quantile-21m/blob/26fb7031ebb4092329bb79ce3d422283d7a14e3b/processing_rwkv7_forecast.py
- Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
- SPDX-License-Identifier: Apache-2.0
- Full license: `RWKV7-LICENSE-APACHE-2.0`.

The experimental `rwkv7_cpu.py` follows the published model architecture,
projection and normalization contract from the same model revision, and:

- https://github.com/rwkv-rs/transformers-rwkv/blob/f93dd4e01e0b565ef0390f76c6726d1d121ebbab/src/transformers/models/rwkv/modeling_rwkv.py
- Copyright 2026 The HuggingFace Inc. team. Apache-2.0.
- https://pypi.org/project/flashrwkv2/0.1.0a18/ (RWKV7 recurrence, BF16 edges,
  key normalization and readout equations). MIT license reproduced below.

No CUDA or TileLang code is bundled or executed by the CPU prototype.
Downloaded weights and source files remain in the ignored research/runtime
directory and retain their original licenses.

## FlashRWKV2 license

MIT License

Copyright (c) 2026 MoonshotAI
Copyright (c) 2026 FlashRWKV2 contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
