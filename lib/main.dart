import 'dart:async';
import 'dart:ui';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory;
import 'package:image/image.dart' as img;
import 'dart:io';
import 'package:flutter/services.dart';

// 全局变量，用于在main函数中获取相机列表
List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '跳跃抓拍',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: JumpCaptureHomePage(cameras: cameras),
    );
  }
}

/// 主页，承载相机预览、姿态检测和抓拍逻辑
class JumpCaptureHomePage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const JumpCaptureHomePage({super.key, required this.cameras});

  @override
  State<JumpCaptureHomePage> createState() => _JumpCaptureHomePageState();
}

// --- 跳跃检测状态机 ---
enum CaptureState { idle, calibrating, detecting, capturing, success }

/// 主页状态类，包含所有核心逻辑
class _JumpCaptureHomePageState extends State<JumpCaptureHomePage> {
  // --- 相机控制 ---
  CameraController? _controller;
  bool _isCameraInitialized = false;
  Size _imageSize = Size.zero;

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // --- 姿态检测 ---
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(),
  );
  List<Pose> _poses = [];
  bool _isProcessing = false;

  CaptureState _captureState = CaptureState.idle; // 当前状态

  // --- 地面基线校准 ---
  static const int calibrationFrameCount = 30; // 校准采样帧数
  List<double> _ankleSamples = []; // 脚踝Y坐标采样列表
  double _groundBaseline = 0.0; // 计算得到的地面基线
  double _jumpThreshold = 25.0; // 离地判断阈值（像素）

  // --- 帧缓存（用于回溯保存最佳帧）---
  static const int cacheFrameCount = 15; // 缓存最近N帧（约0.5秒@30fps）
  List<CameraImage> _frameCache = [];
  final List<Completer<CameraImage?>> _captureCompleters = [];

  // --- UI反馈 ---
  String _statusText = '准备就绪';
  Color _statusColor = Colors.blue;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  /// 初始化相机
  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      _updateStatus('未找到可用相机', Colors.red);
      return;
    }
    final camera = widget.cameras[0];
    _controller = CameraController(
      camera,
      ResolutionPreset.max,
      enableAudio: false,

      // https://pub.dev/packages/google_mlkit_commons
      imageFormatGroup: Platform.isAndroid
          ? ImageFormatGroup
                .nv21 // for Android
          : ImageFormatGroup.bgra8888, // for iOS
    );

    try {
      await _controller!.initialize();
      // 获取图像尺寸，用于坐标转换
      _imageSize = Size(
        _controller!.value.previewSize!.height.toDouble(),
        _controller!.value.previewSize!.width.toDouble(),
      );
      _startImageStream();
      setState(() => _isCameraInitialized = true);
      _updateStatus('点击下方按钮开始跳跃抓拍', Colors.blue);
    } on CameraException catch (e) {
      _updateStatus('相机初始化失败: $e', Colors.red);
    }
  }

  /// 启动相机图像流
  void _startImageStream() {
    if (_controller == null) return;

    _controller!.startImageStream((CameraImage image) {
      _addFrameToCache(image); // 缓存每一帧
      print(
        '_startImageStream addFrameToCache _isProcessing is $_isProcessing',
      );
      if (_isProcessing) return;
      _processImage(image);
    });
  }

  /// 处理图像，进行姿态检测和跳跃判断
  Future<void> _processImage(CameraImage image) async {
    print('_processImage start');
    _isProcessing = true;
    try {
      final inputImage = _convertToInputImage(image);
      final List<Pose> detectedPoses = await _poseDetector.processImage(
        inputImage,
      );

      print('检测到姿态数量: ${detectedPoses.length}');

      if (mounted) {
        setState(() => _poses = detectedPoses);
      }

      // 仅在检测到人体且处于活跃状态时，进行后续逻辑
      if (detectedPoses.isNotEmpty &&
          _captureState.index >= CaptureState.calibrating.index) {
        final pose = detectedPoses.first;
        final leftAnkle = pose.landmarks[PoseLandmarkType.leftAnkle];
        final rightAnkle = pose.landmarks[PoseLandmarkType.rightAnkle];

        if (leftAnkle != null && rightAnkle != null) {
          final double currentAnkleY = (leftAnkle.y + rightAnkle.y) / 2.0;

          switch (_captureState) {
            case CaptureState.calibrating:
              _handleCalibration(currentAnkleY);
              break;
            case CaptureState.detecting:
              _handleJumpDetection(currentAnkleY);
              break;
            default:
              break;
          }
        }
      }
    } catch (e) {
      print('图像处理错误: $e');
    } finally {
      _isProcessing = false;
    }
  }

  /// 将CameraImage转换为ML Kit所需的InputImage
  /// https://pub.dev/packages/google_mlkit_commons
  InputImage _convertToInputImage(CameraImage image) {
    // get image rotation
    // it is used in android to convert the InputImage from Dart to Java
    // `rotation` is not used in iOS to convert the InputImage from Dart to Obj-C
    // in both platforms `rotation` and `camera.lensDirection` can be used to compensate `x` and `y` coordinates on a canvas
    final camera = widget.cameras[0];

    // final camera = _cameras[_cameraIndex];
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;
    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation =
          _orientations[_controller!.value.deviceOrientation];
      if (rotationCompensation == null) {
        throw FormatException('Unknown device orientation');
      }
      if (camera.lensDirection == CameraLensDirection.front) {
        // front-facing
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        // back-facing
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }
    if (rotation == null) {
      throw FormatException('Unknown input image rotation');
    }

    // get image format
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    // validate format depending on platform
    // only supported formats:
    // * nv21 for Android
    // * bgra8888 for iOS
    if (format == null ||
        (Platform.isAndroid && format != InputImageFormat.nv21) ||
        (Platform.isIOS && format != InputImageFormat.bgra8888)) {
      throw FormatException('Unknown input image format');
    }

    // since format is constraint to nv21 or bgra8888, both only have one plane
    if (image.planes.length != 1) {
      throw FormatException('CameraImage planes 为空');
    }

    final plane = image.planes.first;

    // compose InputImage using bytes
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation, // used only in Android
        format: format, // used only in iOS
        bytesPerRow: plane.bytesPerRow, // used only in iOS
      ),
    );
  }

  /// 处理校准阶段：采集脚踝Y坐标样本
  void _handleCalibration(double ankleY) {
    print('采样脚踝Y坐标: $ankleY'); // 添加这行

    _ankleSamples.add(ankleY);
    final int collected = _ankleSamples.length;
    final int total = calibrationFrameCount;

    // 更新UI进度
    _updateStatus('校准中... ($collected/$total)', Colors.orange);

    if (collected >= total) {
      // 校准完成，计算基线
      _groundBaseline = _ankleSamples.reduce((a, b) => a + b) / total;
      _updateStatus('校准完成！准备起跳！', Colors.green);
      // 切换到检测状态，等待跳跃
      setState(() => _captureState = CaptureState.detecting);
    }
  }

  /// 处理跳跃检测：判断双脚是否离地
  void _handleJumpDetection(double currentAnkleY) {
    // 如果当前脚踝位置低于基线减去阈值，则判定为离地
    if (currentAnkleY < (_groundBaseline - _jumpThreshold)) {
      _updateStatus('检测到跳跃！正在抓拍...', Colors.purple);
      _triggerCapture();
    }
  }

  /// 触发抓拍：从缓存中寻找并保存最佳帧
  Future<void> _triggerCapture() async {
    if (_captureState == CaptureState.capturing) return; // 防止重复触发
    setState(() => _captureState = CaptureState.capturing);

    // 从缓存中回溯寻找跳跃瞬间的帧（例如，缓存中间位置的帧）
    final int bestFrameIndex = (_frameCache.length / 2).floor();
    CameraImage? bestFrame;
    if (bestFrameIndex < _frameCache.length) {
      bestFrame = _frameCache[bestFrameIndex];
    }

    if (bestFrame != null) {
      final String? savedPath = await _saveImage(bestFrame);
      if (savedPath != null && mounted) {
        _updateStatus('抓拍成功！照片已保存。', Colors.green);
        setState(() => _captureState = CaptureState.success);
        // 3秒后重置状态
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            _resetCaptureState();
            _updateStatus('准备开始新一轮抓拍', Colors.blue);
          }
        });
      } else {
        _updateStatus('保存照片失败', Colors.red);
        _resetCaptureState();
      }
    } else {
      _updateStatus('未能获取有效帧', Colors.red);
      _resetCaptureState();
    }
  }

  /// 重置抓拍状态，准备下一次拍摄
  void _resetCaptureState() {
    if (mounted) {
      setState(() {
        _captureState = CaptureState.idle;
        _ankleSamples.clear();
        _groundBaseline = 0.0;
      });
    }
  }

  /// 将图像保存到本地相册（简化示例，保存到应用目录）
  Future<String?> _saveImage(CameraImage image) async {
    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      final String filePath = '${appDir.path}/jump_capture_$timestamp.png';

      // 将YUV（NV21）格式的CameraImage转换为RGB，然后编码为PNG
      final img.Image? convertedImage = _convertYUV420toImage(image);
      if (convertedImage == null) return null;

      final File file = File(filePath);
      await file.writeAsBytes(img.encodePng(convertedImage));
      print('照片已保存至: $filePath');
      return filePath;
    } catch (e) {
      print('保存图像时出错: $e');
      return null;
    }
  }

  /// 图像格式转换辅助函数（YUV420 NV21 转 RGB）
  img.Image? _convertYUV420toImage(CameraImage image) {
    // 注意：这是一个简化的转换函数，实际项目中可能需要更精确的转换
    // 此处使用一个占位实现，你需要根据CameraImage的实际格式完善它
    // 或者使用更成熟的图像处理库（如 `camera` 插件可能提供的转换工具）
    // 这里返回一个临时红色占位图像用于演示
    final img.Image newImage = img.Image(
      width: image.width,
      height: image.height,
    );
    img.fill(newImage, color: img.ColorRgb8(255, 0, 0)); // 红色占位
    return newImage;
  }

  /// 将帧添加到缓存队列
  void _addFrameToCache(CameraImage image) {
    _frameCache.add(image);
    if (_frameCache.length > cacheFrameCount) {
      _frameCache.removeAt(0);
    }
  }

  /// 更新UI状态文本和颜色
  void _updateStatus(String text, Color color) {
    if (mounted) {
      setState(() {
        _statusText = text;
        _statusColor = color;
      });
    }
  }

  /// 点击“跳高抓拍”按钮的主逻辑入口
  void _onCaptureButtonPressed() {
    if (_captureState != CaptureState.idle &&
        _captureState != CaptureState.success) {
      return; // 正在执行中，忽略点击
    }
    _resetCaptureState();
    _updateStatus('请保持站立姿势，正在校准地面基线...', Colors.orange);
    setState(() => _captureState = CaptureState.calibrating);
  }

  /// 根据当前状态，返回按钮的文本
  String _getButtonText() {
    switch (_captureState) {
      case CaptureState.calibrating:
        return '校准中...';
      case CaptureState.detecting:
        return '检测跳跃中...';
      case CaptureState.capturing:
        return '抓拍中...';
      case CaptureState.success:
        return '抓拍成功！';
      default:
        return '跳高抓拍';
    }
  }

  /// 根据当前状态，决定按钮是否可点击
  bool _isButtonEnabled() {
    return _captureState == CaptureState.idle ||
        _captureState == CaptureState.success;
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _poseDetector.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('跳跃抓拍'), backgroundColor: _statusColor),
      body: Column(
        children: [
          // 状态显示栏
          Container(
            padding: const EdgeInsets.all(12),
            color: _statusColor.withOpacity(0.1),
            child: Row(
              children: [
                Icon(_getStatusIcon(), color: _statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusText,
                    style: TextStyle(
                      fontSize: 16,
                      color: _statusColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (_groundBaseline > 0)
                  Text(
                    '基线: ${_groundBaseline.toStringAsFixed(1)}',
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
              ],
            ),
          ),

          // 相机预览与骨骼点绘制层
          Expanded(child: _buildCameraPreview()),

          // 控制按钮区域
          Padding(
            padding: const EdgeInsets.all(20.0),
            child: SizedBox(
              width: double.infinity,
              height: 60,
              child: FilledButton.icon(
                onPressed: _isButtonEnabled() ? _onCaptureButtonPressed : null,
                icon: Icon(_getButtonIcon()),
                label: Text(
                  _getButtonText(),
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建相机预览和骨骼点叠加层
  Widget _buildCameraPreview() {
    if (!_isCameraInitialized || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Stack(
      children: [
        CameraPreview(_controller!),
        CustomPaint(
          painter: _PosePainter(poses: _poses, absoluteImageSize: _imageSize),
          child: Container(),
        ),
      ],
    );
  }

  /// 获取状态图标
  IconData _getStatusIcon() {
    switch (_captureState) {
      case CaptureState.calibrating:
        return Icons.timer;
      case CaptureState.detecting:
        return Icons.directions_run;
      case CaptureState.capturing:
        return Icons.camera;
      case CaptureState.success:
        return Icons.check_circle;
      default:
        return Icons.info;
    }
  }

  /// 获取按钮图标
  IconData _getButtonIcon() {
    switch (_captureState) {
      case CaptureState.success:
        return Icons.check;
      default:
        return Icons.camera_alt;
    }
  }
}

/// 自定义绘制器，用于在预览上绘制人体骨骼关键点
class _PosePainter extends CustomPainter {
  final List<Pose> poses;
  final Size absoluteImageSize;

  _PosePainter({required this.poses, required this.absoluteImageSize});

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final scaleX = canvasSize.width / absoluteImageSize.width;
    final scaleY = canvasSize.height / absoluteImageSize.height;

    final pointPaint = Paint()..style = PaintingStyle.fill;
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    for (final pose in poses) {
      // 绘制关键点
      for (final landmark in pose.landmarks.values) {
        final x = landmark.x * scaleX;
        final y = landmark.y * scaleY;
        // 根据置信度改变颜色：高置信度绿色，低置信度红色
        final confidence = landmark.likelihood;
        pointPaint.color = confidence > 0.7 ? Colors.green : Colors.red;
        canvas.drawCircle(Offset(x, y), 6, pointPaint);
      }

      // 绘制连接线
      linePaint.color = Colors.blue;
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.rightShoulder,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.leftElbow,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftElbow,
        PoseLandmarkType.leftWrist,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.rightElbow,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.rightElbow,
        PoseLandmarkType.rightWrist,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftShoulder,
        PoseLandmarkType.leftHip,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.rightShoulder,
        PoseLandmarkType.rightHip,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftHip,
        PoseLandmarkType.rightHip,
        scaleX,
        scaleY,
        linePaint,
      );
      // 腿部连接（对跳跃检测最重要）
      linePaint.color = Colors.green; // 腿部用绿色强调
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftHip,
        PoseLandmarkType.leftKnee,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.leftKnee,
        PoseLandmarkType.leftAnkle,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.rightHip,
        PoseLandmarkType.rightKnee,
        scaleX,
        scaleY,
        linePaint,
      );
      _drawConnection(
        canvas,
        pose,
        PoseLandmarkType.rightKnee,
        PoseLandmarkType.rightAnkle,
        scaleX,
        scaleY,
        linePaint,
      );
    }
  }

  void _drawConnection(
    Canvas canvas,
    Pose pose,
    PoseLandmarkType type1,
    PoseLandmarkType type2,
    double scaleX,
    double scaleY,
    Paint paint,
  ) {
    final landmark1 = pose.landmarks[type1];
    final landmark2 = pose.landmarks[type2];
    if (landmark1 != null && landmark2 != null) {
      final x1 = landmark1.x * scaleX;
      final y1 = landmark1.y * scaleY;
      final x2 = landmark2.x * scaleX;
      final y2 = landmark2.y * scaleY;
      canvas.drawLine(Offset(x1, y1), Offset(x2, y2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PosePainter oldDelegate) {
    return oldDelegate.poses != poses;
  }
}
