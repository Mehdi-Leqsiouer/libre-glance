import 'package:flutter/material.dart';

void main() => runApp(const LibreGlanceApp());

class LibreGlanceApp extends StatelessWidget {
  const LibreGlanceApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'LibreGlance',
    home: Scaffold(body: Center(child: Text('LibreGlance'))),
  );
}
