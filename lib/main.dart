import 'package:flutter/material.dart';

import 'data/game_repository.dart';
import 'pages/main_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await GameRepository.instance.init();
  runApp(const JigsawPuzzleApp());
}

class JigsawPuzzleApp extends StatelessWidget {
  const JigsawPuzzleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '异形拼图 Jigsaw Puzzle',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        fontFamilyFallback: const ['Microsoft YaHei', 'PingFang SC', 'sans-serif'],
      ),
      home: const MainScreen(),
    );
  }
}
