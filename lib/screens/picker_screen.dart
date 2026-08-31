import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/knu_api.dart';

class PickerScreen extends StatefulWidget {
  final KnuApi api;
  const PickerScreen({super.key, required this.api});

  @override
  State<PickerScreen> createState() => _PickerScreenState();
}

class _PickerScreenState extends State<PickerScreen> {
  List<Faculty> _faculties = [];
  List<int> _courses = [];
  List<Group> _groups = [];

  Faculty? _faculty;
  int? _course;
  Group? _group;

  bool _loadingFaculties = true;
  bool _loadingCourses = false;
  bool _loadingGroups = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadFaculties();
  }

  Future<void> _loadFaculties() async {
    setState(() {
      _loadingFaculties = true;
      _error = null;
    });
    try {
      final list = await widget.api.getFaculties();
      if (!mounted) return;
      setState(() {
        _faculties = list;
        _loadingFaculties = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingFaculties = false;
      });
    }
  }

  Future<void> _onFaculty(Faculty? f) async {
    setState(() {
      _faculty = f;
      _course = null;
      _group = null;
      _courses = [];
      _groups = [];
    });
    if (f == null) return;
    setState(() => _loadingCourses = true);
    try {
      final courses = await widget.api.getCourses(f.id);
      if (!mounted) return;
      setState(() {
        _courses = courses;
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingCourses = false;
      });
    }
  }

  Future<void> _onCourse(int? c) async {
    setState(() {
      _course = c;
      _group = null;
      _groups = [];
    });
    if (c == null || _faculty == null) return;
    setState(() => _loadingGroups = true);
    try {
      final groups = await widget.api.getGroups(
        facultyId: _faculty!.id,
        facultyName: _faculty!.name,
        course: c,
      );
      if (!mounted) return;
      setState(() {
        _groups = groups;
        _loadingGroups = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loadingGroups = false;
      });
    }
  }

  void _confirm() {
    if (_group == null) return;
    Navigator.of(context).pop(_group);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Обрати групу')),
      body: _loadingFaculties
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!),
                    ),
                  ),
                Text(
                  'Факультет',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<Faculty>(
                  value: _faculty,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'Оберіть факультет',
                  ),
                  items: _faculties
                      .map(
                        (f) => DropdownMenuItem(
                          value: f,
                          child: Text(f.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: _onFaculty,
                ),
                const SizedBox(height: 20),
                Text('Курс', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_loadingCourses)
                  const LinearProgressIndicator()
                else
                  DropdownButtonFormField<int>(
                    value: _course,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Оберіть курс',
                    ),
                    items: _courses
                        .map(
                          (c) => DropdownMenuItem(
                            value: c,
                            child: Text('$c'),
                          ),
                        )
                        .toList(),
                    onChanged: _faculty == null ? null : _onCourse,
                  ),
                const SizedBox(height: 20),
                Text('Група', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_loadingGroups)
                  const LinearProgressIndicator()
                else
                  DropdownButtonFormField<Group>(
                    value: _group,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Оберіть групу',
                    ),
                    items: _groups
                        .map(
                          (g) => DropdownMenuItem(
                            value: g,
                            child: Text(g.name),
                          ),
                        )
                        .toList(),
                    onChanged: _course == null
                        ? null
                        : (g) => setState(() => _group = g),
                  ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: _group == null ? null : _confirm,
                  icon: const Icon(Icons.push_pin),
                  label: const Text('Закріпити й відкрити'),
                ),
                const SizedBox(height: 8),
                Text(
                  'Групу можна буде змінити або додати інші в будь-який момент.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
    );
  }
}
