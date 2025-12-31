import 'package:flutter/material.dart';
// 稍后我们将在这里导入其他包
import 'package:camera/camera.dart';

// 将变量定义在 main 函数外部，以便全局访问
List<CameraDescription> cameras = [];

Future<void> main() async {
  // 确保 Flutter 框架已初始化
  WidgetsFlutterBinding.ensureInitialized();
  // 获取设备上的相机列表
  cameras = await availableCameras();

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

      home: JumpCaptureHomePage(cameras: cameras), // 应用的主页
    );
  }
}

// 主页 StatefulWidget
class JumpCaptureHomePage extends StatefulWidget {
  // 接收从main函数传递过来的相机列表
  final List<CameraDescription> cameras;
  const JumpCaptureHomePage({super.key, required this.cameras});

  @override
  State<JumpCaptureHomePage> createState() => _JumpCaptureHomePageState();
}

// 主页状态类
class _JumpCaptureHomePageState extends State<JumpCaptureHomePage> {
  // 后续相机控制器、状态变量等将在这里声明
  // 相机控制器，用于控制相机（如开启、关闭、拍照）
  CameraController? _controller;
  // 标记相机是否已初始化完成
  bool _isCameraInitialized = false;

  @override
  void initState() {
    super.initState();
    // 页面初始化时，启动相机
    _initializeCamera();
  }

  // 初始化相机的异步方法
  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      print('未找到可用相机');
      return;
    }
    // 通常使用后置摄像头，widget.cameras[0] 是后置
    final camera = widget.cameras[0];
    _controller = CameraController(
      camera,
      ResolutionPreset.medium, // 分辨率预设：中等，平衡性能与画质
      enableAudio: false, // 不申请音频权限 - 最小化权限申请
    );

    try {
      // 必须调用 initialize 方法，这是一个异步操作
      await _controller!.initialize();
      setState(() {
        _isCameraInitialized = true; // 标记初始化完成
      });
    } on CameraException catch (e) {
      print('相机初始化失败: $e');
    }
  }

  @override
  void dispose() {
    // 页面销毁时，务必释放相机控制器资源
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跳跃抓拍'),
        actions: [
          // 可以在这里添加设置按钮等
          IconButton(icon: const Icon(Icons.settings), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          // 区域1：相机预览 (稍后用CameraPreview填充)
          Expanded(child: _buildCameraPreview()),
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
                label: const Text('跳高抓拍', style: TextStyle(fontSize: 20)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 构建相机预览的组件
  Widget _buildCameraPreview() {
    if (!_isCameraInitialized || _controller == null) {
      // 如果相机未就绪，显示加载指示器
      return const Center(child: CircularProgressIndicator());
    }
    print('相机已就绪，显示 CameraPreview');
    // 如果相机已就绪，显示 CameraPreview
    return CameraPreview(_controller!);
  }

  // 抓拍按钮点击事件处理函数
  void _captureJump() {
    // 稍后实现抓拍逻辑
    print('抓拍按钮被点击！');
  }
}
