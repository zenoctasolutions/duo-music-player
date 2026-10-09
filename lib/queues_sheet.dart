// lib/queues_sheet.dart
//
// "Queues" bottom sheet: the queues you were recently in (kept
// automatically) plus pinned ones. Tap to switch and resume where you were.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_palette.dart';
import 'player_screen.dart' show PlaylistContext;
import 'queue_manager.dart';

Future<void> showQueuesSheet(BuildContext context) async {
  final qm = QueueManager.instance;
  await qm.load();
  if (!context.mounted) return;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final bg = dark ? AppPalette.darkCard : Colors.white;
  final text = dark ? Colors.white : Colors.black87;
  final sub = dark ? Colors.white60 : Colors.black54;

  String fmt(int ms) {
    final d = Duration(milliseconds: ms);
    return '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  await showModalBottomSheet(
    context: context,
    backgroundColor: bg,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => ValueListenableBuilder<int>(
      valueListenable: qm.changes,
      builder: (ctx, _, __) {
        final current = PlaylistContext.getCurrentPlaylist();
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.6,
          maxChildSize: 0.9,
          builder: (ctx, scroll) => Column(children: [
            const SizedBox(height: 10),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: sub.withOpacity(0.4), borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
              child: Row(children: [
                Icon(Icons.layers_rounded, color: AppPalette.accent),
                const SizedBox(width: 10),
                Expanded(child: Text('Queues', style: TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.bold))),
                TextButton.icon(
                  onPressed: (current == null || current.isEmpty)
                      ? null
                      : () async {
                          final ctrl = TextEditingController(text: 'My queue');
                          final name = await showDialog<String>(
                            context: ctx,
                            builder: (d) => AlertDialog(
                              title: const Text('Pin current queue'),
                              content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                                FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Pin')),
                              ],
                            ),
                          );
                          if (name != null && name.trim().isNotEmpty) await qm.pinCurrent(name.trim());
                        },
                  icon: Icon(Icons.push_pin_outlined, color: AppPalette.accent, size: 18),
                  label: Text('Pin current', style: TextStyle(color: AppPalette.accent)),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text('Queues you were playing are kept automatically. Tap one to switch — it resumes where you left off.',
                  style: TextStyle(color: sub, fontSize: 12)),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: qm.queues.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text('No saved queues yet.\nPlay a different album or playlist and your current queue will appear here.',
                            textAlign: TextAlign.center, style: TextStyle(color: sub)),
                      ),
                    )
                  : ListView.builder(
                      controller: scroll,
                      itemCount: qm.queues.length,
                      itemBuilder: (_, i) {
                        final q = qm.queues[i];
                        final at = q.currentPath == null ? '' : ' · at ${p.basenameWithoutExtension(q.currentPath!)} ${fmt(q.positionMs)}';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: AppPalette.accent.withOpacity(0.15),
                            child: Icon(q.pinned ? Icons.push_pin_rounded : Icons.queue_music_rounded, color: AppPalette.accent, size: 20),
                          ),
                          title: Text(q.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: text, fontWeight: FontWeight.w600)),
                          subtitle: Text('${q.paths.length} songs$at', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: sub, fontSize: 12)),
                          onTap: () async {
                            Navigator.pop(ctx);
                            await qm.switchTo(q);
                          },
                          trailing: PopupMenuButton<String>(
                            icon: Icon(Icons.more_vert, color: sub),
                            onSelected: (v) async {
                              if (v == 'pin') await qm.togglePin(q);
                              if (v == 'delete') await qm.delete(q);
                              if (v == 'rename') {
                                final ctrl = TextEditingController(text: q.name);
                                final name = await showDialog<String>(
                                  context: ctx,
                                  builder: (d) => AlertDialog(
                                    title: const Text('Rename queue'),
                                    content: TextField(controller: ctrl, autofocus: true),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')),
                                      FilledButton(onPressed: () => Navigator.pop(d, ctrl.text), child: const Text('Save')),
                                    ],
                                  ),
                                );
                                if (name != null) await qm.rename(q, name);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(value: 'pin', child: Text(q.pinned ? 'Unpin' : 'Pin')),
                              const PopupMenuItem(value: 'rename', child: Text('Rename')),
                              const PopupMenuItem(value: 'delete', child: Text('Remove')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ]),
        );
      },
    ),
  );
}
