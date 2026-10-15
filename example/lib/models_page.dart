import 'package:flutter/material.dart';
import 'package:transcribe_cpp/transcribe_cpp.dart';

import 'models.dart';

/// Downloads in progress, kept outside the pages so one can be cancelled
/// after leaving and coming back.
final _downloads = <ModelId, CancelToken>{};

/// Every model the package can run, with the recommended ones on top.
///
/// Pops with the [ModelId] the user chose to use, or null.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key, required this.models, required this.selected});

  final ModelManager models;
  final ModelId? selected;

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  late final _groups = groupCatalogue(widget.models.available);
  var _query = '';

  ModelGroup _groupOf(ModelId id) =>
      _groups.firstWhere((g) => g.sizes.any((d) => d.id == id));

  Future<void> _open(ModelGroup group, {ModelId? focus}) async {
    final chosen = await Navigator.of(context).push<ModelId>(
      MaterialPageRoute(
        builder: (_) => ModelDetailPage(
          models: widget.models,
          group: group,
          selected: widget.selected,
          focus: focus,
        ),
      ),
    );
    if (chosen != null && mounted) Navigator.of(context).pop(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final query = _query.trim().toLowerCase();
    final matches = [
      for (final g in _groups)
        if (query.isEmpty ||
            g.name.toLowerCase().contains(query) ||
            g.first.family.toLowerCase().contains(query) ||
            g.first.languages.any((l) => l.toLowerCase() == query))
          g,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Models')),
      body: ValueListenableBuilder(
        valueListenable: widget.models.installed,
        builder: (context, installed, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          children: [
            if (query.isEmpty) ...[
              _SectionTitle('Recommended'),
              for (final pick in recommended)
                if (widget.models.catalog[pick.id] case final d?)
                  _RecommendedCard(
                    title: pick.title,
                    note: pick.note,
                    descriptor: d,
                    status: installed[pick.id],
                    inUse: pick.id == widget.selected,
                    onTap: () => _open(_groupOf(pick.id), focus: pick.id),
                  ),
              const SizedBox(height: 12),
            ],
            _SectionTitle('All models'),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SearchBar(
                hintText: 'Search by name, family or language code',
                leading: const Icon(Icons.search),
                elevation: const WidgetStatePropertyAll(0),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            for (final g in matches)
              _ModelTile(
                group: g,
                installed: g.sizes
                    .where((d) => installed[d.id] == ModelStatus.installed)
                    .length,
                inUse: g.sizes.any((d) => d.id == widget.selected),
                onTap: () => _open(g),
              ),
            if (matches.isEmpty)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'No model matches "$_query".',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 16),
            FutureBuilder(
              // Keyed on the statuses so it is recounted after a change.
              key: ValueKey(installed),
              future: widget.models.bytesOnDisk(),
              builder: (context, snapshot) => Text(
                snapshot.hasData
                    ? 'Downloaded models use ${formatBytes(snapshot.data!)}.'
                    : '',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

class _RecommendedCard extends StatelessWidget {
  const _RecommendedCard({
    required this.title,
    required this.note,
    required this.descriptor,
    required this.status,
    required this.inUse,
    required this.onTap,
  });

  final String title;
  final String note;
  final ModelDescriptor descriptor;
  final ModelStatus? status;
  final bool inUse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card.filled(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(note, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    Text(
                      formatBytes(descriptor.sizeBytes),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusBadge(
                installed: status == ModelStatus.installed,
                inUse: inUse,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.group,
    required this.installed,
    required this.inUse,
    required this.onTap,
  });

  final ModelGroup group;
  final int installed;
  final bool inUse;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final d = group.first;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: Text(group.name),
      subtitle: Text(
        '${formatLanguages(d.languages)} · from ${formatBytes(d.sizeBytes)}',
      ),
      trailing: _StatusBadge(installed: installed > 0, inUse: inUse),
      onTap: onTap,
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.installed, required this.inUse});

  final bool installed;
  final bool inUse;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (inUse) {
      return Chip(
        label: const Text('Selected'),
        visualDensity: VisualDensity.compact,
        backgroundColor: scheme.primaryContainer,
        side: BorderSide.none,
      );
    }
    if (installed) {
      return Icon(Icons.download_done, color: scheme.primary);
    }
    return Icon(Icons.chevron_right, color: scheme.outline);
  }
}

/// One model: what it is, and each of its sizes to download, use or delete.
class ModelDetailPage extends StatelessWidget {
  const ModelDetailPage({
    super.key,
    required this.models,
    required this.group,
    required this.selected,
    this.focus,
  });

  final ModelManager models;
  final ModelGroup group;
  final ModelId? selected;

  /// The size to highlight, when arriving from a recommendation.
  final ModelId? focus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = group.first;
    final suggested = focus ?? group.suggested.id;
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      body: ValueListenableBuilder(
        valueListenable: models.installed,
        builder: (context, installed, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _Fact(Icons.translate, formatLanguages(d.languages)),
                _Fact(Icons.memory, formatParameters(d.parameters)),
                _Fact(Icons.category_outlined, d.family),
                _Fact(Icons.gavel, d.license),
              ],
            ),
            if (d.license.contains('nc'))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'Non-commercial licence: fine to try, not to ship in a paid '
                  'app.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Text('Sizes', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Smaller sizes are quantized more and lose a little accuracy. '
              'The highlighted one is a good balance.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            for (final size in group.sizes)
              _SizeTile(
                models: models,
                descriptor: size,
                status: installed[size.id] ?? ModelStatus.notInstalled,
                suggested: size.id == suggested,
                inUse: size.id == selected,
              ),
          ],
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: Icon(icon, size: 16),
    label: Text(text),
    visualDensity: VisualDensity.compact,
  );
}

class _SizeTile extends StatelessWidget {
  const _SizeTile({
    required this.models,
    required this.descriptor,
    required this.status,
    required this.suggested,
    required this.inUse,
  });

  final ModelManager models;
  final ModelDescriptor descriptor;
  final ModelStatus status;
  final bool suggested;
  final bool inUse;

  ModelId get id => descriptor.id;

  Future<void> _download(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final cancel = _downloads[id] = CancelToken();
    try {
      await models.ensure(id, cancel: cancel);
    } on DownloadCancelledException {
      // The user asked for it.
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Download failed: $e')));
    } finally {
      if (identical(_downloads[id], cancel)) _downloads.remove(id);
    }
  }

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${descriptor.quant}?'),
        content: Text(
          'Frees ${formatBytes(descriptor.sizeBytes)}. You can download it '
          'again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await models.remove(id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = models.progressOf(id);
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 8),
      color: suggested ? theme.colorScheme.surfaceContainerLow : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: suggested
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(descriptor.quant, style: theme.textTheme.titleSmall),
                      Text(
                        formatBytes(descriptor.sizeBytes),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                ..._actions(context),
              ],
            ),
            if (status == ModelStatus.downloading && progress != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(0, 8, 8, 4),
                child: ValueListenableBuilder(
                  valueListenable: progress,
                  builder: (context, p, _) => LinearProgressIndicator(
                    value: p.fraction,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(BuildContext context) => switch (status) {
    ModelStatus.installed => [
      IconButton(
        tooltip: 'Delete',
        // The model in use is loaded; deleting it is done from another one.
        onPressed: inUse ? null : () => _delete(context),
        icon: const Icon(Icons.delete_outline),
      ),
      inUse
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('In use'),
            )
          : FilledButton.tonal(
              onPressed: () => Navigator.of(context).pop(id),
              child: const Text('Use'),
            ),
    ],
    ModelStatus.downloading => [
      TextButton(
        onPressed: _downloads[id]?.cancel,
        child: const Text('Cancel'),
      ),
    ],
    ModelStatus.partial => [
      FilledButton.tonal(
        onPressed: () => _download(context),
        child: const Text('Resume'),
      ),
    ],
    ModelStatus.notInstalled => [
      FilledButton.tonal(
        onPressed: () => _download(context),
        child: const Text('Download'),
      ),
    ],
  };
}
