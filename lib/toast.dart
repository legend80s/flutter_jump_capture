import 'package:flutter/material.dart';

enum MessageType { success, error, warning, info }

void showStyledSnackBar(
  BuildContext context,
  String message,
  MessageType type,
) {
  Color backgroundColor;
  IconData icon;
  String title;

  switch (type) {
    case MessageType.success:
      backgroundColor = Colors.green;
      icon = Icons.check_circle;
      title = '成功';
    case MessageType.error:
      backgroundColor = Colors.red;
      icon = Icons.error;
      title = '错误';
    case MessageType.warning:
      backgroundColor = Colors.orange;
      icon = Icons.warning;
      title = '警告';
    case MessageType.info:
      backgroundColor = Colors.blue;
      icon = Icons.info;
      title = '提示';
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      backgroundColor: backgroundColor,
      content: Row(
        children: [
          Icon(icon, color: Colors.white, size: 24),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                Text(message, style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
        ],
      ),
      duration: Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
