import 'package:flutter/material.dart';
import 'package:zapiack/zapiack.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  String _status = 'Not started';

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final push = ZapiackPush.instance;
    await push.configure(appKey: 'pk_example', appGroup: 'group.com.zapiack.example');
    push.onTap.listen((tap) => setState(() => _status = 'Tapped: ${tap.link}'));
    final initial = await push.getInitialTap();
    if (initial != null) setState(() => _status = 'Opened by: ${initial.link}');
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Zapiack Push')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_status),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () async {
                  final allowed = await ZapiackPush.instance.requestPermission();
                  setState(() => _status = allowed ? 'Allowed' : 'Not allowed');
                },
                child: const Text('Turn on notifications'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
