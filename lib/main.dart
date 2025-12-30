import 'package:flutter/material.dart';
// 稍后我们将在这里导入其他包

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '跳跃抓拍',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true, // 启用Material 3设计
      ),
      home: const JumpCaptureHomePage(), // 应用的主页
    );
  }
}

// 主页 StatefulWidget
class JumpCaptureHomePage extends StatefulWidget {
  const JumpCaptureHomePage({super.key});

  @override
  State<JumpCaptureHomePage> createState() => _JumpCaptureHomePageState();
}

// 主页状态类
class _JumpCaptureHomePageState extends State<JumpCaptureHomePage> {
  // 后续相机控制器、状态变量等将在这里声明

  @override
  void initState() {
    super.initState();
    // 后续相机初始化将在这里进行
  }

  @override
  void dispose() {
    // 后续清理相机资源将在这里进行
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跳跃抓拍'),
        actions: [
          // 可以在这里添加设置按钮等
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          // 区域1：相机预览 (稍后用CameraPreview填充)
          Expanded(
            child: Container(
              color: Colors.black,
              child: const Center(
                child: Text(
                  '相机预览区域',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          // 区域2：控制按钮区域
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: SizedBox(
              width: double.infinity, // 使按钮宽度最大
              height: 60, // 设置按钮高度
              child: FilledButton.icon(
                onPressed: () {
                  // 抓拍按钮点击事件
                  _captureJump();
                },
                icon: const Icon(Icons.camera_alt),
                label: const Text(
                  '跳高抓拍',
                  style: TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 抓拍按钮点击事件处理函数
  void _captureJump() {
    // 稍后实现抓拍逻辑
    print('抓拍按钮被点击！');
  }
}
