---
title: Acknowledgements
description: The projects and people transcribe_cpp is built on.
---

transcribe_cpp is a Flutter package around other people's work. It would not
exist without them.

## transcribe.cpp

[transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), by the
transcribe.cpp authors, is the speech engine: it loads the models and turns
audio into text. This package ships its builds for iOS and Android, generates
its model list from transcribe.cpp's catalogue, and downloads the models it
converts and publishes on
[Hugging Face](https://huggingface.co/handy-computer). The word error rates in
these docs come from that catalogue too.

transcribe_cpp is an independent project, not an official part of
transcribe.cpp.

## ggml

[ggml](https://github.com/ggml-org/ggml) is the machine-learning library
transcribe.cpp runs on, including the Metal code that runs models on the
iPhone's GPU.

## Silero VAD

[Silero VAD](https://github.com/snakers4/silero-vad) decides when someone is
speaking. Its model was ported to C for this package, and its weights ship with
it.

## The models

The speech models are the work of their authors, among them
[NVIDIA](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m) (Parakeet) and the
[Moonshine](https://huggingface.co/moonshine-ai/moonshine-streaming-tiny) team.
Each model has its own licence; some require apps to credit the authors, and
some are non-commercial. Check `ModelDescriptor.license` for each one you
ship.

## Licences

transcribe_cpp is MIT-licensed. The licences of everything it includes are in
[THIRD-PARTY-LICENSES.md](https://github.com/ishangavidusha/transcribe_cpp/blob/main/THIRD-PARTY-LICENSES.md).
