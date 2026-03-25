import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

// ── Sound Service ─────────────────────────────────────────────────────────────

class SoundService {
  static final _player = AudioPlayer();
  static Uint8List? _cachedBytes;

  static Future<void> playComplete() async {
    try {
      _cachedBytes ??= _generateDing();
      final file = File('${Directory.systemTemp.path}/todo_complete.wav');
      if (!file.existsSync()) {
        file.writeAsBytesSync(_cachedBytes!);
      }
      await _player.play(DeviceFileSource(file.path));
    } catch (_) {}
  }

  static Uint8List _generateDing() {
    const sampleRate = 44100;
    const numSamples = sampleRate * 4 ~/ 10; // 0.4s
    final data = ByteData(44 + numSamples * 2);

    void str(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        data.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    data.setUint32(4, 36 + numSamples * 2, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // Mono
    data.setUint32(24, sampleRate, Endian.little);
    data.setUint32(28, sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    str(36, 'data');
    data.setUint32(40, numSamples * 2, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      // Two-tone ding: A5 (880Hz) → C#6 (1108Hz)
      final freq = i < numSamples ~/ 2 ? 880.0 : 1108.0;
      final attack = (sampleRate * 0.005).round();
      final decay = (sampleRate * 0.15).round();
      final env = i < attack
          ? i / attack
          : i > numSamples - decay
              ? (numSamples - i) / decay
              : 1.0;
      final v = (math.sin(2 * math.pi * freq * t) * 26000 * env)
          .round()
          .clamp(-32768, 32767);
      data.setInt16(44 + i * 2, v, Endian.little);
    }
    return data.buffer.asUint8List();
  }
}

// ── Notification Service ──────────────────────────────────────────────────────

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> init() async {
    tz_data.initializeTimeZones();
    final tzInfo = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(tzInfo.identifier));

    const ios = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(const InitializationSettings(iOS: ios));
    await _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>()
        ?.requestPermissions(alert: true, badge: true, sound: true);
  }

  static Future<void> schedule(int id, String title, DateTime deadline) async {
    final reminderTime = deadline.subtract(const Duration(minutes: 5));
    if (reminderTime.isBefore(DateTime.now())) return;

    await _plugin.zonedSchedule(
      id,
      '⏰ Task Due Soon!',
      '"$title" is due in 5 minutes',
      tz.TZDateTime.from(reminderTime, tz.local),
      const NotificationDetails(
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentSound: true,
          presentBadge: false,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  static Future<void> cancel(int id) => _plugin.cancel(id);
}

// ── Database ──────────────────────────────────────────────────────────────────

class TodoDatabase {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(
      p.join(dbPath, 'todos.db'),
      version: 2,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE todos(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          is_completed INTEGER NOT NULL DEFAULT 0,
          deadline INTEGER
        )
      '''),
      onUpgrade: (db, oldVersion, _) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE todos ADD COLUMN deadline INTEGER');
        }
      },
    );
    return _db!;
  }

  static Future<List<Todo>> fetchAll() async {
    final db = await database;
    final rows = await db.query('todos', orderBy: 'id DESC');
    return rows.map(Todo.fromMap).toList();
  }

  static Future<Todo> insert(String title, DateTime? deadline) async {
    final db = await database;
    final id = await db.insert('todos', {
      'title': title,
      'is_completed': 0,
      'deadline': deadline?.millisecondsSinceEpoch,
    });
    return Todo(id: id, title: title, deadline: deadline);
  }

  static Future<void> toggleComplete(int id, bool isCompleted) async {
    final db = await database;
    await db.update(
      'todos',
      {'is_completed': isCompleted ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> delete(int id) async {
    final db = await database;
    await db.delete('todos', where: 'id = ?', whereArgs: [id]);
  }
}

// ── Model ─────────────────────────────────────────────────────────────────────

class Todo {
  final int id;
  final String title;
  bool isCompleted;
  final DateTime? deadline;

  Todo({
    required this.id,
    required this.title,
    this.isCompleted = false,
    this.deadline,
  });

  factory Todo.fromMap(Map<String, dynamic> map) => Todo(
        id: map['id'] as int,
        title: map['title'] as String,
        isCompleted: (map['is_completed'] as int) == 1,
        deadline: map['deadline'] != null
            ? DateTime.fromMillisecondsSinceEpoch(map['deadline'] as int)
            : null,
      );
}

// ── Theme colours ─────────────────────────────────────────────────────────────

const _neonPurple = Color(0xFF9B5DE5);
const _neonPink = Color(0xFFF15BB5);
const _neonYellow = Color(0xFFFFE74C);
const _neonCyan = Color(0xFF00BBF9);
const _neonGreen = Color(0xFF00F5A0);
const _darkBg = Color(0xFF0D0D1A);
const _cardBg = Color(0xFF1A1A2E);

// ── Helpers ───────────────────────────────────────────────────────────────────

String _formatDeadline(DateTime dt) {
  final now = DateTime.now();
  final tomorrow = now.add(const Duration(days: 1));
  final time =
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
    return 'Today  $time';
  }
  if (dt.year == tomorrow.year &&
      dt.month == tomorrow.month &&
      dt.day == tomorrow.day) {
    return 'Tomorrow  $time';
  }
  return '${dt.day}/${dt.month}  $time';
}

Color _deadlineColor(DateTime dl) {
  if (dl.isBefore(DateTime.now())) return Colors.red.shade400;
  if (dl.difference(DateTime.now()).inMinutes < 60) return _neonYellow;
  return _neonGreen;
}

// ── Entry point ───────────────────────────────────────────────────────────────

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();
  runApp(const TodoApp());
}

class TodoApp extends StatelessWidget {
  const TodoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Todo App',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _darkBg,
        colorScheme: const ColorScheme.dark(
          primary: _neonPurple,
          secondary: _neonPink,
          surface: _cardBg,
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: _neonPurple,
          foregroundColor: Colors.white,
        ),
      ),
      home: const TodoHomePage(),
    );
  }
}

// ── Home page ─────────────────────────────────────────────────────────────────

class TodoHomePage extends StatefulWidget {
  const TodoHomePage({super.key});

  @override
  State<TodoHomePage> createState() => _TodoHomePageState();
}

class _TodoHomePageState extends State<TodoHomePage> {
  final List<Todo> _todos = [];
  final _listKey = GlobalKey<SliverAnimatedListState>();
  final _controller = TextEditingController();
  bool _loading = true;
  bool _animating = false;

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  Future<void> _loadTodos() async {
    final todos = await TodoDatabase.fetchAll();
    setState(() {
      _todos.addAll(todos);
      _loading = false;
    });
  }

  Future<void> _addTodo(String title, DateTime? deadline) async {
    final todo = await TodoDatabase.insert(title, deadline);
    _todos.insert(0, todo);
    _listKey.currentState?.insertItem(0,
        duration: const Duration(milliseconds: 380));
    setState(() {});
    if (deadline != null) {
      await NotificationService.schedule(todo.id, todo.title, deadline);
    }
  }

  Future<void> _toggleTodo(int id) async {
    final todo = _todos.firstWhere((t) => t.id == id);
    final next = !todo.isCompleted;
    await TodoDatabase.toggleComplete(id, next);
    setState(() => todo.isCompleted = next);
    if (next) {
      await SoundService.playComplete();
      HapticFeedback.mediumImpact();
      if (todo.deadline != null) await NotificationService.cancel(id);
    }
  }

  Future<void> _deleteTodo(int id) async {
    final index = _todos.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final todo = _todos.removeAt(index);
    setState(() => _animating = true);
    _listKey.currentState?.removeItem(
      index,
      (context, animation) => _ExitCard(todo: todo, animation: animation),
      duration: const Duration(milliseconds: 280),
    );
    await Future.delayed(const Duration(milliseconds: 310));
    if (mounted) setState(() => _animating = false);
    await TodoDatabase.delete(id);
    await NotificationService.cancel(id);
  }

  void _showAddDialog() {
    DateTime? deadline;
    _controller.clear();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (ctx, setDS) => Dialog(
          backgroundColor: _cardBg,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Title
                ShaderMask(
                  shaderCallback: (b) => const LinearGradient(
                    colors: [_neonPurple, _neonPink],
                  ).createShader(b),
                  child: const Text(
                    'New Task',
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                ),
                const SizedBox(height: 16),
                // Task input
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'What needs to be done?',
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: _darkBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide:
                          const BorderSide(color: _neonPurple, width: 2),
                    ),
                  ),
                  onSubmitted: (_) {
                    final text = _controller.text.trim();
                    if (text.isNotEmpty) {
                      _addTodo(text, deadline);
                      Navigator.pop(ctx);
                    }
                  },
                ),
                const SizedBox(height: 12),
                // Deadline picker row
                GestureDetector(
                  onTap: () async {
                    final date = await showDatePicker(
                      context: ctx,
                      initialDate:
                          DateTime.now().add(const Duration(hours: 1)),
                      firstDate: DateTime.now(),
                      lastDate:
                          DateTime.now().add(const Duration(days: 365)),
                      builder: (context, child) => Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: const ColorScheme.dark(
                            primary: _neonPurple,
                            surface: _cardBg,
                          ),
                        ),
                        child: child!,
                      ),
                    );
                    if (date == null || !ctx.mounted) return;
                    final time = await showTimePicker(
                      context: ctx,
                      initialTime: TimeOfDay.fromDateTime(
                          DateTime.now().add(const Duration(hours: 1))),
                      builder: (context, child) => Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: const ColorScheme.dark(
                            primary: _neonPurple,
                            surface: _cardBg,
                          ),
                        ),
                        child: child!,
                      ),
                    );
                    if (time == null) return;
                    setDS(() => deadline = DateTime(date.year, date.month,
                        date.day, time.hour, time.minute));
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: _darkBg,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color:
                            deadline != null ? _neonCyan : Colors.white12,
                        width: 1.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.schedule_rounded,
                            size: 18,
                            color: deadline != null
                                ? _neonCyan
                                : Colors.white38),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            deadline != null
                                ? _formatDeadline(deadline!)
                                : 'Set deadline (optional)',
                            style: TextStyle(
                              color: deadline != null
                                  ? _neonCyan
                                  : Colors.white38,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (deadline != null)
                          GestureDetector(
                            onTap: () => setDS(() => deadline = null),
                            child: const Icon(Icons.close_rounded,
                                size: 16, color: Colors.white38),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // Buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () {
                        _controller.clear();
                        Navigator.pop(ctx);
                      },
                      child: const Text('Cancel',
                          style: TextStyle(color: Colors.white38)),
                    ),
                    const SizedBox(width: 8),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                            colors: [_neonPurple, _neonPink]),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () {
                          final text = _controller.text.trim();
                          if (text.isEmpty) return;
                          _addTodo(text, deadline);
                          Navigator.pop(ctx);
                        },
                        child: const Text('Add',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.white)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  int get _completedCount => _todos.where((t) => t.isCompleted).length;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 140,
            pinned: true,
            backgroundColor: _darkBg,
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
              title: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ShaderMask(
                    shaderCallback: (b) => const LinearGradient(
                      colors: [_neonCyan, _neonPurple, _neonPink],
                    ).createShader(b),
                    child: const Text(
                      'MY TODOS',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 3,
                      ),
                    ),
                  ),
                  if (_todos.isNotEmpty)
                    Text(
                      '$_completedCount of ${_todos.length} completed',
                      style: const TextStyle(
                          fontSize: 11,
                          color: _neonYellow,
                          letterSpacing: 1),
                    ),
                ],
              ),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                  child: CircularProgressIndicator(color: _neonPurple)),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              sliver: SliverAnimatedList(
                key: _listKey,
                initialItemCount: _todos.length,
                itemBuilder: (context, index, animation) {
                  final todo = _todos[index];
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(1, 0),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                    child: FadeTransition(
                      opacity: animation,
                      child: _TodoCard(
                        key: ValueKey(todo.id),
                        todo: todo,
                        onToggle: () => _toggleTodo(todo.id),
                        onDelete: () => _deleteTodo(todo.id),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_todos.isEmpty && !_animating)
              SliverFillRemaining(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ShaderMask(
                        shaderCallback: (b) => const LinearGradient(
                          colors: [_neonCyan, _neonPurple],
                        ).createShader(b),
                        child: const Icon(Icons.bolt,
                            size: 72, color: Colors.white),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Nothing here yet.\nTap + to add a task!',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Colors.white38, fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Task',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _neonPurple,
        foregroundColor: Colors.white,
      ),
    );
  }
}

// ── Exit animation card (used by removeItem) ──────────────────────────────────

class _ExitCard extends StatelessWidget {
  final Todo todo;
  final Animation<double> animation;
  const _ExitCard({required this.todo, required this.animation});

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: animation,
      child: FadeTransition(
        opacity: animation,
        child: _TodoCard(todo: todo, onToggle: () {}, onDelete: () {}),
      ),
    );
  }
}

// ── Todo card ─────────────────────────────────────────────────────────────────

class _TodoCard extends StatefulWidget {
  final Todo todo;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _TodoCard({
    super.key,
    required this.todo,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  State<_TodoCard> createState() => _TodoCardState();
}

class _TodoCardState extends State<_TodoCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _bounceCtrl;
  late final Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _bounceCtrl = AnimationController(
        duration: const Duration(milliseconds: 420), vsync: this);
    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.45), weight: 28),
      TweenSequenceItem(tween: Tween(begin: 1.45, end: 0.82), weight: 34),
      TweenSequenceItem(tween: Tween(begin: 0.82, end: 1.0), weight: 38),
    ]).animate(
        CurvedAnimation(parent: _bounceCtrl, curve: Curves.easeInOut));
  }

  @override
  void didUpdateWidget(_TodoCard old) {
    super.didUpdateWidget(old);
    if (widget.todo.isCompleted && !old.todo.isCompleted) {
      _bounceCtrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _bounceCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final todo = widget.todo;
    final dl = todo.deadline;

    return Dismissible(
      key: Key('d_${todo.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: _neonPink.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _neonPink),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_rounded, color: _neonPink),
      ),
      onDismissed: (_) => widget.onDelete(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: todo.isCompleted
                ? _neonPurple.withValues(alpha: 0.25)
                : _neonPurple.withValues(alpha: 0.65),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: _neonPurple
                  .withValues(alpha: todo.isCompleted ? 0.03 : 0.18),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: GestureDetector(
            onTap: widget.onToggle,
            child: ScaleTransition(
              scale: _scaleAnim,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: todo.isCompleted
                      ? const LinearGradient(
                          colors: [_neonPurple, _neonPink])
                      : null,
                  border: todo.isCompleted
                      ? null
                      : Border.all(color: _neonPurple, width: 2),
                  boxShadow: todo.isCompleted
                      ? [
                          BoxShadow(
                              color: _neonPink.withValues(alpha: 0.55),
                              blurRadius: 10)
                        ]
                      : null,
                ),
                child: todo.isCompleted
                    ? const Icon(Icons.check_rounded,
                        size: 16, color: Colors.white)
                    : null,
              ),
            ),
          ),
          title: AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 250),
            style: TextStyle(
              color: todo.isCompleted ? Colors.white30 : Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w500,
              decoration:
                  todo.isCompleted ? TextDecoration.lineThrough : null,
              decorationColor: _neonPink,
            ),
            child: Text(todo.title),
          ),
          subtitle: dl != null
              ? Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(Icons.schedule_rounded,
                          size: 12, color: _deadlineColor(dl)),
                      const SizedBox(width: 4),
                      Text(
                        _formatDeadline(dl),
                        style: TextStyle(
                          fontSize: 12,
                          color: _deadlineColor(dl),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : null,
          trailing: IconButton(
            icon: Icon(Icons.close_rounded,
                color: _neonPink.withValues(alpha: 0.6), size: 20),
            onPressed: widget.onDelete,
          ),
        ),
      ),
    );
  }
}
