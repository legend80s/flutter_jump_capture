/// 跳跃检测结果
class JumpDetectionResult {
  final bool isNewJump;
  final String reason;
  final double? lastJumpHeight;
  final int timeDiff;

  JumpDetectionResult({
    required this.isNewJump,
    required this.reason,
    this.lastJumpHeight,
    required this.timeDiff,
  });
}

/// 跳跃检测器
class JumpDetector {
  /// 检测是否为新的跳跃
  ///
  /// [currentHeight] 当前检测到的跳跃高度
  /// [currentTime] 当前时间戳
  /// [lastJumpHeight] 上次记录的跳跃高度
  /// [lastJumpTime] 上次跳跃的时间戳
  /// [jumpThreshold] 跳跃检测阈值
  ///
  /// 返回 [JumpDetectionResult] 包含检测结果和详细信息
  static JumpDetectionResult detectNewJump({
    required double currentHeight,
    required Duration currentTime,
    required double jumpThreshold,
    double? lastJumpHeight,
    Duration? lastJumpTime,
  }) {
    // 首次跳跃
    if (lastJumpHeight == null || lastJumpTime == null) {
      return JumpDetectionResult(isNewJump: true, reason: '首次跳跃', timeDiff: 0);
    }

    final timeDiff = (currentTime - lastJumpTime).inMilliseconds;

    // 改进的跳跃检测逻辑：
    // 1. 时间间隔超过1000ms认为是新跳跃
    // 2. 或者当前跳跃高度比上次高至少20%（记录更高的跳跃）
    final bool isTimeBasedNewJump = timeDiff > 1000;
    final bool isHeightBasedNewJump = currentHeight > lastJumpHeight * 1.2;
    final bool isNewJump = isTimeBasedNewJump || isHeightBasedNewJump;

    String reason;
    if (isTimeBasedNewJump && isHeightBasedNewJump) {
      reason = '时间间隔和高度提升都满足条件';
    } else if (isTimeBasedNewJump) {
      reason = '时间间隔超过1000ms';
    } else if (isHeightBasedNewJump) {
      reason = '高度提升超过20%';
    } else {
      reason = '不满足新跳跃条件';
    }

    return JumpDetectionResult(
      isNewJump: isNewJump,
      reason: reason,
      lastJumpHeight: lastJumpHeight,
      timeDiff: timeDiff,
    );
  }

  /// 打印跳跃检测日志
  static void printJumpDetectionLog({
    required double currentHeight,
    required JumpDetectionResult result,
  }) {
    print(
      '[JC] 跳跃检测: 高度=${currentHeight.toStringAsFixed(3)}px, 时间差=${result.timeDiff}ms, 上次高度=${result.lastJumpHeight?.toStringAsFixed(3) ?? '0.000'}px',
    );
    print('[JC] 跳跃检测: ${result.reason}, 最终=${result.isNewJump}');

    if (!result.isNewJump) {
      print('[JC] 跳跃忽略: 不满足新跳跃条件');
    }
  }

  /// 打印跳跃记录日志
  static void printJumpRecordLog({
    required int jumpCount,
    required double height,
  }) {
    print('[JC] ✅ 跳跃记录: 跳跃次数=$jumpCount, 高度=${height.toStringAsFixed(3)}px');
  }
}
