# Third-party licenses

`transcribe_cpp` is MIT-licensed (see [LICENSE](LICENSE)). It redistributes the
prebuilt and derived artifacts below, each under its own permissive license.

| Component | Redistributed as | License |
|-----------|------------------|---------|
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | `ios/transcribe_cpp/Frameworks/TranscribeCpp.xcframework` (compiled) | MIT |
| [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) | `lib/src/catalog.g.dart` (model metadata from its `catalog/`, generated) | MIT |
| [ggml](https://github.com/ggml-org/ggml) | linked into the same framework | MIT |
| [miniz](https://github.com/richgel999/miniz) | linked into the same framework | MIT |
| [Silero VAD](https://github.com/snakers4/silero-vad) | `assets/silero_vad.bin` (weights, converted) | MIT |

`example/assets/jfk.wav` is an excerpt of John F. Kennedy's 1961 inaugural
address, a work of the United States federal government and therefore in the
public domain. It is the same sample transcribe.cpp and whisper.cpp ship, kept
here so the VAD tests have a fixed, shareable input.

The models listed in `lib/src/catalog.g.dart` are not redistributed: an app
downloads them from Hugging Face. Each is under its own licence, recorded in
its `ModelDescriptor.license`, and several are not permissive.

Model weights (GGUF) are **not** redistributed by this package. They are
downloaded at runtime from the source the application chooses, and each carries
its own license from its own publisher.

---

## transcribe.cpp

The speech-to-text engine. Consumed as a prebuilt dynamic xcframework; see
`ios/transcribe_cpp/Package.swift` for why it is dynamic rather than static.

```
MIT License

Copyright (c) 2026 The transcribe.cpp authors

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
```

---

## ggml

The tensor library underlying transcribe.cpp, including the Metal backend used
on iOS. Vendored by transcribe.cpp and compiled into the framework above.

```
MIT License

Copyright (c) 2023-2026 The ggml authors

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
```

---

## miniz

A single-file deflate/inflate codec, used by transcribe.cpp for Whisper's
temperature-fallback heuristic. Compiled into the framework above. The comment
block at the top of the amalgamated `miniz.c` still reads "public domain" — a
stale artifact of the project's pre-relicensing history; the authoritative
license is MIT.

```
MIT License

Copyright 2013-2014 RAD Game Tools and Valve Software
Copyright 2010-2014 Rich Geldreich and Tenacious Software LLC

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
```

---

## Silero VAD

Voice activity detection. `assets/silero_vad.bin` holds the 16 kHz weights
lifted out of the official ONNX release by `tool/extract_silero_weights.py`;
`lib/src/vad.dart` and `src/silero_vad.c` are an independent implementation of
the same four-layer architecture, written so the package does not have to carry
a second inference runtime.

```
MIT License

Copyright (c) 2024 Silero Team

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
```
