import 'dart:async';
import 'dart:ui' as ui;
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getExternalStorageDirectory;
import 'package:image/image.dart' as img;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_thumbnail/video_thumbnail.dart' as thumbnail;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'jump_detector.dart' show JumpDetector;
import 'toast.dart' show showStyledSnackBar, MessageType;

enum AppMode { liveCamera, videoAnalysis }

enum Level {
  // debug(100),
  info(200),
  warning(300),
  error(400),
  fatal(500),
  success(600);

  final int value;
  // final String name;
  // final String emoji;

  const Level(this.value);
}

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

// 分析结果数据结构
class VideoJumpResult {
  final Duration timestamp; // 跳跃发生的时间点
  final double jumpHeight; // 估算的跳跃高度
  final File? snapshot; // 跳跃最高点的截图

  VideoJumpResult(this.timestamp, this.jumpHeight, this.snapshot);
}

/// 主页状态类，包含所有核心逻辑
class _JumpCaptureHomePageState extends State<JumpCaptureHomePage> {
  // --- 相机控制 ---
  CameraController? _controller;
  bool _isCameraInitialized = false;
  Size _imageSize = Size.zero;

  // --- 超时控制 ---
  Timer? _calibrationTimer; // 用于校准超时的计时器
  static const int calibrationTimeoutSeconds = 10; // 校准超时时间（秒）

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  // 模式控制
  AppMode _currentMode = AppMode.videoAnalysis; // 默认模式

  // --- 视频分析模式相关 ---
  String? _selectedVideoPath; // --- 视频分析 ---
  VideoPlayerController? _videoController;
  bool _isVideoInitialized = false;
  bool _isAnalyzingVideo = false;
  double _videoAnalysisProgress = 0.0;
  final List<VideoJumpResult> _jumpResults = []; // 存储分析结果
  final List<VideoJumpResult> _savedJumps = []; // 保存的跳跃结果（按高度排序）
  static const int maxSavedJumps = 3; // 最多保存3张最高跳跃的图片
  // ----------------------

  // --- 姿态检测 ---
  final PoseDetector _poseDetector = PoseDetector(
    options: PoseDetectorOptions(),
  );
  List<Pose> _poses = [];
  bool _isProcessing = false;

  CaptureState _captureState = CaptureState.idle; // 当前状态

  // --- 地面基线校准 ---
  static const int _calibrationFrameCount = 30; // 校准采样帧数
  final List<double> _ankleSamples = []; // 脚踝Y坐标采样列表
  double _groundBaseline = 0.0; // 计算得到的地面基线
  final double _jumpThreshold = 25.0; // 离地判断阈值（像素）

  // --- 帧缓存（用于回溯保存最佳帧）---
  static const int cacheFrameCount = 15; // 缓存最近N帧（约0.5秒@30fps）
  List<CameraImage> _frameCache = [];

  // --- UI反馈 ---
  String _statusText = '';
  Color _statusColor = Colors.blue;

  @override
  void initState() {
    super.initState();
    _requestPermissions();

    switch (_currentMode) {
      case AppMode.liveCamera:
        _initializeCamera();
        break;
      case AppMode.videoAnalysis:
        break;
    }
  }

  /// 请求必要的权限
  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      // Android 10+ 不需要请求存储权限，但 Android 9 及以下需要
      // 这里我们统一请求，确保兼容性
      await [Permission.storage, Permission.photos].request();
    }
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
      print('[JC] _isCameraInitialized true 点击下方按钮开始跳跃抓拍');
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
    final int total = _calibrationFrameCount;

    // 更新UI进度
    _updateStatus('校准中... ($collected/$total)', Colors.orange);

    if (collected >= total) {
      // 校准完成，计算基线
      _groundBaseline = _ankleSamples.reduce((a, b) => a + b) / total;
      _updateStatus('校准完成！准备起跳！', Colors.green);
      // 切换到检测状态，等待跳跃
      setState(() => _captureState = CaptureState.detecting);

      _cancelCalibrationTimer(); // 【新增】校准成功，取消超时计时
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
    _cancelCalibrationTimer(); // 【新增】确保计时器被清理

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

    // 【新增】启动校准超时计时器
    _startCalibrationTimer();
  }

  /// 启动校准超时计时器
  void _startCalibrationTimer() {
    _cancelCalibrationTimer(); // 先取消之前的计时器（如果有）
    _calibrationTimer = Timer(
      const Duration(seconds: calibrationTimeoutSeconds),
      _onCalibrationTimeout,
    );
  }

  /// 校准超时回调
  void _onCalibrationTimeout() {
    if (!mounted || _captureState != CaptureState.calibrating) return;
    if (_captureState == CaptureState.calibrating) {
      // 如果超时时仍在校准状态，说明检测失败
      String message;
      // 这里可以根据其他条件判断，比如是否根本没有图像流等
      // 目前我们简单判断为检测失败
      message = '无法检测到人体姿态，请确保：\n1. 全身在取景框内\n2. 光线充足\n3. 面向摄像头';
      _updateStatus(message, Colors.red);

      _resetCaptureState(); // 重置状态，允许用户再次点击
    }
  }

  /// 取消校准计时器
  void _cancelCalibrationTimer() {
    _calibrationTimer?.cancel();
    _calibrationTimer = null;
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
    _cancelCalibrationTimer(); // 清理计时器

    _videoController?.dispose();
    _controller?.stopImageStream();
    _poseDetector.close();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跳跃抓拍'),
        backgroundColor: _statusColor,
        actions: [
          PopupMenuButton<AppMode>(
            onSelected: (mode) {
              _switchMode(mode);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: AppMode.liveCamera,
                child: Row(
                  children: [
                    Icon(Icons.camera_alt, size: 20),
                    SizedBox(width: 8),
                    Text('实时抓拍模式'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: AppMode.videoAnalysis,
                child: Row(
                  children: [
                    Icon(Icons.video_library, size: 20),
                    SizedBox(width: 8),
                    Text('视频分析模式'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: null,
                child: Row(
                  children: [
                    Icon(Icons.photo_library, size: 20),
                    SizedBox(width: 8),
                    Text('查看保存的图片'),
                  ],
                ),
                onTap: () {
                  // 直接在这里调用，不依赖 onSelected
                  _showSavedImages();
                },
              ),
            ],
            icon: const Icon(Icons.menu),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildStatusBar(),
          Expanded(child: _buildMainContent()),
          _buildControlButtons(),
        ],
      ),
    );
  }

  Widget _buildStatusBar() {
    return _statusText.isEmpty
        ? Container()
        : Container(
            padding: const EdgeInsets.all(12),
            color: _statusColor.withAlpha((_statusColor.alpha * 0.1).toInt()),
            child: Row(
              children: [
                Icon(_getStatusIcon(), color: _statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _statusText,
                    style: TextStyle(color: _statusColor),
                  ),
                ),
                if (_groundBaseline > 0)
                  Text(
                    '基线: ${_groundBaseline.toStringAsFixed(1)}',
                    style: const TextStyle(color: Colors.grey),
                  ),
              ],
            ),
          );
  }

  Widget _buildMainContent() {
    switch (_currentMode) {
      case AppMode.liveCamera:
        return _buildCameraPreview();
      case AppMode.videoAnalysis:
        return _buildVideoAnalysisView();
    }
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

  Widget _buildVideoAnalysisView() {
    return Column(
      children: [
        // 视频预览
        if (_videoController != null && _isVideoInitialized)
          AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          )
        else
          _buildVideoPlaceholder(),

        // 分析进度
        if (_isAnalyzingVideo)
          LinearProgressIndicator(value: _videoAnalysisProgress),

        // 分析结果
        if (_jumpResults.isNotEmpty) Expanded(child: _buildJumpResultsList()),
      ],
    );
  }

  // Widget _buildVideoPlaceholder() {
  //   return Center(
  //     child: Column(
  //       mainAxisAlignment: MainAxisAlignment.center,
  //       children: [
  //         Icon(Icons.video_library, size: 80, color: Colors.grey[400]),
  //         const SizedBox(height: 20),
  //         const Text('尚未选择视频', style: TextStyle(color: Colors.grey)),
  //         const SizedBox(height: 10),
  //         FilledButton.icon(
  //           onPressed: _pickVideo,
  //           icon: const Icon(Icons.upload_file),
  //           label: const Text('选择视频文件'),
  //         ),
  //       ],
  //     ),
  //   );
  // }

  Widget _buildControlButtons() {
    switch (_currentMode) {
      case AppMode.liveCamera:
        return _buildCameraControls();
      case AppMode.videoAnalysis:
        return _buildVideoControls();
    }
  }

  Widget _buildCameraControls() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: SizedBox(
        width: double.infinity,
        height: 60,
        child: FilledButton.icon(
          onPressed: _isButtonEnabled() ? _onCaptureButtonPressed : null,
          icon: Icon(_getButtonIcon()),
          label: Text(_getButtonText(), style: const TextStyle(fontSize: 20)),
        ),
      ),
    );
  }

  Widget _buildVideoControls() {
    if (_videoController == null || !_isVideoInitialized) {
      return const SizedBox();
    }

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        children: [
          // 播放控制
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: Icon(
                  _videoController!.value.isPlaying
                      ? Icons.pause
                      : Icons.play_arrow,
                ),
                onPressed: () {
                  _videoController!.value.isPlaying
                      ? _videoController!.pause()
                      : _videoController!.play();
                },
              ),
              const SizedBox(width: 20),

              // 分析和选择视频按钮
              if (!_isAnalyzingVideo)
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _analyzeVideo,
                      icon: const Icon(Icons.analytics),
                      label: const Text('分析视频'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _pickVideo,
                      icon: const Icon(Icons.video_file),
                      label: const Text('选择其他视频'),
                    ),
                  ],
                )
              else
                OutlinedButton(
                  onPressed: null,
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text('分析中 ${(_videoAnalysisProgress * 100).toInt()}%'),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 切换应用模式（实时相机 ↔ 视频分析）
  void _switchMode(AppMode newMode) {
    print('[JC] 尝试切换模式到: $_currentMode → $newMode');

    // 如果正在分析中，不允许切换模式
    if (_isAnalyzingVideo ||
        (_captureState != CaptureState.idle &&
            _captureState != CaptureState.success)) {
      _updateStatus('请先完成当前操作', Colors.orange);
      return;
    }

    if (_currentMode == newMode) {
      // 如果已经是视频分析模式，重置状态让用户可以选择其他视频
      if (newMode == AppMode.videoAnalysis) {
        print('[JC] 重置视频分析模式状态');
        setState(() {
          // 清理当前模式资源
          _cleanupCurrentMode();

          // 重新初始化视频分析模式
          _initializeNewMode(newMode);
        });
      }
      return;
    }

    setState(() {
      // 清理当前模式资源
      _cleanupCurrentMode();

      // 切换到新模式
      _currentMode = newMode;
      print('[JC] ✅ 成功切换模式到: $_currentMode → $newMode');

      // 初始化新模式
      _initializeNewMode(newMode);
    });
  }

  /// 清理当前模式的资源
  void _cleanupCurrentMode() {
    switch (_currentMode) {
      case AppMode.liveCamera:
        // 停止相机流
        _controller?.stopImageStream();
        // 重置抓拍状态
        _resetCaptureState();
        break;
      case AppMode.videoAnalysis:
        // 停止视频播放并释放控制器
        _videoController?.pause();
        _videoController?.dispose();
        _videoController = null;
        // 重置视频初始化状态
        _isVideoInitialized = false;
        // 清理视频分析状态
        _isAnalyzingVideo = false;
        _videoAnalysisProgress = 0.0;
        _jumpResults.clear();
        break;
    }
  }

  /// 初始化新模式的资源
  void _initializeNewMode(AppMode mode) {
    switch (mode) {
      case AppMode.liveCamera:
        // 重新启动相机流
        if (_controller != null && _isCameraInitialized) {
          _startImageStream();
        }
        print('[JC] 已切换到实时相机模式');
        break;
      case AppMode.videoAnalysis:
        // 视频模式初始化
        print('[JC] 已切换到视频分析模式，请选择视频文件');
        break;
    }
  }

  Widget _buildJumpResultsList() {
    return ListView.builder(
      itemCount: _jumpResults.length,
      itemBuilder: (context, index) {
        final result = _jumpResults[index];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ListTile(
            leading: result.snapshot != null && result.snapshot!.existsSync()
                ? Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      image: DecorationImage(
                        image: FileImage(result.snapshot!),
                        fit: BoxFit.cover,
                      ),
                    ),
                  )
                : Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.image_not_supported,
                      color: Colors.grey,
                    ),
                  ),
            title: Text('跳跃 ${index + 1}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('时间: ${_formatDuration(result.timestamp)}'),
                Text('高度: ${result.jumpHeight.toStringAsFixed(1)}像素'),
                if (result.snapshot != null && result.snapshot!.existsSync())
                  Text(
                    '已保存到相册',
                    style: TextStyle(fontSize: 12, color: Colors.green),
                  ),
              ],
            ),
            trailing: const Icon(Icons.play_arrow),
            onTap: () => _seekToJump(result.timestamp),
          ),
        );
      },
    );
  }

  /// 将Duration格式化为易读的时间字符串 (MM:SS.ms)
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final milliseconds = duration.inMilliseconds
        .remainder(1000)
        .toString()
        .padLeft(3, '0');

    return '$minutes:${seconds}.$milliseconds';
  }

  /// 跳转到视频的指定跳跃时间点
  Future<void> _seekToJump(Duration timestamp) async {
    if (_videoController == null || !_isVideoInitialized) return;

    try {
      await _videoController!.seekTo(timestamp);

      // 可选：如果是视频分析模式，自动播放几秒
      if (_currentMode == AppMode.videoAnalysis) {
        _videoController!.play();
        // 3秒后暂停，方便查看跳跃瞬间
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted && _videoController != null) {
            _videoController!.pause();
          }
        });
      }

      _updateStatus('已跳转到跳跃时间点: ${_formatDuration(timestamp)}', Colors.blue);
    } catch (e) {
      _updateStatus('跳转失败: $e', Colors.red);
    }
  }

  /// 构建视频分析模式的占位界面（当没有选择视频时显示）
  Widget _buildVideoPlaceholder() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 大图标
          const SizedBox(height: 40),
          Icon(Icons.video_library, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 20),

          // 提示文本
          Text(
            '尚未选择视频',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 10),

          Text(
            '请点击下方按钮选择要分析的视频文件',
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 100),

          // 选择视频按钮（直接放在占位图中也很方便）
          FilledButton.icon(
            onPressed: _pickVideo, // 确保你已经实现了_pickVideo方法
            icon: const Icon(Icons.upload_file),
            label: const Text('选择视频文件'),
          ),
        ],
      ),
    );
  }

  /// 选择视频文件
  Future<void> _pickVideo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    //  I/flutter (24819): [JC] _pickVideo result: FilePickerResult(files: [PlatformFile(path /data/user/0/com.example.jump_capture/cache/file_picker/1767172255419/一位女性面向镜头，原地起跳整
    // 个过程，稍稍屈膝，双脚离地，在空中双手双脚张开，然后落下，整个过程大笑，跳跃姿势自然。_.mp4, name: 一位女性面向镜头，原地起跳整个过程，稍稍屈膝，双脚离地，在空中双手双脚张开，然后落下
    // ，整个过程大笑，跳跃姿势自然。_.mp4, bytes: null, readStream: null, size: 3196709)])
    print('[JC] _pickVideo result: $result');

    if (result != null && result.files.isNotEmpty) {
      final filePath = result.files.single.path!;
      // I/flutter (24819): [JC] _pickVideo filePath: /data/user/0/com.example.jump_capture/cache/file_picker/1767172255419/一位女性面向镜头，原地起跳整个过程，稍稍屈膝，双脚离地，在空中双手双
      // 脚张开，然后落下，整个过程大笑，跳跃姿势自然。_.mp4
      print('[JC] _pickVideo filePath: [$filePath]');

      _selectedVideoPath = filePath; // 保存路径

      _loadVideo(File(filePath));
    }
  }

  /// 加载视频文件
  Future<void> _loadVideo(File videoFile) async {
    _videoController?.dispose();
    _videoController = VideoPlayerController.file(videoFile);

    try {
      await _videoController!.initialize();
      setState(() => _isVideoInitialized = true);

      if (mounted) {
        showStyledSnackBar(context, '视频加载成功！点击「分析视频」开始', MessageType.success);
      }
    } catch (e) {
      _updateStatus('视频加载失败: $e', Colors.red);
    }
  }

  // begin

  /// 核心：分析视频中的跳跃动作（基于video_thumbnail优化版）
  Future<void> _analyzeVideo() async {
    print('[JC] _analyzeVideo');

    // ========== 1. 前置检查 ==========
    if (_videoController == null || _isAnalyzingVideo || !_isVideoInitialized) {
      _updateStatus('视频未就绪，无法分析', Colors.red);
      return;
    }

    // 获取视频文件路径
    final String? videoPath = _getVideoPath();
    if (videoPath == null || !File(videoPath).existsSync()) {
      _updateStatus('无法获取视频文件', Colors.red);
      return;
    }

    // ========== 2. 初始化分析状态 ==========
    setState(() {
      _isAnalyzingVideo = true;
      _jumpResults.clear();
      _videoAnalysisProgress = 0.0;
    });

    // 跳跃检测状态
    bool isCalibrated = false;
    double groundBaseline = 0.0;
    List<double> ankleSamples = [];

    // 分析参数配置
    final videoDuration = _videoController!.value.duration;
    final int totalSeconds = videoDuration.inSeconds;

    if (totalSeconds < 2) {
      _updateStatus('视频太短（至少需要2秒）', Colors.red);
      setState(() => _isAnalyzingVideo = false);
      return;
    }

    // 优化：每秒分析3帧（平衡性能与准确性）
    const int framesPerSecond = 3;
    final int totalFrames = totalSeconds * framesPerSecond;
    int processedFrames = 0;
    int jumpCount = 0;

    // 分析开始时间戳（用于计算耗时）
    final analysisStartTime = DateTime.now();

    _updateStatus('开始分析视频... 0%', Colors.orange);

    // ========== 3. 逐帧分析主循环 ==========
    try {
      for (int second = 0; second < totalSeconds; second++) {
        // 检查是否被取消或页面已卸载
        if (!mounted || !_isAnalyzingVideo) {
          _updateStatus('分析已中断', Colors.orange);
          return;
        }

        for (
          int frameInSecond = 0;
          frameInSecond < framesPerSecond;
          frameInSecond++
        ) {
          // 计算当前帧的时间位置
          final Duration position = Duration(
            seconds: second,
            milliseconds: (frameInSecond * (1000 / framesPerSecond)).toInt(),
          );

          // 3.1 提取视频帧
          final ui.Image? videoFrame = await _getVideoFrameAtPosition(
            videoPath,
            position,
            quality: 60, // 60%质量足够姿态检测
            maxWidth: 480, // 限制宽度提高速度
          );

          if (videoFrame == null) {
            // 帧提取失败，跳过但继续处理
            processedFrames++;
            continue;
          }

          // 3.2 转换为InputImage
          final InputImage? inputImage = await _convertVideoFrameToInputImage(
            videoFrame,
          );
          videoFrame.dispose(); // 及时释放资源

          if (inputImage == null) {
            processedFrames++;
            continue;
          }

          // 3.3 姿态检测
          try {
            final List<Pose> poses = await _poseDetector.processImage(
              inputImage,
            );

            if (poses.isNotEmpty) {
              final Pose pose = poses.first;
              final PoseLandmark? leftAnkle =
                  pose.landmarks[PoseLandmarkType.leftAnkle];
              final PoseLandmark? rightAnkle =
                  pose.landmarks[PoseLandmarkType.rightAnkle];

              if (leftAnkle != null && rightAnkle != null) {
                final double currentAnkleY = (leftAnkle.y + rightAnkle.y) / 2.0;
                print(
                  '[JC] 帧 $processedFrames: 左脚踝=${leftAnkle.y.toStringAsFixed(3)}, 右脚踝=${rightAnkle.y.toStringAsFixed(3)}, 平均=${currentAnkleY.toStringAsFixed(3)}',
                );

                // 3.4 跳跃检测逻辑
                if (!isCalibrated) {
                  // 校准阶段：前3秒用于校准（每秒3帧，共9帧）
                  if (second < 3) {
                    ankleSamples.add(currentAnkleY);
                    print('[JC] 校准中: 收集样本 ${ankleSamples.length}/8');

                    // 收集足够样本后计算基线
                    if (ankleSamples.length >= 8) {
                      // 约2.7秒的数据
                      groundBaseline =
                          ankleSamples.reduce((a, b) => a + b) /
                          ankleSamples.length;
                      isCalibrated = true;
                      print(
                        '[JC] 校准完成！基线: ${groundBaseline.toStringAsFixed(3)}',
                      );
                      _updateStatus(
                        '校准完成！基线: ${groundBaseline.toStringAsFixed(1)}',
                        Colors.green,
                      );
                    }
                  }
                } else {
                  // 检测阶段：判断是否跳跃
                  final double heightDiff = _calculateJumpHeight(
                    groundBaseline,
                    currentAnkleY,
                  );
                  print(
                    '[JC] 检测中: 基线=${groundBaseline.toStringAsFixed(3)}, 当前=${currentAnkleY.toStringAsFixed(3)}, 高度差=${heightDiff.toStringAsFixed(3)}, 阈值=$_jumpThreshold',
                  );

                  // 跳跃判断条件：脚踝显著高于基线，且保持一定连续性
                  if (heightDiff > _jumpThreshold &&
                      // 限制最大跳跃高度，避免误判（基于阈值的合理倍数）
                      heightDiff < _jumpThreshold * 15) {
                    // 使用跳跃检测器进行智能检测
                    final lastResult = _jumpResults.isEmpty
                        ? null
                        : _jumpResults.last;
                    final detectionResult = JumpDetector.detectNewJump(
                      currentHeight: heightDiff,
                      currentTime: position,
                      jumpThreshold: _jumpThreshold,
                      lastJumpHeight: lastResult?.jumpHeight,
                      lastJumpTime: lastResult?.timestamp,
                    );

                    // 打印检测日志
                    JumpDetector.printJumpDetectionLog(
                      currentHeight: heightDiff,
                      result: detectionResult,
                    );

                    if (detectionResult.isNewJump) {
                      jumpCount++;
                      JumpDetector.printJumpRecordLog(
                        jumpCount: jumpCount,
                        height: heightDiff,
                      );

                      // 计算跳跃高度（像素单位）
                      final double jumpHeight = heightDiff;

                      // 创建跳跃结果（不立即保存图片）
                      final result = VideoJumpResult(
                        position,
                        jumpHeight,
                        null, // 先不保存图片
                      );

                      _jumpResults.add(result);

                      // 实时反馈
                      if (mounted) {
                        _updateStatus(
                          '发现第$jumpCount次跳跃！高度: ${jumpHeight.toStringAsFixed(1)}像素',
                          Colors.green,
                        );
                      }
                    }
                  }
                }
              }
            }
          } catch (e, stackTrace) {
            print('姿态检测失败（帧 $processedFrames）: $e');
            // 单个帧失败不影响整体分析
            print('详细堆栈:');
            print(stackTrace.toString());
          }

          // 3.5 更新进度
          processedFrames++;
          final double progress = processedFrames / totalFrames;

          if (mounted) {
            setState(() {
              _videoAnalysisProgress = progress;
            });

            // 每处理10%或发现跳跃时更新状态
            if (processedFrames % (totalFrames ~/ 10) == 0 ||
                jumpCount > _jumpResults.length) {
              _updateStatus(
                '分析中... ${(progress * 100).toInt()}% '
                '已发现 $jumpCount 次跳跃',
                Colors.orange,
              );
            }
          }
        }

        // 每分析3秒，短暂暂停避免过热/卡顿
        if (second % 3 == 0 && second > 0) {
          await Future.delayed(const Duration(milliseconds: 30));
        }
      }

      // ========== 4. 分析完成 ==========
      final analysisDuration = DateTime.now().difference(analysisStartTime);

      if (mounted) {
        setState(() => _isAnalyzingVideo = false);

        if (_jumpResults.isEmpty) {
          _updateStatus(
            '分析完成（耗时 ${analysisDuration.inSeconds} 秒）\n'
            '未检测到明显的跳跃动作\n'
            '建议：确保视频中包含完整的跳跃过程',
            Colors.blue,
          );
        } else {
          // 计算统计数据
          final double avgHeight =
              _jumpResults.map((r) => r.jumpHeight).reduce((a, b) => a + b) /
              _jumpResults.length;

          final double maxHeight = _jumpResults
              .map((r) => r.jumpHeight)
              .reduce((a, b) => a > b ? a : b);

          _updateStatus(
            '✅ 分析完成（耗时 ${analysisDuration.inSeconds}秒）\n'
            '共发现 ${_jumpResults.length} 次跳跃\n'
            '平均高度: ${avgHeight.toStringAsFixed(1)}像素 | '
            '最高: ${maxHeight.toStringAsFixed(1)}像素',
            Colors.green,
          );

          // 保存跳跃高度最高的前3张照片
          await _saveTopJumpSnapshots(videoPath);

          // 自动跳转到最高跳跃
          if (_jumpResults.isNotEmpty) {
            // 找到高度最高的跳跃
            final highestJump = _jumpResults.reduce(
              (a, b) => a.jumpHeight > b.jumpHeight ? a : b,
            );
            print(
              '[JC] 自动跳转到最高跳跃: 高度=${highestJump.jumpHeight.toStringAsFixed(3)}px',
            );
            await _seekToJump(highestJump.timestamp);
          }
        }
      }
    } catch (e) {
      // ========== 5. 错误处理 ==========
      print('视频分析严重错误: $e');

      if (mounted) {
        setState(() => _isAnalyzingVideo = false);
        _updateStatus(
          '分析失败: ${e.toString().split('\n').first}\n'
          '请确保视频格式支持或尝试更短的视频',
          Colors.red,
        );
      }
    }
  }

  /// 获取视频文件路径
  String? _getVideoPath() {
    // 方法1：直接返回保存的路径
    if (_selectedVideoPath != null && File(_selectedVideoPath!).existsSync()) {
      return _selectedVideoPath;
    }

    if (_videoController == null) return null;

    final String dataSource = _videoController!.dataSource;

    print('[jc] dataSource = $dataSource');

    String? videoPath;

    // 判断数据源类型
    if (dataSource.startsWith('file://')) {
      // 文件路径，去除'file://'前缀
      videoPath = dataSource.substring(7);
    } else if (dataSource.startsWith('/')) {
      // 绝对路径
      videoPath = dataSource;
    } else if (!dataSource.contains('://')) {
      // 可能是相对路径
      videoPath = dataSource;
    } else {
      // 其他情况（如网络视频：http://, https://）
      videoPath = null;
    }
    print('[jc] videoPath = $videoPath');

    return videoPath;
  }

  /// 使用video_thumbnail提取视频帧
  Future<ui.Image?> _getVideoFrameAtPosition(
    String videoPath,
    Duration position, {
    int quality = 75,
    int maxWidth = 640,
  }) async {
    try {
      final Uint8List? uint8List = await thumbnail.VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: thumbnail.ImageFormat.JPEG,
        timeMs: position.inMilliseconds,
        quality: quality,
        maxWidth: maxWidth,
      );

      if (uint8List == null || uint8List.isEmpty) {
        return null;
      }

      final ui.Codec codec = await ui.instantiateImageCodec(uint8List);
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      return frameInfo.image;
    } catch (e) {
      print('提取视频帧失败 [${position.inMilliseconds}ms]: $e');
      return null;
    }
  }

  /// 将ui.Image转换为InputImage
  Future<InputImage?> _convertVideoFrameToInputImage(
    ui.Image videoFrame,
  ) async {
    try {
      final int width = videoFrame.width;
      final int height = videoFrame.height;

      final ByteData? byteData = await videoFrame.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );

      if (byteData == null) return null;

      final Uint8List rgbaBytes = byteData.buffer.asUint8List();

      if (Platform.isAndroid) {
        final Uint8List nv21Bytes = _convertRGBAToNV21(
          rgbaBytes,
          width,
          height,
        );

        return InputImage.fromBytes(
          bytes: nv21Bytes,
          metadata: InputImageMetadata(
            size: Size(width.toDouble(), height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.nv21,
            bytesPerRow: width,
          ),
        );
      } else {
        final Uint8List bgraBytes = _convertRGBAToBGRA(rgbaBytes);

        return InputImage.fromBytes(
          bytes: bgraBytes,
          metadata: InputImageMetadata(
            size: Size(width.toDouble(), height.toDouble()),
            rotation: InputImageRotation.rotation0deg,
            format: InputImageFormat.bgra8888,
            bytesPerRow: width * 4,
          ),
        );
      }
    } catch (e) {
      print('[JC] 图像转换失败: $e');
      return null;
    }
  }

  Uint8List _convertRGBAToBGRA(Uint8List rgbaBytes) {
    final Uint8List bgraBytes = Uint8List(rgbaBytes.length);
    for (int i = 0; i < rgbaBytes.length; i += 4) {
      bgraBytes[i] = rgbaBytes[i + 2];
      bgraBytes[i + 1] = rgbaBytes[i + 1];
      bgraBytes[i + 2] = rgbaBytes[i];
      bgraBytes[i + 3] = rgbaBytes[i + 3];
    }
    return bgraBytes;
  }

  Uint8List _convertRGBAToNV21(Uint8List rgbaBytes, int width, int height) {
    final int yuvSize = width * height + (width * height ~/ 2);
    final Uint8List nv21Bytes = Uint8List(yuvSize);

    int yIndex = 0;
    int uvIndex = width * height;

    for (int j = 0; j < height; j++) {
      for (int i = 0; i < width; i++) {
        final int index = (j * width + i) * 4;
        final int r = rgbaBytes[index];
        final int g = rgbaBytes[index + 1];
        final int b = rgbaBytes[index + 2];

        final int y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
        nv21Bytes[yIndex++] = y.clamp(0, 255);
      }
    }

    for (int j = 0; j < height ~/ 2; j++) {
      for (int i = 0; i < width ~/ 2; i++) {
        final int index = (j * 2 * width + i * 2) * 4;
        final int r = rgbaBytes[index];
        final int g = rgbaBytes[index + 1];
        final int b = rgbaBytes[index + 2];

        final int u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
        final int v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;

        nv21Bytes[uvIndex++] = v;
        nv21Bytes[uvIndex++] = u;
      }
    }

    return nv21Bytes;
  }

  /// 显示图片预览对话框
  void _showImagePreview(String imagePath) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('跳跃快照', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                Container(
                  width: 300,
                  height: 400,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    image: DecorationImage(
                      image: FileImage(File(imagePath)),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '保存路径:',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                Text(
                  imagePath,
                  style: TextStyle(fontSize: 10),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        // 这里可以添加分享功能
                        Navigator.of(context).pop();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('分享功能开发中...')),
                        );
                      },
                      icon: const Icon(Icons.share, size: 16),
                      label: const Text('分享'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<File?> _captureFrameSnapshot(
    String videoPath,
    Duration timestamp,
    double jumpHeight,
    int rank, // 跳跃排名（1, 2, 3）
  ) async {
    try {
      // 为跳跃时刻生成稍高质量的缩略图
      final Uint8List? uint8List = await thumbnail.VideoThumbnail.thumbnailData(
        video: videoPath,
        imageFormat: thumbnail.ImageFormat.PNG,
        timeMs: timestamp.inMilliseconds,
        quality: 90,
        maxWidth: 320,
      );

      if (uint8List == null) return null;

      final Directory appDir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();

      // 在 Android 上，使用 Pictures 目录
      Directory picturesDir;
      if (Platform.isAndroid) {
        picturesDir = Directory('/storage/emulated/0/Pictures/JumpCapture');
      } else {
        picturesDir = Directory('${appDir.path}/JumpCapture');
      }

      // 生成新的文件名格式：jump_序号_年月日-时分秒毫秒_高度px.png
      final now = DateTime.now();
      final String timestampStr =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
          '${now.hour.toString().padLeft(2, '0')}h${now.minute.toString().padLeft(2, '0')}m'
          '${now.second.toString().padLeft(2, '0')}s${now.millisecond.toString().padLeft(3, '0')}ms';

      final String filename =
          'jump_${rank}_${timestampStr}_${jumpHeight.toStringAsFixed(0)}px.png';
      final File file = File('${picturesDir.path}/$filename');

      await picturesDir.create(recursive: true);
      await file.writeAsBytes(uint8List);

      print('✅ 跳跃快照已保存: ${file.path}');
      return file;
    } catch (e) {
      print('保存快照失败: $e');
      return null;
    }
  }

  /// 显示所有保存的图片
  void _showSavedImages() async {
    final List<File> images = await _getSavedJumpImages();

    if (!mounted) return;

    if (images.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('暂无保存的图片')));
      return;
    }

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return Dialog(
          child: Container(
            width: double.maxFinite,
            height: 400,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  '保存的跳跃图片 (${images.length}张)',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 0.75,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                    itemCount: images.length,
                    itemBuilder: (context, index) {
                      final file = images[index];
                      return GestureDetector(
                        onTap: () => _showImagePreview(file.path),
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[300]!),
                          ),
                          child: Column(
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(8),
                                  ),
                                  child: Image.file(
                                    file,
                                    fit: BoxFit.cover,
                                    width: double.infinity,
                                  ),
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.all(4),
                                child: Text(
                                  _formatFileName(file.path),
                                  style: const TextStyle(fontSize: 10),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭'),
                    ),
                    FilledButton.icon(
                      onPressed: () {
                        _openSaveFolder();
                        Navigator.of(context).pop();
                      },
                      label: const Text('前往相册'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 格式化文件名显示
  String _formatFileName(String path) {
    final fileName = path.split('/').last;
    // 从 jump_1_20260120-17h36m4s330ms_39px.png 中提取信息
    final match = RegExp(
      r'jump_(\d+)_(\d{8}-\d{2}h\d{2}m\d{2}s\d{3}ms)_(\d+)px\.png',
    ).firstMatch(fileName);
    if (match != null) {
      final rank = match.group(1);
      final height = match.group(3);
      return '第${rank}高 (${height}px)';
    }
    return fileName;
  }

  Future<List<File>> _getSavedJumpImages() async {
    try {
      final Directory appDir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();

      Directory picturesDir;
      if (Platform.isAndroid) {
        picturesDir = Directory('/storage/emulated/0/Pictures/JumpCapture');
      } else {
        picturesDir = Directory('${appDir.path}/JumpCapture');
      }

      if (await picturesDir.exists()) {
        final List<FileSystemEntity> files = await picturesDir.list().toList();
        final List<File> imageFiles =
            files
                .whereType<File>()
                .where((file) => file.path.endsWith('.png'))
                .toList()
              ..sort(
                (a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()),
              );
        return imageFiles;
      }
      return [];
    } catch (e) {
      print('获取保存的图片失败: $e');
      return [];
    }
  }

  /// 保存跳跃高度最高的前3张照片
  Future<void> _saveTopJumpSnapshots(String videoPath) async {
    try {
      // 按跳跃高度降序排序
      final sortedJumps = List<VideoJumpResult>.from(_jumpResults)
        ..sort((a, b) => b.jumpHeight.compareTo(a.jumpHeight));

      // 只保存前3张
      final topJumps = sortedJumps.take(maxSavedJumps).toList();

      for (int i = 0; i < topJumps.length; i++) {
        final jump = topJumps[i];
        final rank = i + 1;

        // 生成新的文件名
        final snapshotFile = await _captureFrameSnapshot(
          videoPath,
          jump.timestamp,
          jump.jumpHeight,
          rank,
        );

        if (snapshotFile != null) {
          // 更新结果中的文件引用
          final index = _jumpResults.indexOf(jump);
          if (index != -1) {
            _jumpResults[index] = VideoJumpResult(
              jump.timestamp,
              jump.jumpHeight,
              snapshotFile,
            );
          }

          // 添加到保存列表
          _savedJumps.add(
            VideoJumpResult(jump.timestamp, jump.jumpHeight, snapshotFile),
          );

          print('✅ 保存第${rank}高跳跃照片: ${snapshotFile.path}');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存最高 ${topJumps.length} 张跳跃照片'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      print('保存最高跳跃照片失败: $e');
    }
  }

  /// 获取保存目录
  Future<Directory?> _getSaveDirectory() async {
    if (Platform.isAndroid) {
      return Directory('/storage/emulated/0/Pictures/JumpCapture');
    } else {
      final appDir =
          await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      return Directory('${appDir.path}/JumpCapture');
    }
  }

  /// 打开保存文件夹
  Future<void> _openSaveFolder() async {
    try {
      final directory = await _getSaveDirectory();
      if (directory == null || !await directory.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('保存文件夹不存在')));
        }
        return;
      }

      if (Platform.isAndroid) {
        // Android 使用 Intent
        openFolderForAndroid(directory);
      } else {
        // iOS 使用 URL Launcher
        final uri = Uri.directory(directory.path);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri);
        } else {
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('无法打开文件夹')));
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开文件夹失败: $e')));
      }
    }
  }

  Future<void> openFolderForAndroid(Directory directory) async {
    // 显示提示信息，让用户到相册查看
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请到「相册-更多相册-其他相册」查看'),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// 计算跳跃高度（当前为简化版，未来可添加相机标定等逻辑）
  double _calculateJumpHeight(double baseline, double currentAnkleY) {
    // 当前：简单的像素差值
    final double pixelHeight = (baseline - currentAnkleY).abs();

    // 未来可以在这里添加：
    // 1. 根据相机参数转换为真实高度（厘米/米）
    // 2. 考虑透视校正
    // 3. 根据人物身高进行归一化

    return pixelHeight;
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
