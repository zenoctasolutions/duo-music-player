// lib/ringtone_screen.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'app_palette.dart';
import 'ad_widgets.dart';

class RingtoneScreen extends StatefulWidget {
  final File file;
  final String? title;

  const RingtoneScreen({
    super.key,
    required this.file,
    this.title, required bool isDarkMode,
  });

  @override
  State<RingtoneScreen> createState() => _RingtoneScreenState();
}

class _RingtoneScreenState extends State<RingtoneScreen> {
  // MATCH THIS STRING EXACTLY WITH MAINACTIVITY.KT
  static const MethodChannel _ringtoneChannel = MethodChannel('music_app/ringtone');

  bool _setting = false;
  bool _loadingRingtones = false;

  // Accent color used for icons and buttons
  static Color get _accent => AppPalette.accent;

  // -------------------------
  // Permissions + native calls
  // -------------------------
  Future<void> _setAsRingtone() async {
    if (!Platform.isAndroid) {
      _showSnack('Setting ringtone is supported only on Android', isError: true);
      return;
    }

    // Request storage/audio permission depending on platform/version
    // permission_handler abstracts some differences; still request both if needed.
    try {
      var storageStatus = await Permission.storage.status;
      if (!storageStatus.isGranted) {
        storageStatus = await Permission.storage.request();
      }

      // For Android 13+ read-permission for audio may be required
      if (!storageStatus.isGranted) {
        final audioStatus = await Permission.audio.request();
        if (!audioStatus.isGranted) {
          _showSnack('Storage or audio permission required to set ringtone', isError: true);
          return;
        }
      }

      setState(() => _setting = true);

      final args = {
        'path': widget.file.path,
        'title': widget.title ?? p.basenameWithoutExtension(widget.file.path),
      };

      final bool? success = await _ringtoneChannel.invokeMethod('setRingtone', args);

      if (success == true) {
        _showSnack('Ringtone set successfully!', isError: false);
      } else {
        _showSnack('Failed to set ringtone.', isError: true);
      }
    } on PlatformException catch (e) {
      if (e.code == 'permission_required') {
        _showWriteSettingsDialog();
      } else {
        _showSnack('Error: ${e.message}', isError: true);
      }
    } catch (e) {
      _showSnack('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  Future<void> _showWriteSettingsDialog() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Permission Required'),
        content: const Text(
            'To change the ringtone, this app needs permission to "Modify System Settings".\n\nPlease allow it on the next screen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Open Settings')),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _ringtoneChannel.invokeMethod('openWriteSettings');
      } on PlatformException catch (e) {
        _showSnack('Could not open settings: ${e.message}', isError: true);
      } catch (e) {
        _showSnack('Could not open settings: $e', isError: true);
      }
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  Future<List<Map<String, dynamic>>> _getDeviceRingtones() async {
    // returns list of maps: id, title, data, uri, isDefault
    if (!Platform.isAndroid) return [];
    setState(() => _loadingRingtones = true);
    try {
      final List<dynamic> raw = await _ringtoneChannel.invokeMethod('getRingtones');
      final list = raw.map<Map<String, dynamic>>((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return {
          'id': m['id'],
          'title': m['title'] ?? '',
          'data': m['data'] ?? '',
          'uri': m['uri'] ?? '',
          'isDefault': m['isDefault'] == true,
        };
      }).toList();
      return list;
    } on PlatformException catch (e) {
      _showSnack('Failed to fetch ringtones: ${e.message}', isError: true);
      return [];
    } catch (e) {
      _showSnack('Failed to fetch ringtones: $e', isError: true);
      return [];
    } finally {
      if (mounted) setState(() => _loadingRingtones = false);
    }
  }

  Future<void> _showDeviceRingtonePicker() async {
    final list = await _getDeviceRingtones();
    if (!mounted) return;
    if (list.isEmpty) {
      _showSnack('No ringtones found', isError: true);
      return;
    }

    // determine colors from system brightness
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final sheetBg = isDark ? AppPalette.darkBackground : Colors.white;
    final sheetText = isDark ? Colors.white : Colors.black;
    final sheetSub = isDark ? Colors.white70 : Colors.black54;
    final dividerColor = isDark ? Colors.white10 : Colors.grey.shade300;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: sheetBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.75,
            child: Column(
              children: [
                ListTile(
                  tileColor: sheetBg,
                  title: Text('Device Ringtones', style: TextStyle(fontWeight: FontWeight.bold, color: sheetText)),
                  trailing: IconButton(
                    icon: const Icon(Icons.close),
                    color: sheetText,
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ),
                Divider(height: 1, color: dividerColor),
                Expanded(
                  child: ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => Divider(height: 1, color: dividerColor),
                    itemBuilder: (context, index) {
                      final item = list[index];
                      final title = item['title']?.toString() ?? 'Unknown';
                      final uri = item['uri']?.toString() ?? '';
                      final isDefault = item['isDefault'] == true;

                      return ListTile(
                        tileColor: sheetBg,
                        title: Text(title, style: TextStyle(color: sheetText)),
                        subtitle: Text(uri, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: sheetSub)),
                        trailing: isDefault ? Icon(Icons.check_circle, color: Colors.green) : null,
                        onTap: () async {
                          Navigator.of(ctx).pop(); // close bottom sheet
                          await _setDeviceRingtone(uri, title);
                        },
                      );
                    },
                  ),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _setDeviceRingtone(String uri, String title) async {
    if (uri.isEmpty) {
      _showSnack('Invalid ringtone URI', isError: true);
      return;
    }

    if (!Platform.isAndroid) {
      _showSnack('This operation is supported only on Android', isError: true);
      return;
    }

    setState(() => _setting = true);
    try {
      final args = {'uri': uri, 'title': title};
      final bool? success = await _ringtoneChannel.invokeMethod('setDefaultRingtoneUri', args);
      if (success == true) {
        _showSnack('Ringtone set successfully', isError: false);
      } else {
        _showSnack('Failed to set ringtone', isError: true);
      }
    } on PlatformException catch (e) {
      if (e.code == 'permission_required') {
        await _showWriteSettingsDialog();
      } else {
        _showSnack('Error: ${e.message}', isError: true);
      }
    } catch (e) {
      _showSnack('Error: $e', isError: true);
    } finally {
      if (mounted) setState(() => _setting = false);
    }
  }

  // -------------------------
  // UI
  // -------------------------
  @override
  Widget build(BuildContext context) {
    // Use system brightness for dark mode
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;

    final bgColor = isDark ? AppPalette.darkBackground : Colors.white;
    final txtColor = isDark ? Colors.white : Colors.black;
    final appBarBg = bgColor;

    return Scaffold(
      bottomNavigationBar: const BannerAdWidget(),
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text('Set Ringtone'),
        backgroundColor: appBarBg,
        foregroundColor: txtColor,
        elevation: 0,
        systemOverlayStyle: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.notifications_active, size: 60, color: _accent),
              const SizedBox(height: 20),
              Text(
                widget.title ?? p.basenameWithoutExtension(widget.file.path),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: txtColor),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _setting ? null : _setAsRingtone,
                  icon: _setting
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.sd_storage, color: Colors.white),
                  label: Text(_setting ? 'Setting...' : 'Set as Default Ringtone (this file)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  onPressed: _loadingRingtones ? null : _showDeviceRingtonePicker,
                  icon: _loadingRingtones
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Icon(Icons.library_music, color: Colors.white),
                  label: Text(_loadingRingtones ? 'Loading...' : 'Browse Device Ringtones'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
