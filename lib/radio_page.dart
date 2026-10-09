// lib/radio_page.dart
//
// Internet Radio UI: country list -> station list (search + genre filter +
// pagination) -> playback via the shared AudioPlayer. Visuals intentionally
// mirror the existing app (same primary color, card/list styles, dialogs)
// instead of introducing a new design language.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'radio_service.dart';
import 'banner_ad_widget2.dart';
import 'songs_page.dart' show GlobalMiniPlayer;
import 'app_palette.dart';
import 'ad_widgets.dart';

Color get _kPrimary => AppPalette.accent;

/// Small "now playing" indicator shown on the currently active station's
/// list tile: three bars that animate while [active] (audio actually
/// playing) and freeze at a low height when the station is current but
/// paused, so paused vs. playing stay visually distinguishable.
class _NowPlayingBars extends StatefulWidget {
  final bool active;
  final Color color;
  final double barWidth;
  final double maxBarHeight;

  const _NowPlayingBars({
    required this.active,
    required this.color,
    this.barWidth = 3,
    this.maxBarHeight = 14,
  });

  @override
  State<_NowPlayingBars> createState() => _NowPlayingBarsState();
}

class _NowPlayingBarsState extends State<_NowPlayingBars> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(covariant _NowPlayingBars oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.active && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final minBarHeight = widget.maxBarHeight * 0.3;
        final swing = widget.maxBarHeight - minBarHeight;
        return SizedBox(
          width: widget.barWidth * 3 + 4,
          height: widget.maxBarHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              final phase = (_controller.value + i * 0.33) % 1.0;
              final height = widget.active
                  ? minBarHeight + swing * (0.5 + 0.5 * math.sin(phase * 2 * math.pi))
                  : minBarHeight;
              return Container(
                width: widget.barWidth,
                height: height,
                decoration: BoxDecoration(color: widget.color, borderRadius: BorderRadius.circular(widget.barWidth / 2)),
              );
            }),
          ),
        );
      },
    );
  }
}

/// Renders a station/album-art network image with a graceful fallback to
/// the existing radio icon whenever the URL is null/empty/unreachable or the
/// bytes fail to decode — matches buildCoverArt()'s fallback contract in
/// player_screen.dart, adapted for network (favicon) URLs instead of bytes.
class _StationArt extends StatelessWidget {
  final String? url;
  final bool isDark;
  final double iconSize;

  const _StationArt({required this.url, required this.isDark, this.iconSize = 24});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: isDark ? Colors.grey.shade800 : Colors.grey.shade200,
      child: Icon(Icons.radio, color: isDark ? Colors.white54 : Colors.grey, size: iconSize),
    );
    final u = url;
    if (u == null || u.trim().isEmpty) return fallback;
    return Image.network(
      u,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => fallback,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return fallback;
      },
    );
  }
}

class InternetRadioPage extends StatefulWidget {
  final AudioPlayer audioPlayer;
  final bool isDark;
  final Future<bool> Function(RadioStation station) onPlayStation;
  // False when this page is embedded as the tab body of the main
  // AudioPlayerScreen, which already renders GlobalMiniPlayer + a banner ad
  // in its own persistent bottomNavigationBar. True (default) when this page
  // is pushed as its own full-screen route (e.g. from Settings), where that
  // parent bottomNavigationBar is hidden and this page must show its own.
  final bool showMiniPlayer;

  const InternetRadioPage({
    super.key,
    required this.audioPlayer,
    required this.isDark,
    required this.onPlayStation,
    this.showMiniPlayer = true,
  });

  @override
  State<InternetRadioPage> createState() => _InternetRadioPageState();
}

class _InternetRadioPageState extends State<InternetRadioPage> {
  List<RadioCountry> _countries = [];
  List<RadioCountry> _filtered = [];
  Set<String> _pinnedCountries = {};
  bool _isLoading = true;
  String? _error;
  final TextEditingController _searchController = TextEditingController();

  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _cardColor => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _textColor => widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _subtitleColor => widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);

  @override
  void initState() {
    super.initState();
    _loadPinnedCountries();
    _load();
    _searchController.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPinnedCountries() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _pinnedCountries = (prefs.getStringList('radio_pinned_countries') ?? []).toSet();
        _applyFilter();
      });
    }
  }

  Future<void> _togglePin(RadioCountry country) async {
    final isPinned = _pinnedCountries.contains(country.countryCode);

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(isPinned ? 'Unpin Country' : 'Pin Country', style: TextStyle(color: _textColor)),
        content: Text(
          isPinned
              ? 'Do you want to unpin ${country.name}?'
              : 'Do you want to pin ${country.name} to top?',
          style: TextStyle(color: _subtitleColor),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: _subtitleColor)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kPrimary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isPinned ? 'Unpin' : 'Pin'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        if (isPinned) {
          _pinnedCountries.remove(country.countryCode);
        } else {
          _pinnedCountries.add(country.countryCode);
        }
        _applyFilter();
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('radio_pinned_countries', _pinnedCountries.toList());
    }
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final countries = await RadioBrowserService.instance.getCountries();
      if (!mounted) return;
      setState(() {
        _countries = countries;
        _isLoading = false;
        _applyFilter();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is RadioServiceException ? e.message : 'Failed to load countries.';
        _isLoading = false;
      });
    }
  }

  void _applyFilter() {
    final q = _searchController.text.trim().toLowerCase();
    List<RadioCountry> result = q.isEmpty
        ? List.from(_countries)
        : _countries.where((c) => c.name.toLowerCase().contains(q)).toList();

    result.sort((a, b) {
      final aPinned = _pinnedCountries.contains(a.countryCode);
      final bPinned = _pinnedCountries.contains(b.countryCode);

      if (aPinned && !bPinned) return -1;
      if (!aPinned && bPinned) return 1;
      return a.name.compareTo(b.name);
    });

    setState(() {
      _filtered = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: widget.isDark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        iconTheme: IconThemeData(color: _textColor),
        title: Text('Internet Radio', style: TextStyle(color: _textColor)),
        actions: [
          IconButton(
            icon: Icon(Icons.favorite_border, color: _textColor),
            tooltip: 'Favorite Stations',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RadioFavoritesPage(
                audioPlayer: widget.audioPlayer,
                isDark: widget.isDark,
                onPlayStation: widget.onPlayStation,
              ),
            )),
          ),
        ],
      ),
      bottomNavigationBar: widget.showMiniPlayer
          ? const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GlobalMiniPlayer(),
                SafeArea(
                  bottom: true,
                  child: BannerAdWidget2(),
                ),
              ],
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: _textColor),
              decoration: InputDecoration(
                hintText: 'Search countries...',
                hintStyle: TextStyle(color: _subtitleColor),
                prefixIcon: Icon(Icons.search, color: _subtitleColor),
                filled: true,
                fillColor: _cardColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: _kPrimary));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: _subtitleColor),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: _textColor, fontSize: 15)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _load,
              style: ElevatedButton.styleFrom(backgroundColor: _kPrimary),
              child: const Text('Retry', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
    if (_filtered.isEmpty) {
      return Center(
        child: Text('No countries found', style: TextStyle(color: _subtitleColor, fontSize: 15)),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _filtered.length,
      itemBuilder: (context, index) {
        final country = _filtered[index];
        final isPinned = _pinnedCountries.contains(country.countryCode);
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: _cardColor,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: Text(country.flagEmoji, style: const TextStyle(fontSize: 26)),
              title: Text(country.name, style: TextStyle(color: _textColor, fontWeight: FontWeight.w600)),
              subtitle: Text('${country.stationCount} stations', style: TextStyle(color: _subtitleColor, fontSize: 12)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    iconSize: 22,
                    icon: Icon(
                      isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                      color: isPinned ? _kPrimary : _subtitleColor,
                    ),
                    onPressed: () => _togglePin(country),
                    tooltip: isPinned ? 'Unpin' : 'Pin to top',
                  ),
                  Icon(Icons.chevron_right, color: _subtitleColor),
                ],
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => RadioStationsPage(
                  country: country,
                  audioPlayer: widget.audioPlayer,
                  isDark: widget.isDark,
                  onPlayStation: widget.onPlayStation,
                ),
              )),
            ),
          ),
        );
      },
    );
  }
}

class RadioStationsPage extends StatefulWidget {
  final RadioCountry country;
  final AudioPlayer audioPlayer;
  final bool isDark;
  final Future<bool> Function(RadioStation station) onPlayStation;

  const RadioStationsPage({
    super.key,
    required this.country,
    required this.audioPlayer,
    required this.isDark,
    required this.onPlayStation,
  });

  @override
  State<RadioStationsPage> createState() => _RadioStationsPageState();
}

class _RadioStationsPageState extends State<RadioStationsPage> {
  static const int _pageSize = 30;

  final List<RadioStation> _stations = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  List<String> _tags = [];
  String? _selectedTag;
  String _query = '';

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isGridView = true;
  String? _error;
  int _requestSeq = 0;

  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _cardColor => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _textColor => widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _subtitleColor => widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);

  @override
  void initState() {
    super.initState();
    RadioFavoritesNotifier.instance.init();
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    _loadTags();
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadTags() async {
    try {
      final tags = await RadioBrowserService.instance.getTagsForCountry(widget.country.countryCode);
      if (mounted) setState(() => _tags = tags);
    } catch (_) {}
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      _query = _searchController.text.trim();
      _loadInitial();
    });
  }

  void _onScroll() {
    if (!_hasMore || _isLoadingMore || _isLoading) return;
    if (_scrollController.position.pixels > _scrollController.position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<List<RadioStation>> _fetchPage(int offset) {
    if (_query.isNotEmpty) {
      return RadioBrowserService.instance.searchStations(
        name: _query,
        countryCode: widget.country.countryCode,
        tag: _selectedTag,
        limit: _pageSize,
        offset: offset,
      );
    }
    if (_selectedTag != null) {
      return RadioBrowserService.instance.searchStations(
        countryCode: widget.country.countryCode,
        tag: _selectedTag,
        limit: _pageSize,
        offset: offset,
      );
    }
    return RadioBrowserService.instance.getStationsByCountryCode(
      widget.country.countryCode,
      limit: _pageSize,
      offset: offset,
    );
  }

  Future<void> _loadInitial() async {
    final mySeq = ++_requestSeq;
    setState(() {
      _isLoading = true;
      _error = null;
      _hasMore = true;
    });
    try {
      final stations = await _fetchPage(0);
      if (mySeq != _requestSeq || !mounted) return;
      setState(() {
        _stations
          ..clear()
          ..addAll(stations);
        _isLoading = false;
        _hasMore = stations.length >= _pageSize;
      });
    } catch (e) {
      if (mySeq != _requestSeq || !mounted) return;
      setState(() {
        _error = e is RadioServiceException ? e.message : 'Failed to load stations.';
        _isLoading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final mySeq = _requestSeq;
    setState(() => _isLoadingMore = true);
    try {
      final more = await _fetchPage(_stations.length);
      if (mySeq != _requestSeq || !mounted) return;
      setState(() {
        _stations.addAll(more);
        _isLoadingMore = false;
        _hasMore = more.length >= _pageSize;
      });
    } catch (_) {
      if (mySeq != _requestSeq || !mounted) return;
      setState(() => _isLoadingMore = false);
    }
  }

  void _selectTag(String? tag) {
    setState(() => _selectedTag = tag == null ? null : (_selectedTag == tag ? null : tag));
    _loadInitial();
  }

  bool _isOpeningFullScreenPlayer = false;

  Future<void> _play(RadioStation station) async {
    // Register/start the station immediately and open the Full Screen Player
    // on the first tap — don't block navigation on the stream actually
    // connecting. onPlayStation registers the station (and pushes it to the
    // notification) synchronously before it awaits anything, so the Full
    // Screen Player — which reads the current station reactively via
    // RadioPlaybackContext — already has the right details by the time it
    // builds; it shows its own buffering state while the stream connects and
    // auto-closes via that same listener if playback ultimately fails.
    unawaited(widget.onPlayStation(station));
    // A second/third rapid tap on another station must still make that
    // station the active one (handled above), but must not stack a second
    // Full Screen Player route on top of the one already being opened.
    if (_isOpeningFullScreenPlayer || !mounted) return;
    _isOpeningFullScreenPlayer = true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RadioFullScreenPlayer(audioPlayer: widget.audioPlayer, isDarkMode: widget.isDark),
    ));
    _isOpeningFullScreenPlayer = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _cardColor,
        elevation: 0,
        iconTheme: IconThemeData(color: _textColor),
        title: Text(widget.country.name, style: TextStyle(color: _textColor)),
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          SafeArea(
            bottom: true,
            child: BannerAdWidget2(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: TextStyle(color: _textColor),
                    decoration: InputDecoration(
                      hintText: 'Search stations...',
                      hintStyle: TextStyle(color: _subtitleColor),
                      prefixIcon: Icon(Icons.search, color: _subtitleColor),
                      filled: true,
                      fillColor: _cardColor,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: BoxDecoration(
                    color: _cardColor,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: IconButton(
                    icon: Icon(_isGridView ? Icons.view_list_rounded : Icons.grid_view_rounded, color: _textColor),
                    onPressed: () => setState(() => _isGridView = !_isGridView),
                    tooltip: _isGridView ? 'Switch to List View' : 'Switch to Grid View',
                  ),
                ),
              ],
            ),
          ),
          if (_tags.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: _tags.length + 1, // Added 1 for the 'All' option
                itemBuilder: (context, i) {
                  final isAll = i == 0;
                  final tag = isAll ? 'All' : _tags[i - 1];
                  final selected = isAll ? _selectedTag == null : _selectedTag == tag;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(tag, style: TextStyle(color: selected ? Colors.white : _textColor, fontSize: 12)),
                      selected: selected,
                      selectedColor: _kPrimary,
                      backgroundColor: _cardColor,
                      onSelected: (_) => _selectTag(isAll ? null : tag),
                    ),
                  );
                },
              ),
            ),
          const SizedBox(height: 4),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: _kPrimary));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 64, color: _subtitleColor),
            const SizedBox(height: 16),
            Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: _textColor, fontSize: 15)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadInitial,
              style: ElevatedButton.styleFrom(backgroundColor: _kPrimary),
              child: const Text('Retry', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
    if (_stations.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radio, size: 64, color: _subtitleColor),
            const SizedBox(height: 12),
            Text('No stations found', style: TextStyle(color: _subtitleColor, fontSize: 15)),
          ],
        ),
      );
    }
    // Responsive station grid: 4 columns on wider screens (tablets/large
    // phones in landscape), 3 on a normal phone width — computed from the
    // available width instead of a fixed cross-device size, so cards never
    // stretch or clip on either breakpoint.
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth >= 600 ? 4 : 3;
        return ValueListenableBuilder<RadioStation?>(
          valueListenable: RadioPlaybackContext.currentStationNotifier,
          builder: (context, currentStation, _) {
            return CustomScrollView(
              controller: _scrollController,
              slivers: [
                SliverPadding(
                  padding: _isGridView
                      ? const EdgeInsets.fromLTRB(12, 8, 12, 4)
                      : const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  sliver: _isGridView
                      ? SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 0.74,
                    ),
                    delegate: SliverChildBuilderDelegate(
                          (context, index) {
                        final station = _stations[index];
                        final isCurrent =
                            currentStation != null && currentStation.stationUuid == station.stationUuid;
                        return _StationGridCard(
                          station: station,
                          isCurrent: isCurrent,
                          audioPlayer: widget.audioPlayer,
                          cardColor: _cardColor,
                          textColor: _textColor,
                          subtitleColor: _subtitleColor,
                          isDark: widget.isDark,
                          onTap: () => _play(station),
                        );
                      },
                      childCount: _stations.length,
                    ),
                  )
                      : SliverList(
                    delegate: SliverChildBuilderDelegate(
                          (context, index) {
                        final station = _stations[index];
                        final isCurrent =
                            currentStation != null && currentStation.stationUuid == station.stationUuid;
                        return _StationTile(
                          station: station,
                          isCurrent: isCurrent,
                          audioPlayer: widget.audioPlayer,
                          cardColor: _cardColor,
                          textColor: _textColor,
                          subtitleColor: _subtitleColor,
                          isDark: widget.isDark,
                          onTap: () => _play(station),
                        );
                      },
                      childCount: _stations.length,
                    ),
                  ),
                ),
                if (_hasMore)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(child: CircularProgressIndicator(color: _kPrimary, strokeWidth: 2)),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Grid-cell station card used by the country-wise station grid: artwork on
/// top, name + region/genre below, favorite toggle and now-playing badge
/// overlaid on the artwork. Shares the same highlight/favorite/playback
/// state sources as [_StationTile] (used by the Favorites list) so both
/// stay in sync with the one shared player.
class _StationGridCard extends StatelessWidget {
  final RadioStation station;
  final bool isCurrent;
  final AudioPlayer audioPlayer;
  final Color cardColor;
  final Color textColor;
  final Color subtitleColor;
  final bool isDark;
  final VoidCallback onTap;

  const _StationGridCard({
    required this.station,
    required this.isCurrent,
    required this.audioPlayer,
    required this.cardColor,
    required this.textColor,
    required this.subtitleColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlightBg = isDark ? _kPrimary.withOpacity(0.22) : _kPrimary.withOpacity(0.10);
    final regionLabel = station.state.isNotEmpty ? station.state : station.primaryGenre;

    return Material(
      color: isCurrent ? highlightBg : cardColor,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: isCurrent
            ? BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: _kPrimary, width: 1.4),
        )
            : null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: _StationArt(url: station.favicon, isDark: isDark, iconSize: 28),
                        ),
                      ),
                      Positioned(
                        top: 2,
                        right: 2,
                        child: AnimatedBuilder(
                          animation: RadioFavoritesNotifier.instance,
                          builder: (context, _) {
                            final fav = RadioFavoritesNotifier.instance.contains(station.stationUuid);
                            return Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.45),
                                shape: BoxShape.circle,
                              ),
                              child: IconButton(
                                iconSize: 12, // Reduced icon size
                                constraints: const BoxConstraints(minWidth: 20, minHeight: 20), // Reduced circle radius
                                padding: EdgeInsets.zero,
                                icon: Icon(fav ? Icons.favorite : Icons.favorite_border,
                                    color: fav ? Colors.red : Colors.white),
                                onPressed: () => RadioFavoritesNotifier.instance.toggle(station),
                              ),
                            );
                          },
                        ),
                      ),
                      if (isCurrent)
                        Positioned(
                          left: 4,
                          bottom: 4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: _kPrimary,
                              shape: BoxShape.circle,
                              border: Border.all(color: cardColor, width: 1.5),
                            ),
                            child: StreamBuilder<PlayerState>(
                              stream: audioPlayer.playerStateStream,
                              builder: (context, snap) {
                                final playing = snap.data?.playing ?? audioPlayer.playing;
                                return _NowPlayingBars(
                                  active: playing,
                                  color: Colors.white,
                                  barWidth: 2,
                                  maxBarHeight: 9,
                                );
                              },
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  station.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isCurrent ? _kPrimary : textColor,
                    fontWeight: FontWeight.w600,
                    fontSize: 12.5,
                  ),
                ),
                if (regionLabel.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    regionLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: subtitleColor, fontSize: 10.5),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Single station row shared by the station list and favorites list: art +
/// name/subtitle + favorite toggle, plus (when [isCurrent]) a highlighted
/// background/border and a now-playing/paused indicator sourced from the
/// existing shared player state (RadioPlaybackContext + the app's
/// AudioPlayer) rather than any station-local playback state.
class _StationTile extends StatelessWidget {
  final RadioStation station;
  final bool isCurrent;
  final AudioPlayer audioPlayer;
  final Color cardColor;
  final Color textColor;
  final Color subtitleColor;
  final bool isDark;
  final VoidCallback onTap;

  const _StationTile({
    required this.station,
    required this.isCurrent,
    required this.audioPlayer,
    required this.cardColor,
    required this.textColor,
    required this.subtitleColor,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final highlightBg = isDark ? _kPrimary.withOpacity(0.22) : _kPrimary.withOpacity(0.10);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      // See the country list above: the background/rounded corners move
      // onto a Material ancestor so ListTile's ink splash stays visible.
      child: Material(
        color: isCurrent ? highlightBg : cardColor,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: Container(
          decoration: isCurrent
              ? BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kPrimary, width: 1.4),
          )
              : null,
          child: ListTile(
            leading: Stack(
              clipBehavior: Clip.none,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 44, height: 44, child: _StationArt(url: station.favicon, isDark: isDark)),
                ),
                if (isCurrent)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: _kPrimary,
                        shape: BoxShape.circle,
                        border: Border.all(color: cardColor, width: 1.5),
                      ),
                      child: StreamBuilder<PlayerState>(
                        stream: audioPlayer.playerStateStream,
                        builder: (context, snap) {
                          final playing = snap.data?.playing ?? audioPlayer.playing;
                          return _NowPlayingBars(
                            active: playing,
                            color: Colors.white,
                            barWidth: 2,
                            maxBarHeight: 10,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
            title: Text(
              station.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: isCurrent ? _kPrimary : textColor, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(station.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: subtitleColor, fontSize: 12)),
            trailing: AnimatedBuilder(
              animation: RadioFavoritesNotifier.instance,
              builder: (context, _) {
                final fav = RadioFavoritesNotifier.instance.contains(station.stationUuid);
                return IconButton(
                  iconSize: 20,
                  icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.red : subtitleColor),
                  onPressed: () => RadioFavoritesNotifier.instance.toggle(station),
                );
              },
            ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

/// Compact bar shown in place of the normal MiniPlayer while a radio station
/// is the active source — same visual language (card, gradient play button,
/// rounded corners) as MiniPlayer in player_screen.dart.
class RadioMiniPlayer extends StatelessWidget {
  final RadioStation station;
  final AudioPlayer audioPlayer;
  final bool isDarkMode;
  final VoidCallback onOpenFullScreen;

  const RadioMiniPlayer({
    super.key,
    required this.station,
    required this.audioPlayer,
    required this.isDarkMode,
    required this.onOpenFullScreen,
  });

  @override
  Widget build(BuildContext context) {
    final backgroundColor = isDarkMode ? AppPalette.darkCard : Colors.white;
    final titleColor = isDarkMode ? Colors.white : const Color(0xFF2D2B4E);
    final subtitleColor = isDarkMode ? Colors.grey[400] : Colors.grey[600];

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(isDarkMode ? 0.3 : 0.1), blurRadius: 15, offset: const Offset(0, 4)),
        ],
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onOpenFullScreen,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(width: 48, height: 48, child: _StationArt(url: station.favicon, isDark: isDarkMode)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(
                      children: [
                        Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(station.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: titleColor)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(station.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: subtitleColor)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StreamBuilder<PlayerState>(
                stream: audioPlayer.playerStateStream,
                builder: (context, snap) {
                  final playing = snap.data?.playing ?? audioPlayer.playing;
                  return Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: AppPalette.gradient,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
                      onPressed: () => playing ? audioPlayer.pause() : audioPlayer.play(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RadioFullScreenPlayer extends StatefulWidget {
  final AudioPlayer audioPlayer;
  final bool isDarkMode;

  const RadioFullScreenPlayer({super.key, required this.audioPlayer, required this.isDarkMode});

  @override
  State<RadioFullScreenPlayer> createState() => _RadioFullScreenPlayerState();
}

class _RadioFullScreenPlayerState extends State<RadioFullScreenPlayer> {
  @override
  void initState() {
    super.initState();
    RadioFavoritesNotifier.instance.init();
  }

  Future<void> _stop() async {
    try {
      await widget.audioPlayer.stop();
    } catch (_) {}
    RadioPlaybackContext.clear();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDarkMode;
    final bg = isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
    final textColor = isDark ? Colors.white : const Color(0xFF2D2B4E);
    final subtitleColor = isDark ? Colors.white70 : const Color(0xFF8C8A9D);

    return ValueListenableBuilder<RadioStation?>(
      valueListenable: RadioPlaybackContext.currentStationNotifier,
      builder: (context, station, _) {
        if (station == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return Scaffold(backgroundColor: bg, body: const SizedBox.shrink());
        }
        return Scaffold(
          bottomNavigationBar: const BannerAdWidget(),
          backgroundColor: bg,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            iconTheme: IconThemeData(color: textColor),
            title: Text('Internet Radio', style: TextStyle(color: textColor)),
            actions: [
              AnimatedBuilder(
                animation: RadioFavoritesNotifier.instance,
                builder: (context, _) {
                  final fav = RadioFavoritesNotifier.instance.contains(station.stationUuid);
                  return IconButton(
                    icon: Icon(fav ? Icons.favorite : Icons.favorite_border, color: fav ? Colors.red : textColor),
                    onPressed: () => RadioFavoritesNotifier.instance.toggle(station),
                  );
                },
              ),
            ],
          ),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Spacer(),
                  Container(
                    width: 220,
                    height: 220,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.4 : 0.15), blurRadius: 30, offset: const Offset(0, 10))],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(24),
                      child: _StationArt(url: station.favicon, isDark: isDark, iconSize: 72),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(width: 10, height: 10, margin: const EdgeInsets.only(right: 8), decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                      const Text('LIVE', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(station.name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: textColor, fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Text(station.subtitle, textAlign: TextAlign.center, style: TextStyle(color: subtitleColor, fontSize: 14)),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 40,
                        icon: Icon(Icons.stop_circle, color: subtitleColor),
                        onPressed: _stop,
                        tooltip: 'Stop',
                      ),
                      const SizedBox(width: 28),
                      StreamBuilder<PlayerState>(
                        stream: widget.audioPlayer.playerStateStream,
                        builder: (context, snap) {
                          final playerState = snap.data;
                          final playing = playerState?.playing ?? widget.audioPlayer.playing;
                          final processingState = playerState?.processingState ?? widget.audioPlayer.processingState;
                          // The stream is still connecting — show the existing
                          // loading state instead of a Play/Pause icon so the
                          // Full Screen Player never looks stuck while it
                          // waits for the newly selected station to buffer.
                          final isBuffering = processingState == ProcessingState.loading ||
                              processingState == ProcessingState.buffering;
                          return CircleAvatar(
                            radius: 36,
                            backgroundColor: _kPrimary,
                            child: isBuffering
                                ? const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
                            )
                                : IconButton(
                              icon: Icon(playing ? Icons.pause : Icons.play_arrow, size: 36, color: Colors.white),
                              onPressed: () => playing ? widget.audioPlayer.pause() : widget.audioPlayer.play(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 28 + 40),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Lists the user's favorite radio stations (RadioFavoritesNotifier) using
/// the same card/list style as RadioStationsPage, opened from the Favorites
/// action in the Internet Radio App Bar.
class RadioFavoritesPage extends StatefulWidget {
  final AudioPlayer audioPlayer;
  final bool isDark;
  final Future<bool> Function(RadioStation station) onPlayStation;

  const RadioFavoritesPage({
    super.key,
    required this.audioPlayer,
    required this.isDark,
    required this.onPlayStation,
  });

  @override
  State<RadioFavoritesPage> createState() => _RadioFavoritesPageState();
}

class _RadioFavoritesPageState extends State<RadioFavoritesPage> {
  bool _isOpeningFullScreenPlayer = false;

  Color get _bg => widget.isDark ? AppPalette.darkBackground : const Color(0xFFF8F9FD);
  Color get _cardColor => widget.isDark ? AppPalette.darkCard : Colors.white;
  Color get _textColor => widget.isDark ? Colors.white : const Color(0xFF2D2B4E);
  Color get _subtitleColor => widget.isDark ? Colors.white70 : const Color(0xFF8C8A9D);

  @override
  void initState() {
    super.initState();
    RadioFavoritesNotifier.instance.init();
  }

  Future<void> _play(RadioStation station) async {
    // Same first-tap-opens-immediately behavior as the station list.
    unawaited(widget.onPlayStation(station));
    if (_isOpeningFullScreenPlayer || !mounted) return;
    _isOpeningFullScreenPlayer = true;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RadioFullScreenPlayer(audioPlayer: widget.audioPlayer, isDarkMode: widget.isDark),
    ));
    _isOpeningFullScreenPlayer = false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        // AppBar color matches the Settings page AppBar (SettingsColors.appBarBackground).
        backgroundColor: widget.isDark ? AppPalette.darkBackground : Colors.white,
        elevation: 0,
        iconTheme: IconThemeData(color: _textColor),
        title: Text('Favorite Stations', style: TextStyle(color: _textColor)),
      ),
      bottomNavigationBar: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GlobalMiniPlayer(),
          SafeArea(
            bottom: true,
            child: BannerAdWidget2(),
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: RadioFavoritesNotifier.instance,
        builder: (context, _) {
          final stations = RadioFavoritesNotifier.instance.favorites;
          if (stations.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.favorite_border, size: 64, color: _subtitleColor),
                  const SizedBox(height: 12),
                  Text('No favorite stations yet', style: TextStyle(color: _subtitleColor, fontSize: 15)),
                ],
              ),
            );
          }
          return ValueListenableBuilder<RadioStation?>(
            valueListenable: RadioPlaybackContext.currentStationNotifier,
            builder: (context, currentStation, _) {
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: stations.length,
                itemBuilder: (context, index) {
                  final station = stations[index];
                  final isCurrent = currentStation != null && currentStation.stationUuid == station.stationUuid;
                  return _StationTile(
                    station: station,
                    isCurrent: isCurrent,
                    audioPlayer: widget.audioPlayer,
                    cardColor: _cardColor,
                    textColor: _textColor,
                    subtitleColor: _subtitleColor,
                    isDark: widget.isDark,
                    onTap: () => _play(station),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}