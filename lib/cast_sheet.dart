// lib/cast_sheet.dart
//
// Cast button sheet: pick a Chromecast / Google TV / Nest speaker, then
// control playback on it.

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'app_palette.dart';
import 'cast_service.dart';

Future<void> showCastSheet(BuildContext context, {String Function(String path)? titleFor}) async {
  final cast = CastService.instance;
  final available = await cast.isAvailable();
  if (!context.mounted) return;
  if (!available) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Casting needs Google Play services, which isn\'t available on this device.'),
      behavior: SnackBarBehavior.floating,
    ));
    return;
  }
  await cast.startDiscovery();
  if (!context.mounted) return;
  final dark = Theme.of(context).brightness == Brightness.dark;
  final bg = dark ? AppPalette.darkCard : Colors.white;
  final text = dark ? Colors.white : Colors.black87;
  final sub = dark ? Colors.white60 : Colors.black54;
  String fmt(Duration d) => '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  await showModalBottomSheet(
    context: context,
    backgroundColor: bg,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: ValueListenableBuilder<String?>(
          valueListenable: cast.connectedDevice,
          builder: (ctx, device, _) {
            if (device == null) {
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.cast_rounded, color: AppPalette.accent),
                  const SizedBox(width: 10),
                  Text('Cast to a device', style: TextStyle(color: text, fontSize: 18, fontWeight: FontWeight.bold)),
                  const Spacer(),
                  const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                ]),
                const SizedBox(height: 6),
                Text('Your phone and the Chromecast / Google TV / Nest speaker must be on the same Wi-Fi.',
                    style: TextStyle(color: sub, fontSize: 12)),
                const SizedBox(height: 8),
                ValueListenableBuilder<List<CastDevice>>(
                  valueListenable: cast.devices,
                  builder: (ctx, list, _) => list.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Center(child: Text('Looking for devices…', style: TextStyle(color: sub))),
                        )
                      : Column(children: [
                          for (final d in list)
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.tv_rounded, color: AppPalette.accent),
                              title: Text(d.name, style: TextStyle(color: text, fontWeight: FontWeight.w600)),
                              subtitle: d.description.isEmpty ? null : Text(d.description, style: TextStyle(color: sub, fontSize: 12)),
                              onTap: () => cast.connect(d),
                            ),
                        ]),
                ),
                ValueListenableBuilder<String?>(
                  valueListenable: cast.error,
                  builder: (ctx, e, _) => e == null ? const SizedBox.shrink() : Text(e, style: const TextStyle(color: Colors.redAccent)),
                ),
              ]);
            }
            return ValueListenableBuilder<CastStatus>(
              valueListenable: cast.status,
              builder: (ctx, st, _) {
                final path = cast.castingPath.value;
                final title = path == null ? 'Nothing playing' : (titleFor?.call(path) ?? p.basenameWithoutExtension(path));
                final max = st.duration.inMilliseconds.toDouble();
                return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.cast_connected_rounded, color: AppPalette.accent),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Casting to $device', style: TextStyle(color: text, fontSize: 17, fontWeight: FontWeight.bold))),
                  ]),
                  const SizedBox(height: 14),
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: text, fontSize: 16, fontWeight: FontWeight.w600)),
                  Slider(
                    value: st.position.inMilliseconds.toDouble().clamp(0, max <= 0 ? 1 : max),
                    max: max <= 0 ? 1 : max,
                    activeColor: AppPalette.accent,
                    onChanged: max <= 0 ? null : (_) {},
                    onChangeEnd: (v) => cast.seek(Duration(milliseconds: v.toInt())),
                  ),
                  Row(children: [
                    Text(fmt(st.position), style: TextStyle(color: sub, fontSize: 12)),
                    const Spacer(),
                    Text(fmt(st.duration), style: TextStyle(color: sub, fontSize: 12)),
                  ]),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    IconButton(tooltip: 'Previous', iconSize: 34, icon: Icon(Icons.skip_previous_rounded, color: text), onPressed: cast.previous),
                    const SizedBox(width: 12),
                    IconButton.filled(tooltip: st.playing ? 'Pause' : 'Play', 
                      iconSize: 40,
                      style: IconButton.styleFrom(backgroundColor: AppPalette.accent),
                      icon: Icon(st.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: Colors.white),
                      onPressed: cast.togglePlay,
                    ),
                    const SizedBox(width: 12),
                    IconButton(tooltip: 'Next', iconSize: 34, icon: Icon(Icons.skip_next_rounded, color: text), onPressed: cast.next),
                  ]),
                  Row(children: [
                    Icon(Icons.volume_down_rounded, color: sub),
                    Expanded(
                      child: Slider(
                        value: st.volume.clamp(0, 1),
                        activeColor: AppPalette.accent,
                        onChanged: (v) => cast.setVolume(v),
                      ),
                    ),
                    Icon(Icons.volume_up_rounded, color: sub),
                  ]),
                  Center(
                    child: TextButton.icon(
                      onPressed: () async {
                        await cast.disconnect();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: Icon(Icons.cast_rounded, color: sub),
                      label: Text('Stop casting', style: TextStyle(color: sub)),
                    ),
                  ),
                ]);
              },
            );
          },
        ),
      ),
    ),
  );
  if (!cast.isConnected) await cast.stopDiscovery();
}
