import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const blue = Color(0xFF1E5BD8);
const softBlue = Color(0xFFF1F6FF);
const lineBlue = Color(0xFFD6E3FA);

const dayNames = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];

final notif = FlutterLocalNotificationsPlugin();

final alarmDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    'alarm_channel_v1',
    'المنبّهات',
    channelDescription: 'تنبيهات المنبّه',
    importance: Importance.max,
    priority: Priority.max,
    category: AndroidNotificationCategory.alarm,
    audioAttributesUsage: AudioAttributesUsage.alarm,
    sound: const UriAndroidNotificationSound('content://settings/system/alarm_alert'),
    playSound: true,
    enableVibration: true,
    additionalFlags: Int32List.fromList(<int>[4]), // يكرّر الصوت حتى تفتح الإشعار
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  try {
    final name = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(name));
  } catch (_) {}
  try {
    await notif.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    final android = notif.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  } catch (_) {}
  runApp(const AlarmApp());
}

String fmt(TimeOfDay t) {
  final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final m = t.minute.toString().padLeft(2, '0');
  return '$h:$m ${t.period == DayPeriod.am ? 'ص' : 'م'}';
}

// ---------- النغمات ----------
class Note {
  const Note(this.f, this.d);
  final double f;
  final double d;
}

Uint8List makeWav(List<Note> notes) {
  const rate = 22050;
  final samples = <int>[];
  for (final n in notes) {
    final count = (rate * n.d).round();
    for (var i = 0; i < count; i++) {
      if (n.f == 0) {
        samples.add(0);
        continue;
      }
      final t = i / rate;
      final fade = math.min(1.0, math.min(i, count - i) / (rate * 0.01));
      samples.add((math.sin(2 * math.pi * n.f * t) * 0.6 * fade * 32767).round());
    }
  }
  final data = ByteData(44 + samples.length * 2);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + samples.length * 2, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return data.buffer.asUint8List();
}

class Tone {
  Tone(this.id, this.name, this.notes);
  final String id;
  final String name;
  final List<Note> notes;
  Uint8List? _bytes;
  Uint8List get bytes => _bytes ??= makeWav(notes);
}

final tones = <Tone>[
  Tone('classic', 'كلاسيكي', const [
    Note(880, .18), Note(0, .08), Note(880, .18), Note(0, .08), Note(880, .18), Note(0, .5),
  ]),
  Tone('soft', 'هادئ', const [
    Note(523, .3), Note(659, .3), Note(784, .3), Note(1047, .5), Note(0, .4),
  ]),
  Tone('morning', 'صباحي', const [
    Note(784, .2), Note(988, .2), Note(1175, .2), Note(988, .2), Note(1319, .4), Note(0, .5),
  ]),
  Tone('fast', 'سريع', const [
    Note(1000, .12), Note(800, .12), Note(1000, .12), Note(800, .12),
    Note(1000, .12), Note(800, .12), Note(0, .3),
  ]),
];

// ---------- التطبيق ----------
class AlarmApp extends StatelessWidget {
  const AlarmApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'المنبّه',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: Brightness.light)
            .copyWith(primary: blue, surface: Colors.white),
        scaffoldBackgroundColor: Colors.white,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: blue,
          elevation: 0,
          centerTitle: true,
          titleTextStyle:
              TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: blue),
        ),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomePage(),
    );
  }
}

class Alarm {
  Alarm({
    required this.id,
    required this.time,
    this.label = '',
    Set<int>? days,
    this.on = true,
    this.tone = 'classic',
    this.customPath,
    this.customName,
    this.fireAt,
  }) : days = days ?? <int>{};
  final int id;
  TimeOfDay time;
  String label;
  Set<int> days; // 1 = الاثنين ... 7 = الأحد
  bool on;
  String tone;
  String? customPath;
  String? customName;
  DateTime? fireAt; // وقت الرنين القادم للمنبّه لمرة واحدة

  String get toneName {
    if (tone == 'custom') return customName ?? 'نغمتي';
    return tones.firstWhere((t) => t.id == tone, orElse: () => tones.first).name;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'h': time.hour,
        'm': time.minute,
        'label': label,
        'days': days.toList(),
        'on': on,
        'tone': tone,
        'path': customPath,
        'cname': customName,
        'fire': fireAt?.millisecondsSinceEpoch,
      };

  factory Alarm.fromJson(Map<String, dynamic> j) => Alarm(
        id: j['id'] as int,
        time: TimeOfDay(hour: j['h'] as int, minute: j['m'] as int),
        label: (j['label'] ?? '') as String,
        days: Set<int>.from((j['days'] ?? <int>[]) as List),
        on: (j['on'] ?? true) as bool,
        tone: (j['tone'] ?? 'classic') as String,
        customPath: j['path'] as String?,
        customName: j['cname'] as String?,
        fireAt: j['fire'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(j['fire'] as int),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final List<Alarm> alarms = [];
  final AudioPlayer player = AudioPlayer();
  late final Timer timer;
  Timer? vibTimer;
  DateTime now = DateTime.now();
  String lastKey = '';
  bool ringing = false;
  bool fg = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer.cancel();
    vibTimer?.cancel();
    player.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    fg = s == AppLifecycleState.resumed;
    if (fg) {
      expireOneTime();
      persist();
      if (mounted) setState(() {});
    }
  }

  // ---------- الحفظ ----------
  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString('alarms');
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        alarms
          ..clear()
          ..addAll(list.map((e) => Alarm.fromJson(Map<String, dynamic>.from(e as Map))));
      }
    } catch (_) {}
    expireOneTime();
    if (mounted) setState(() {});
  }

  Future<void> persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('alarms', jsonEncode(alarms.map((a) => a.toJson()).toList()));
    } catch (_) {}
  }

  void expireOneTime() {
    final n = DateTime.now();
    for (final a in alarms) {
      if (a.days.isEmpty && a.on && a.fireAt != null && n.isAfter(a.fireAt!)) {
        a.on = false;
      }
    }
  }

  // ---------- الجدولة في نظام أندرويد ----------
  Future<void> cancelAlarm(Alarm a) async {
    for (var d = 0; d <= 9; d++) {
      try {
        await notif.cancel(a.id * 10 + d);
      } catch (_) {}
    }
  }

  Future<void> schedule(Alarm a) async {
    try {
      await cancelAlarm(a);
      if (!a.on) return;
      final nowTz = tz.TZDateTime.now(tz.local);
      final targets = a.days.isEmpty ? <int>[0] : a.days.toList();
      for (final d in targets) {
        var t = tz.TZDateTime(
            tz.local, nowTz.year, nowTz.month, nowTz.day, a.time.hour, a.time.minute);
        if (d == 0) {
          if (!t.isAfter(nowTz)) t = t.add(const Duration(days: 1));
          a.fireAt = t;
        } else {
          while (t.weekday != d || !t.isAfter(nowTz)) {
            t = t.add(const Duration(days: 1));
          }
        }
        await notif.zonedSchedule(
          a.id * 10 + d,
          a.label.isEmpty ? 'المنبّه' : a.label,
          fmt(a.time),
          t,
          alarmDetails,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: d == 0 ? null : DateTimeComponents.dayOfWeekAndTime,
        );
      }
    } catch (_) {}
  }

  Future<void> snooze(Alarm a) async {
    try {
      final t = tz.TZDateTime.now(tz.local).add(const Duration(minutes: 5));
      await notif.zonedSchedule(
        a.id * 10 + 8,
        'غفوة',
        a.label.isEmpty ? 'حان الوقت' : a.label,
        t,
        alarmDetails,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {}
  }

  // ---------- الصوت داخل التطبيق ----------
  Future<void> playTone(String id, String? path, {required bool loop}) async {
    try {
      await player.stop();
      await player.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      if (id == 'custom' && path != null) {
        await player.play(DeviceFileSource(path));
      } else {
        final t = tones.firstWhere((x) => x.id == id, orElse: () => tones.first);
        await player.play(BytesSource(t.bytes, mimeType: 'audio/wav'));
      }
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  void tick() {
    now = DateTime.now();
    if (fg && !ringing) {
      final key = '${now.year}-${now.month}-${now.day}-${now.hour}:${now.minute}';
      if (key != lastKey) {
        for (final a in alarms) {
          if (a.on &&
              a.time.hour == now.hour &&
              a.time.minute == now.minute &&
              (a.days.isEmpty || a.days.contains(now.weekday))) {
            lastKey = key;
            if (a.days.isEmpty) a.on = false;
            startRing(a.label.isEmpty ? 'حان الوقت' : a.label, a);
            // يلغي إشعار النظام (حتى ما يرنّ مرتين) ويجدول الأسبوع القادم
            schedule(a);
            persist();
            break;
          }
        }
      }
    }
    if (mounted) setState(() {});
  }

  void stopRing() {
    vibTimer?.cancel();
    player.stop();
    ringing = false;
  }

  void startRing(String label, Alarm a) {
    ringing = true;
    playTone(a.tone, a.customPath, loop: true);
    HapticFeedback.vibrate();
    vibTimer = Timer.periodic(const Duration(seconds: 2), (_) => HapticFeedback.vibrate());
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(label, textAlign: TextAlign.center, style: const TextStyle(color: blue)),
        content: Text(
          fmt(TimeOfDay.now()),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: blue),
        ),
        actions: [
          TextButton(
            onPressed: () {
              snooze(a);
              Navigator.pop(ctx);
            },
            child: const Text('غفوة 5 دقائق'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إيقاف'),
          ),
        ],
      ),
    ).then((_) => stopRing());
  }

  String nextText() {
    DateTime? best;
    for (final a in alarms.where((a) => a.on)) {
      for (var d = 0; d < 8; d++) {
        final base = now.add(Duration(days: d));
        final t = DateTime(base.year, base.month, base.day, a.time.hour, a.time.minute);
        if (!t.isAfter(now)) continue;
        if (a.days.isNotEmpty && !a.days.contains(t.weekday)) continue;
        if (best == null || t.isBefore(best)) best = t;
        break;
      }
    }
    if (best == null) return 'لا يوجد منبّه مفعّل';
    final mins = (best.difference(now).inSeconds / 60).ceil();
    final h = mins ~/ 60;
    final m = mins % 60;
    final parts = <String>[];
    if (h > 0) parts.add('$h ساعة');
    if (m > 0 || h == 0) parts.add('$m دقيقة');
    return 'أقرب منبّه بعد ${parts.join(' و ')}';
  }

  Future<void> edit([Alarm? a]) async {
    var time = a?.time ?? TimeOfDay.now();
    final label = TextEditingController(text: a?.label ?? '');
    final days = <int>{...?a?.days};
    var tone = a?.tone ?? 'classic';
    String? customPath = a?.customPath;
    String? customName = a?.customName;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextButton(
                onPressed: () async {
                  final t = await showTimePicker(context: ctx, initialTime: time);
                  if (t != null) setS(() => time = t);
                },
                child: Text(fmt(time),
                    style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
              ),
              TextField(
                controller: label,
                maxLength: 30,
                decoration: const InputDecoration(
                    labelText: 'الاسم', hintText: 'مثال: صلاة الفجر'),
              ),
              const Text('التكرار (بدون اختيار = مرة واحدة)'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (var i = 1; i <= 7; i++)
                    FilterChip(
                      label: Text(dayNames[i - 1]),
                      selected: days.contains(i),
                      onSelected: (v) => setS(() {
                        if (v) {
                          days.add(i);
                        } else {
                          days.remove(i);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              const Text('النغمة (اضغط على النغمة لتسمعها)'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in tones)
                    ChoiceChip(
                      avatar: const Icon(Icons.music_note, size: 18),
                      label: Text(t.name),
                      selected: tone == t.id,
                      onSelected: (_) {
                        setS(() => tone = t.id);
                        playTone(t.id, null, loop: false);
                      },
                    ),
                  if (customPath != null)
                    ChoiceChip(
                      avatar: const Icon(Icons.audio_file, size: 18),
                      label: Text(customName ?? 'نغمتي'),
                      selected: tone == 'custom',
                      onSelected: (_) {
                        setS(() => tone = 'custom');
                        playTone('custom', customPath, loop: false);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.library_music),
                label: const Text('إضافة نغمة من جوالك'),
                onPressed: () async {
                  final r = await FilePicker.platform.pickFiles(type: FileType.audio);
                  final f = r?.files.single;
                  if (f != null && f.path != null) {
                    setS(() {
                      customPath = f.path;
                      customName = f.name;
                      tone = 'custom';
                    });
                    playTone('custom', customPath, loop: false);
                  }
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'ملاحظة: إذا كان التطبيق مغلقاً، يرنّ المنبّه بنغمة المنبّه الافتراضية في جوالك.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7385)),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('حفظ المنبّه'),
              ),
            ],
          ),
        ),
      ),
    );
    player.stop();

    if (saved == true) {
      final Alarm target;
      if (a != null) {
        target = a
          ..time = time
          ..label = label.text.trim()
          ..days = days
          ..on = true
          ..tone = tone
          ..customPath = customPath
          ..customName = customName;
      } else {
        target = Alarm(
          id: DateTime.now().millisecondsSinceEpoch % 100000000,
          time: time,
          label: label.text.trim(),
          days: days,
          tone: tone,
          customPath: customPath,
          customName: customName,
        );
        alarms.add(target);
      }
      setState(() {
        alarms.sort((x, y) =>
            (x.time.hour * 60 + x.time.minute) - (y.time.hour * 60 + y.time.minute));
      });
      await schedule(target);
      await persist();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hh = (now.hour % 12 == 0 ? 12 : now.hour % 12).toString();
    final mm = now.minute.toString().padLeft(2, '0');
    final ss = now.second.toString().padLeft(2, '0');
    const grey = Color(0xFF6B7385);
    return Scaffold(
      appBar: AppBar(title: const Text('المنبّه')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: blue,
        foregroundColor: Colors.white,
        onPressed: () => edit(),
        icon: const Icon(Icons.add_alarm),
        label: const Text('إضافة منبّه'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        children: [
          const SizedBox(height: 16),
          Center(
            child: Text(
              '$hh:$mm:$ss ${now.hour < 12 ? 'ص' : 'م'}',
              textDirection: TextDirection.ltr,
              style: const Te