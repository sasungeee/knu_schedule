import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/knu_api.dart';
import '../services/storage.dart';
import 'login_screen.dart';
import 'picker_screen.dart';
import 'schedule_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _storage = AppStorage();
  final _api = KnuApi();
  List<Group> _pinned = [];
  int? _primaryId;
  bool _loading = true;
  bool _authenticated = false;
  bool _checkingAuth = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _api.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _checkingAuth = true;
      _loading = true;
    });

    final creds = await _storage.loadCredentials();
    if (creds != null) {
      try {
        _api.setCredentials(creds.username, creds.password);
        await _api.login(creds.username, creds.password);
        if (!mounted) return;
        setState(() {
          _authenticated = true;
          _checkingAuth = false;
        });
        await _reload();
        return;
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _authenticated = false;
          _checkingAuth = false;
          _loading = false;
        });
        return;
      }
    }

    if (!mounted) return;
    setState(() {
      _authenticated = false;
      _checkingAuth = false;
      _loading = false;
    });
  }

  Future<void> _reload() async {
    final pinned = await _storage.loadPinned();
    final primary = await _storage.loadPrimaryId();
    if (!mounted) return;
    setState(() {
      _pinned = pinned;
      _primaryId = primary;
      _loading = false;
    });
  }

  void _onLoginSuccess() {
    setState(() {
      _authenticated = true;
      _loading = true;
    });
    _reload();
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Вийти?'),
        content: const Text(
          'Сесію буде завершено. Збережені групи залишаться, '
          'але для перегляду розкладу потрібен повторний вхід.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Скасувати'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Вийти'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _api.logout();
    await _storage.clearCredentials();
    if (!mounted) return;
    setState(() {
      _authenticated = false;
    });
  }

  Future<void> _openPicker() async {
    try {
      final added = await Navigator.of(context).push<Group>(
        MaterialPageRoute(builder: (_) => PickerScreen(api: _api)),
      );
      if (added != null) {
        await _storage.pin(added);
        await _reload();
      }
    } on KnuAuthException {
      if (!mounted) return;
      setState(() => _authenticated = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сесія закінчилась. Увійдіть знову.')),
      );
    }
  }

  Future<void> _openSchedule(Group group) async {
    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScheduleScreen(group: group, api: _api),
        ),
      );
    } on KnuAuthException {
      if (!mounted) return;
      setState(() => _authenticated = false);
    }
  }

  Future<void> _setPrimary(Group g) async {
    await _storage.setPrimary(g.id);
    await _reload();
  }

  Future<void> _unpin(Group g) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Відкріпити?'),
        content: Text('Група ${g.name} буде прибрана з обраних.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Скасувати'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Відкріпити'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _storage.unpin(g.id);
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingAuth) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    if (!_authenticated) {
      return LoginScreen(
        api: _api,
        storage: _storage,
        onSuccess: _onLoginSuccess,
      );
    }

    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Розклад КНУ'),
        actions: [
          IconButton(
            tooltip: 'Додати групу',
            onPressed: _openPicker,
            icon: const Icon(Icons.add),
          ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'logout',
                child: Text('Вийти з акаунту'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _pinned.isEmpty
              ? _EmptyState(onAdd: _openPicker)
              : RefreshIndicator(
                  onRefresh: _reload,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 88),
                    itemCount: _pinned.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            'Обрані групи',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }
                      final g = _pinned[i - 1];
                      final isPrimary = g.id == _primaryId;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 10),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: isPrimary
                                ? theme.colorScheme.primary
                                : theme.colorScheme.surfaceContainerHighest,
                            foregroundColor: isPrimary
                                ? theme.colorScheme.onPrimary
                                : theme.colorScheme.onSurface,
                            child: Text(
                              g.name.length >= 2
                                  ? g.name.substring(0, 2)
                                  : g.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          title: Text(
                            g.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            '${g.facultyName}\n${g.course} курс',
                          ),
                          isThreeLine: true,
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) {
                              if (v == 'primary') _setPrimary(g);
                              if (v == 'unpin') _unpin(g);
                            },
                            itemBuilder: (_) => [
                              if (!isPrimary)
                                const PopupMenuItem(
                                  value: 'primary',
                                  child: Text('Зробити основною'),
                                ),
                              const PopupMenuItem(
                                value: 'unpin',
                                child: Text('Відкріпити'),
                              ),
                            ],
                          ),
                          onTap: () => _openSchedule(g),
                        ),
                      );
                    },
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openPicker,
        icon: const Icon(Icons.group_add),
        label: const Text('Додати групу'),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyState({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.calendar_month_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.7),
            ),
            const SizedBox(height: 16),
            Text(
              'Немає закріплених груп',
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Додай свою групу один раз — і розклад відкриватиметься без вибору факультету та курсу.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Обрати групу'),
            ),
          ],
        ),
      ),
    );
  }
}
