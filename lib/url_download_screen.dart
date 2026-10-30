// lib/audio_download_page.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'app_palette.dart';
import 'ad_widgets.dart';
import 'public_storage_service.dart';

bool isDark(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark;

/// AudioDownloadPage
class AudioDownloadPage extends StatefulWidget {
  const AudioDownloadPage({Key? key, required bool isDark}) : super(key: key);

  @override
  State<AudioDownloadPage> createState() => _AudioDownloadPageState();
}

class _AudioDownloadPageState extends State<AudioDownloadPage>
    with SingleTickerProviderStateMixin {
  final Dio _dio = Dio();
  final TextEditingController _urlController = TextEditingController(text: '');

  bool _isDownloading = false;
  double _progress = 0.0;
  String _statusMessage = '';
  String? _downloadedFilePath;

  late final AnimationController _btnController;
  late final Animation<double> _btnScale;

  static Color get kPrimary => AppPalette.accent;

  @override
  void initState() {
    super.initState();
    _btnController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 140),
      lowerBound: 0.0,
      upperBound: 0.08,
    );
    _btnScale = Tween<double>(begin: 1.0, end: 0.96).animate(
        CurvedAnimation(parent: _btnController, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _urlController.dispose();
    _btnController.dispose();
    super.dispose();
  }

  /// Scratch location the download is written to first (app-private, needs
  /// no permission). On Android it is then published to the public Downloads
  /// folder through MediaStore (PublicStorageService).
  Future<String> _getSavePath(String filename) async {
    final dir = Platform.isAndroid
        ? await getTemporaryDirectory()
        : await getApplicationDocumentsDirectory();
    return p.join(dir.path, p.basename(filename));
  }

  String _mimeFor(String name) {
    switch (p.extension(name).toLowerCase()) {
      case '.m4a':
      case '.aac':
        return 'audio/mp4';
      case '.wav':
        return 'audio/wav';
      case '.flac':
        return 'audio/flac';
      case '.ogg':
      case '.opus':
        return 'audio/ogg';
      case '.mp4':
        return 'video/mp4';
      case '.mkv':
        return 'video/x-matroska';
      default:
        return 'audio/mpeg';
    }
  }

  /// Android: copy the scratch file into Downloads via MediaStore and return
  /// the public path (or the scratch path if none is reported).
  Future<String> _finalize(String tempPath, String filename) async {
    if (!Platform.isAndroid) return tempPath;
    final pub = await PublicStorageService.instance.publish(
      sourcePath: tempPath,
      displayName: p.basename(filename),
      mimeType: _mimeFor(filename),
    );
    try {
      await File(tempPath).delete();
    } catch (_) {}
    return pub.path ?? p.join('Downloads', p.basename(filename));
  }

  String _fileNameFromHeaders(Response response, String url) {
    try {
      List<String>? headerList;
      try {
        final mp = response.headers.map;
        if (mp != null) {
          headerList = mp['content-disposition'] ?? mp['Content-Disposition'];
        }
      } catch (_) {}

      headerList ??= [];
      try {
        final maybe = response.headers.value('content-disposition');
        if (maybe != null) headerList.add(maybe);
      } catch (_) {}

      if (headerList.isNotEmpty) {
        final cdStr = headerList.join('; ');
        final reg = RegExp(r'''filename\*?=(?:UTF-8'')?"?([^";\n]+)"?''',
            caseSensitive: false);
        final match = reg.firstMatch(cdStr);
        if (match != null && match.groupCount >= 1) {
          return match.group(1)!.trim();
        }
        final reg2 = RegExp(r'''filename="?([^"]+)"?''', caseSensitive: false);
        final m2 = reg2.firstMatch(cdStr);
        if (m2 != null && m2.groupCount >= 1) {
          return m2.group(1)!.trim();
        }
      }
    } catch (_) {}
    var name = url.split('/').last;
    if (name.contains('?')) name = name.split('?').first;
    if (name.isEmpty) name = 'media_${DateTime.now().millisecondsSinceEpoch}';
    return name;
  }

  void _showSnack(String text, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(text),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating));
  }

  Future<void> _startDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      _showSnack('Enter a valid URL or local path', Colors.orange);
      return;
    }

    _btnController.forward().then((_) => _btnController.reverse());
    FocusScope.of(context).unfocus();

    setState(() {
      _isDownloading = true;
      _progress = 0.0;
      _statusMessage = 'Preparing...';
      _downloadedFilePath = null;
    });

    try {
      String filename = 'media_${DateTime.now().millisecondsSinceEpoch}.mp3';
      try {
        final head = await _dio.head(url);
        filename = _fileNameFromHeaders(head, url);
      } catch (_) {
        final lower = url.toLowerCase();
        if (lower.endsWith('.mp3') ||
            lower.endsWith('.m4a') ||
            lower.endsWith('.wav')) {
          filename = url.split('/').last.split('?').first;
        } else if (lower.endsWith('.mp4') || lower.endsWith('.mkv')) {
          filename = url.split('/').last.split('?').first;
        } else {
          filename = 'media_${DateTime.now().millisecondsSinceEpoch}.mp3';
        }
      }

      final tempPath = await _getSavePath(filename);

      final parent = Directory(p.dirname(tempPath));
      if (!await parent.exists()) await parent.create(recursive: true);

      setState(() {
        _statusMessage = 'Downloading...';
      });

      if (url.startsWith('/') && await File(url).exists()) {
        final src = File(url);
        await src.copy(tempPath);
        final savePath = await _finalize(tempPath, filename);

        setState(() {
          _isDownloading = false;
          _progress = 1.0;
          _statusMessage = 'Saved to Downloads';
          _downloadedFilePath = savePath;
        });
        _showSnack('File copied to: $savePath', Colors.green);
        return;
      }

      await _dio.download(
        url,
        tempPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            setState(() {
              _progress = (received / total).clamp(0.0, 1.0);
              _statusMessage =
              'Downloading: ${(received / 1024 / 1024).toStringAsFixed(2)} MB / ${(total / 1024 / 1024).toStringAsFixed(2)} MB';
            });
          } else {
            setState(() {
              _statusMessage =
              'Downloading... (${(received / 1024).toStringAsFixed(0)} KB)';
            });
          }
        },
        options: Options(
          receiveTimeout: Duration.zero,
          followRedirects: true,
          validateStatus: (s) => s != null && s < 500,
        ),
      );

      final savePath = await _finalize(tempPath, filename);
      setState(() {
        _isDownloading = false;
        _progress = 1.0;
        _statusMessage = 'Download complete';
        _downloadedFilePath = savePath;
      });

      _showSnack('Saved to: $savePath', Colors.green);
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _progress = 0.0;
        _statusMessage = 'Download failed';
      });
      _showSnack('Download failed: $e', Colors.red);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1. Detect System or App Theme
    final dark = isDark(context);

    // 2. Define Colors based on brightness
    final bg = dark ? AppPalette.darkBackground : Colors.white;
    final cardColor = dark ? AppPalette.darkCard : Colors.white;
    final textColor = dark ? Colors.white : Colors.black;
    final secondary = dark ? Colors.grey.shade400 : Colors.black54;
    final inputFill = dark ? AppPalette.darkCard : Colors.grey.shade100;

    // 3. Status Bar Style
    final overlayStyle =
    dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        bottomNavigationBar: const BannerAdWidget(),
        backgroundColor: bg,
        appBar: AppBar(
          title: Text(
            'Media Downloader',
            style: TextStyle(color: textColor, fontWeight: FontWeight.w700),
          ),
          centerTitle: true,
          // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
          backgroundColor: dark ? AppPalette.darkBackground : Colors.white,
          elevation: 0,
          leading: IconButton(tooltip: 'Back', 
            icon: Icon(Icons.arrow_back, color: textColor),
            onPressed: () => Navigator.of(context).pop(),
          ),
          systemOverlayStyle: overlayStyle,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Circular Header Icon
                Center(
                  child: Container(
                    height: 110,
                    width: 110,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: kPrimary.withOpacity(0.12),
                    ),
                    child: Icon(Icons.cloud_download,
                        size: 56, color: kPrimary),
                  ),
                ),
                const SizedBox(height: 28),

                // URL Input Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(dark ? 0.2 : 0.05),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      )
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Download direct MP3 audio files using URL links',
                          style: TextStyle(
                              color: textColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 15)),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _urlController,
                        style: TextStyle(color: textColor),
                        decoration: InputDecoration(
                          hintText: 'https://example.com/song.mp3',
                          hintStyle: TextStyle(color: secondary),
                          filled: true,
                          fillColor: inputFill,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none),
                          prefixIcon: Icon(Icons.link, color: kPrimary),
                          suffixIcon: IconButton(tooltip: 'Paste', 
                            icon: Icon(Icons.paste, color: secondary),
                            onPressed: () async {
                              final data =
                              await Clipboard.getData(Clipboard.kTextPlain);
                              if (data?.text != null) {
                                _urlController.text = data!.text!;
                              }
                            },
                          ),
                        ),
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.done,
                      ),
                      const SizedBox(height: 8),
                      Text('Tip: Paste only MP3 audio files link only',
                          style: TextStyle(color: secondary, fontSize: 12)),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Download Status
                if (_isDownloading || _progress > 0) ...[
                  Text(_statusMessage,
                      style: TextStyle(color: textColor, fontSize: 13),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      backgroundColor: inputFill,
                      value: _isDownloading
                          ? _progress
                          : (_progress == 1.0 ? 1.0 : null),
                      valueColor: AlwaysStoppedAnimation<Color>(kPrimary),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_isDownloading)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                          '${(_progress * 100).clamp(0, 100).toInt()}%',
                          style: TextStyle(
                              color: kPrimary, fontWeight: FontWeight.w700)),
                    ),
                  const SizedBox(height: 18),
                ],

                // Download Button (Hidden after successful download)
                if (_downloadedFilePath == null)
                  ScaleTransition(
                    scale: _btnScale,
                    child: ElevatedButton(
                      onPressed: _isDownloading ? null : _startDownload,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kPrimary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 6,
                        shadowColor: kPrimary.withOpacity(0.35),
                      ),
                      child: _isDownloading
                          ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.2))
                          : const Text('DOWNLOAD NOW',
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6)),
                    ),
                  ),

                const SizedBox(height: 22),

                // Result/Success Area
                if (_downloadedFilePath != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.green.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border:
                      Border.all(color: Colors.green.withOpacity(0.18)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.check_circle, color: Colors.green),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Download successful',
                                    style: TextStyle(
                                        color: Colors.green,
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 6),
                                Text(p.basename(_downloadedFilePath!),
                                    style: TextStyle(color: textColor)),
                                const SizedBox(height: 4),
                                Text(_downloadedFilePath!,
                                    style: TextStyle(
                                        color: secondary, fontSize: 12),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                              ]),
                        ),
                        IconButton(
                          tooltip: 'Open file',
                          onPressed: () async {
                            try {
                              final file = File(_downloadedFilePath!);
                              if (await file.exists()) {
                                _showSnack(
                                    'File saved: ${p.basename(_downloadedFilePath!)}',
                                    Colors.green);
                              } else {
                                _showSnack('File not found', Colors.orange);
                              }
                            } catch (e) {
                              _showSnack(
                                  'Cannot open file location', Colors.orange);
                            }
                          },
                          icon: const Icon(Icons.folder_open),
                          color: kPrimary,
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 28),

                // Footer
                Center(
                  child: Text(
                      'By downloading you accept terms and device storage rules.',
                      style: TextStyle(color: secondary, fontSize: 12),
                      textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}