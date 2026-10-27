import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;

// ---------------- API ----------------
class Api {
  // Android emulator -> host machine is 10.0.2.2. Real phone: your LAN IP or deployed HTTPS URL.
  static final base = (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
      ? 'http://10.0.2.2:3000'
      : 'http://localhost:3000';
  static String? token;
  static String name = '';
  static int uid = 0;

  static Future<dynamic> req(String method, String path, [Map? body]) async {
    final r = http.Request(method, Uri.parse('$base$path'))..headers['Content-Type'] = 'application/json';
    if (token != null) r.headers['Authorization'] = 'Bearer $token';
    if (body != null) r.body = jsonEncode(body);
    final res = await http.Response.fromStream(await r.send().timeout(const Duration(seconds: 20)));
    final data = res.body.isEmpty ? null : jsonDecode(res.body);
    if (res.statusCode >= 400) throw (data?['error'] ?? 'Error ${res.statusCode}');
    return data;
  }

  static Future<void> saveSession(Map d) async {
    token = d['token'];
    name = d['user']['name'];
    uid = d['user']['id'];
    final p = await SharedPreferences.getInstance();
    await p.setString('token', token!);
    await p.setString('name', name);
    await p.setInt('uid', uid);
  }

  static Future<void> logout() async {
    Net.close();
    token = null;
    (await SharedPreferences.getInstance()).clear();
  }
}

// ---------------- Realtime ----------------
class Net {
  static sio.Socket? _s;
  static final state = ValueNotifier<Map<String, dynamic>?>(null); // current game
  static final lobby = ValueNotifier<Map<String, dynamic>?>(null); // online count + open rooms
  static final chat = ValueNotifier<List<Map<String, dynamic>>>([]);
  static final message = ValueNotifier<String?>(null);

  static Map<String, dynamic> _m(dynamic d) => Map<String, dynamic>.from(d);

  static void connect() {
    close();
    _s = sio.io(
        Api.base,
        sio.OptionBuilder()
            .setTransports(['websocket'])
            .setAuth({'token': Api.token})
            .disableAutoConnect()
            .build());
    _s!.on('state', (d) => state.value = _m(d));
    _s!.on('lobby', (d) => lobby.value = _m(d));
    _s!.on('chat_history', (d) => chat.value = (d as List).map(_m).toList());
    _s!.on('chat', (d) => chat.value = [...chat.value, _m(d)]);
    _s!.on('error_msg', (d) => message.value = d.toString());
    _s!.on('connect_error', (d) => message.value = 'Connection problem: $d');
    _s!.connect();
  }

  static void emit(String e, [dynamic d]) => _s?.emit(e, d);
  static void leave() {
    emit('leave');
    state.value = null;
  }

  static void close() {
    _s?.dispose();
    _s = null;
    state.value = null;
    lobby.value = null;
    chat.value = [];
  }
}

// ---------------- App ----------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  Api.token = p.getString('token');
  Api.name = p.getString('name') ?? '';
  Api.uid = p.getInt('uid') ?? 0;
  runApp(MaterialApp(
    title: 'Tic-Tac-Toe Online',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: Api.token == null ? const AuthPage() : const LobbyPage(),
  ));
}

void snack(BuildContext c, Object m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m.toString())));

// ---------------- Step 1: email + password ----------------
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _name = TextEditingController(), _email = TextEditingController(), _pass = TextEditingController();
  bool _register = false, _busy = false;

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final d = await Api.req('POST', _register ? '/api/register' : '/api/login', {
        'name': _name.text.trim(),
        'email': _email.text.trim(),
        'password': _pass.text,
      });
      if (!mounted) return;
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => CodePage(challengeId: d['challengeId'], email: _email.text.trim())));
    } catch (e) {
      if (mounted) snack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.grid_3x3, size: 64, color: Colors.indigo),
              const SizedBox(height: 8),
              Text('Tic-Tac-Toe Online',
                  textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 24),
              if (_register) ...[
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Display name', border: OutlineInputBorder())),
                const SizedBox(height: 12),
              ],
              TextField(controller: _email, keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _pass, obscureText: true, onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder())),
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? 'Please wait…' : (_register ? 'Sign up' : 'Log in'))),
              TextButton(
                  onPressed: () => setState(() => _register = !_register),
                  child: Text(_register ? 'Have an account? Log in' : 'New here? Create an account')),
            ]),
          ),
        ),
      );
}

// ---------------- Step 2: emailed 6-digit code ----------------
class CodePage extends StatefulWidget {
  final String challengeId, email;
  const CodePage({super.key, required this.challengeId, required this.email});
  @override
  State<CodePage> createState() => _CodePageState();
}

class _CodePageState extends State<CodePage> {
  final _code = TextEditingController();
  bool _busy = false;

  Future<void> _verify() async {
    setState(() => _busy = true);
    try {
      final d = await Api.req('POST', '/api/verify', {'challengeId': widget.challengeId, 'code': _code.text.trim()});
      await Api.saveSession(d);
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LobbyPage()), (_) => false);
    } catch (e) {
      if (mounted) snack(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resend() async {
    try {
      await Api.req('POST', '/api/resend', {'challengeId': widget.challengeId});
      if (mounted) snack(context, 'New code sent');
    } catch (e) {
      if (mounted) snack(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text("Verify it's you")),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(24), children: [
              const Icon(Icons.mark_email_read, size: 56, color: Colors.indigo),
              const SizedBox(height: 12),
              Text('We emailed a 6-digit code to ${widget.email}', textAlign: TextAlign.center),
              const SizedBox(height: 20),
              TextField(
                controller: _code,
                keyboardType: TextInputType.number,
                maxLength: 6,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 28, letterSpacing: 8),
                onSubmitted: (_) => _verify(),
                decoration: const InputDecoration(border: OutlineInputBorder(), counterText: ''),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy ? null : _verify, child: Text(_busy ? 'Checking…' : 'Verify')),
              TextButton(onPressed: _resend, child: const Text('Resend code')),
            ]),
          ),
        ),
      );
}

// ---------------- Multiplayer lobby (Play + Chat tabs) ----------------
class LobbyPage extends StatefulWidget {
  const LobbyPage({super.key});
  @override
  State<LobbyPage> createState() => _LobbyPageState();
}

class _LobbyPageState extends State<LobbyPage> {
  final _code = TextEditingController(), _msg = TextEditingController();
  bool _searching = false, _inGame = false;
  Map? _me;

  @override
  void initState() {
    super.initState();
    Net.connect();
    Net.state.addListener(_onState);
    Net.message.addListener(_onMessage);
    _loadMe();
  }

  @override
  void dispose() {
    Net.state.removeListener(_onState);
    Net.message.removeListener(_onMessage);
    super.dispose();
  }

  void _onMessage() {
    final m = Net.message.value;
    if (m != null && mounted) {
      snack(context, m);
      Net.message.value = null;
      setState(() => _searching = false);
    }
  }

  void _onState() {
    if (Net.state.value != null && !_inGame && mounted) {
      _inGame = true;
      setState(() => _searching = false);
      Navigator.push(context, MaterialPageRoute(builder: (_) => const GamePage())).then((_) {
        _inGame = false;
        Net.leave();
        _loadMe();
      });
    }
  }

  Future<void> _loadMe() async {
    try {
      final d = await Api.req('GET', '/api/me');
      if (mounted) setState(() => _me = d);
    } catch (e) {
      if (e.toString().contains('authenticated')) _logout();
    }
  }

  Future<void> _logout() async {
    await Api.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const AuthPage()), (_) => false);
  }

  Future<void> _leaderboard() async {
    try {
      final l = await Api.req('GET', '/api/leaderboard') as List;
      if (!mounted) return;
      showDialog(
          context: context,
          builder: (_) => AlertDialog(
                title: const Text('Leaderboard'),
                content: SizedBox(
                    width: 320,
                    child: ListView(shrinkWrap: true, children: [
                      for (var i = 0; i < l.length; i++)
                        ListTile(
                            dense: true,
                            leading: Text('${i + 1}'),
                            title: Text(l[i]['name']),
                            trailing: Text('${l[i]['wins']}W ${l[i]['losses']}L ${l[i]['draws']}D')),
                    ])),
              ));
    } catch (e) {
      if (mounted) snack(context, e);
    }
  }

  void _send() {
    final t = _msg.text.trim();
    if (t.isEmpty) return;
    Net.emit('chat', t);
    _msg.clear();
  }

  Widget _playTab() {
    final st = _me?['stats'];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: ListView(padding: const EdgeInsets.all(16), children: [
          ValueListenableBuilder<Map<String, dynamic>?>(
            valueListenable: Net.lobby,
            builder: (_, l, __) {
              final rooms = (l?['rooms'] as List?) ?? [];
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Card(
                    child: ListTile(
                  leading: const Icon(Icons.circle, color: Colors.green, size: 14),
                  title: Text('${l?['online'] ?? 1} players online'),
                  subtitle: st == null ? null : Text('Your record: ${st['wins']}W ${st['losses']}L ${st['draws']}D'),
                )),
                const SizedBox(height: 12),
                if (_searching) ...[
                  const Center(child: CircularProgressIndicator()),
                  const SizedBox(height: 12),
                  const Text('Looking for an opponent…', textAlign: TextAlign.center),
                  TextButton(
                      onPressed: () {
                        Net.emit('cancel');
                        setState(() => _searching = false);
                      },
                      child: const Text('Cancel')),
                ] else ...[
                  FilledButton.icon(
                      icon: const Icon(Icons.bolt),
                      label: const Text('Quick match'),
                      onPressed: () {
                        Net.emit('quick');
                        setState(() => _searching = true);
                      }),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child: OutlinedButton.icon(
                            icon: const Icon(Icons.public),
                            label: const Text('Public room'),
                            onPressed: () => Net.emit('create', {'public': true}))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: OutlinedButton.icon(
                            icon: const Icon(Icons.lock),
                            label: const Text('Private room'),
                            onPressed: () => Net.emit('create', {'public': false}))),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                        child: TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Room code', border: OutlineInputBorder(), isDense: true),
                      onSubmitted: (v) => Net.emit('join', v),
                    )),
                    const SizedBox(width: 8),
                    FilledButton(onPressed: () => Net.emit('join', _code.text), child: const Text('Join')),
                  ]),
                ],
                const SizedBox(height: 24),
                Text('Open games', style: Theme.of(context).textTheme.titleMedium),
                if (rooms.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text('No open games right now. Create a public room!')),
                for (final r in rooms)
                  Card(
                      child: ListTile(
                    leading: const Icon(Icons.sports_esports),
                    title: Text("${r['host']}'s game"),
                    subtitle: Text('Room ${r['code']}'),
                    trailing: FilledButton(onPressed: () => Net.emit('join', r['code']), child: const Text('Join')),
                  )),
              ]);
            },
          ),
        ]),
      ),
    );
  }

  Widget _chatTab() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(children: [
            Expanded(
              child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                valueListenable: Net.chat,
                builder: (_, msgs, __) => msgs.isEmpty
                    ? const Center(child: Text('No messages yet. Say hi!'))
                    : ListView(reverse: true, children: [
                        for (final m in msgs.reversed)
                          ListTile(
                              dense: true,
                              title: Text(m['name'],
                                  style: TextStyle(fontWeight: FontWeight.bold, color: m['name'] == Api.name ? Colors.indigo : null)),
                              subtitle: Text(m['text'])),
                      ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(children: [
                Expanded(
                    child: TextField(
                        controller: _msg,
                        maxLength: 200,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(hintText: 'Message everyone…', border: OutlineInputBorder(), counterText: ''))),
                IconButton(icon: const Icon(Icons.send), onPressed: _send),
              ]),
            ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: Text('Hi, ${Api.name}'),
            actions: [
              IconButton(icon: const Icon(Icons.leaderboard), tooltip: 'Leaderboard', onPressed: _leaderboard),
              IconButton(icon: const Icon(Icons.logout), tooltip: 'Log out', onPressed: _logout),
            ],
            bottom: const TabBar(tabs: [
              Tab(icon: Icon(Icons.public), text: 'Multiplayer'),
              Tab(icon: Icon(Icons.chat), text: 'Chat'),
            ]),
          ),
          body: TabBarView(children: [_playTab(), _chatTab()]),
        ),
      );
}

// ---------------- Game ----------------
class GamePage extends StatelessWidget {
  const GamePage({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: Net.state,
        builder: (context, s, _) {
          if (s == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          final players = s['players'] as Map;
          final mySym = players['X']?['id'] == Api.uid ? 'X' : 'O';
          final oppSym = mySym == 'X' ? 'O' : 'X';
          final board = List<String>.from(s['board']);
          final status = s['status'];
          final winner = s['winner'];
          final bothHere = players['X'] != null && players['O'] != null;

          String text;
          if (status == 'waiting') {
            text = 'Waiting for opponent… share code ${s['code']}';
          } else if (status == 'playing') {
            text = s['turn'] == mySym ? 'Your turn ($mySym)' : "${players[oppSym]?['name'] ?? 'Opponent'}'s turn";
          } else {
            text = winner == 'draw' ? "It's a draw!" : (winner == mySym ? 'You won! 🎉' : 'You lost');
            if ((s['note'] ?? '').toString().isNotEmpty) text += '\n${s['note']}';
          }

          return Scaffold(
            appBar: AppBar(title: Text('Room ${s['code']}')),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
                  Text('You ($mySym) vs ${players[oppSym]?['name'] ?? '…'} ($oppSym)',
                      textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  GridView.count(
                    crossAxisCount: 3,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    children: [
                      for (var i = 0; i < 9; i++)
                        InkWell(
                          onTap: () => Net.emit('move', i),
                          child: Container(
                            decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(12)),
                            child: Center(
                                child: Text(board[i],
                                    style: TextStyle(
                                        fontSize: 56,
                                        fontWeight: FontWeight.bold,
                                        color: board[i] == 'X' ? Colors.indigo : Colors.pink))),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (status == 'finished' && bothHere)
                    FilledButton(onPressed: () => Net.emit('rematch'), child: const Text('Rematch')),
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Leave game')),
                ]),
              ),
            ),
          );
        },
      );
}
