---
title: Models
description: Choose a speech model, download it with progress, and manage what is on the device.
---

transcribe_cpp does not ship a model inside your app. Models are tens to
hundreds of megabytes, so your app downloads the one it needs, usually at
first launch, and keeps it.

## Which model?

Start with one of these two. Both are English.

| Model | Download | Word error rate* | Good for |
|---|---|---|---|
| `parakeet-tdt_ctc-110m-Q4_K_M` | 90 MB | 2.5% | Most apps. Fast and accurate. |
| `moonshine-streaming-tiny-Q8_0` | 50 MB | 4.5% | When download size matters most. |

\* LibriSpeech test-clean, as published in
[transcribe.cpp's model catalogue](https://github.com/handy-computer/transcribe.cpp/tree/main/catalog).
Real-world speech is harder; try a model with your own users' audio.

The package knows many more models, including other languages: every model
transcribe.cpp publishes up to 1 GB. List them with `models.available`. A model
being listed does not mean it is practical on a phone; the larger ones are
slower and use more memory.

Model licences differ, and some are non-commercial. Check
`ModelDescriptor.license` before you ship one.

## Download a model

```dart
final models = await ModelManager.open();

final model = await models.ensure(
  const ModelId('parakeet-tdt_ctc-110m-Q4_K_M'),
);
```

`ensure` returns the model at once if it is already on the device. Otherwise it
downloads it, checks the file against its published SHA-256, and only then
returns it. The package never downloads anything on its own: nothing happens
until you call `ensure`.

- **Interrupted downloads resume.** If the app is closed or the network drops,
  the next `ensure` continues from where it stopped.
- **Shared downloads.** Two parts of your app asking for the same model share
  one download.
- **Space is checked first.** If the device does not have room, `ensure` throws
  `InsufficientStorageException` before downloading anything.
- **Not during a session.** `ensure` refuses to start a download while a
  session is transcribing, because the two would compete for the phone.

### Show progress

```dart
final progress = models.progressOf(id); // null when not downloading

ValueListenableBuilder(
  valueListenable: progress!,
  builder: (context, p, _) => LinearProgressIndicator(value: p.fraction),
)
```

### Let the user cancel

```dart
final cancel = CancelToken();
final download = models.ensure(id, cancel: cancel);

// later, from a Cancel button:
cancel.cancel(); // ensure throws DownloadCancelledException
```

What was already downloaded is kept, so starting again resumes.

### Show what is installed

`models.installed` holds the status of every model: `notInstalled`, `partial`,
`downloading` or `installed`. It is correct from the first frame, so a picker
built on it never offers to download a model that is already there.

```dart
ValueListenableBuilder(
  valueListenable: models.installed,
  builder: (context, status, _) => Text('${status[id]}'),
)
```

## Remove a model

```dart
await models.remove(id);           // the file and any partial download
final bytes = await models.bytesOnDisk();
```

## Where models are stored

On iOS, in Application Support, excluded from iCloud backup. On Android, in the
app's no-backup directory. Either way, models are not backed up, and they
survive app updates.

## Your own models

To offer a model the catalogue does not list, such as a fine-tune on your own
server, describe it yourself:

```dart
final mine = ModelDescriptor(
  id: const ModelId('my-model-Q4_K_M'),
  variant: 'my-model',
  quant: 'Q4_K_M',
  family: 'parakeet', // the engine loader it needs
  displayName: 'My model',
  languages: const ['en'],
  license: 'proprietary',
  parameters: 114000000,
  sizeBytes: 89989600,
  sha256: '…',
  url: Uri.parse('https://example.com/my-model-Q4_K_M.gguf'),
  headers: const {'Authorization': 'Bearer …'}, // only sent to that host
);

final models = await ModelManager.open(
  catalog: ModelCatalog.bundled().withEntries([mine]),
);
```
