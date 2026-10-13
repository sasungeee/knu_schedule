import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/models.dart';

class AppStorage {
  static const _pinnedKey = 'pinned_groups';
  static const _primaryKey = 'primary_group_id';
  static const _usernameKey = 'auth_username';
  static const _passwordKey = 'auth_password';
  static const _rememberKey = 'auth_remember';

  Future<List<Group>> loadPinned() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_pinnedKey) ?? [];
    return raw
        .map((s) => Group.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  Future<void> savePinned(List<Group> groups) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _pinnedKey,
      groups.map((g) => jsonEncode(g.toJson())).toList(),
    );
  }

  Future<int?> loadPrimaryId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_primaryKey);
  }

  Future<void> savePrimaryId(int? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_primaryKey);
    } else {
      await prefs.setInt(_primaryKey, id);
    }
  }

  Future<void> pin(Group group) async {
    final list = await loadPinned();
    if (list.any((g) => g.id == group.id)) return;
    list.add(group);
    await savePinned(list);
    final primary = await loadPrimaryId();
    if (primary == null) await savePrimaryId(group.id);
  }

  Future<void> unpin(int groupId) async {
    final list = await loadPinned();
    list.removeWhere((g) => g.id == groupId);
    await savePinned(list);
    final primary = await loadPrimaryId();
    if (primary == groupId) {
      await savePrimaryId(list.isEmpty ? null : list.first.id);
    }
  }

  Future<void> setPrimary(int groupId) async {
    await savePrimaryId(groupId);
  }

  // --- auth ---

  Future<({String username, String password})?> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(_rememberKey) ?? false;
    if (!remember) return null;
    final u = prefs.getString(_usernameKey);
    final p = prefs.getString(_passwordKey);
    if (u == null || p == null || u.isEmpty || p.isEmpty) return null;
    return (username: u, password: p);
  }

  Future<void> saveCredentials({
    required String username,
    required String password,
    required bool remember,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (remember) {
      await prefs.setString(_usernameKey, username.trim());
      await prefs.setString(_passwordKey, password);
      await prefs.setBool(_rememberKey, true);
    } else {
      await clearCredentials();
    }
  }

  Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    await prefs.setBool(_rememberKey, false);
  }

  Future<bool> hasSavedCredentials() async {
    final c = await loadCredentials();
    return c != null;
  }
}
