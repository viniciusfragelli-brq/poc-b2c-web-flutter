import 'package:flutter/material.dart';

import 'ui/home_page.dart';

void main() => runApp(const PocLoginApp());

class PocLoginApp extends StatelessWidget {
  const PocLoginApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'POC Login AD · WebView',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFFF6A13),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
