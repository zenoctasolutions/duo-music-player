// lib/constants.dart
import 'package:flutter/material.dart';

/// Define your bottom navigation items here
const List<BottomNavigationBarItem> bottomNavItems = [
  BottomNavigationBarItem(
    icon: Icon(Icons.list_alt),
    label: 'Lists',
  ),
  BottomNavigationBarItem(
    icon: Icon(Icons.music_note),
    label: 'Songs',
  ),
  BottomNavigationBarItem(
    icon: Icon(Icons.album),
    label: 'Albums',
  ),
  BottomNavigationBarItem(
    icon: Icon(Icons.settings),
    label: 'Settings',
  ),
];

/// Optionally define tab titles (for app bars, etc.)
const List<String> bottomNavTitles = [
  'Your Lists',
  'All Songs',
  'Albums',
  'Settings',
];
