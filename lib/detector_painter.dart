import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

class ObjectDetectorPainter extends CustomPainter {
  final List<DetectedObject> detectedObjects;
  final Size imageSize;
  final Map<Offset,Color> gridPoints;

  ObjectDetectorPainter({required this.detectedObjects,
    required this.imageSize,
    required this.gridPoints});


  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final obj in detectedObjects) {
      final rect = obj.boundingBox;
      final scaledRect = Rect.fromLTRB(
        rect.left * scaleX,
        rect.top * scaleY,
        rect.right * scaleX,
        rect.bottom * scaleY,
      );

      final paint = Paint()
        ..color = Colors.red
        ..strokeWidth = 3.0
        ..style = PaintingStyle.stroke;

      canvas.drawRect(scaledRect, paint);

      final paintdot = Paint()
        ..color = Colors.purple
        ..strokeWidth = 3.0
        ..style = PaintingStyle.fill;
      final objectoffset = Offset((rect.left+rect.right)/ 2 * scaleX, (rect.top +rect.bottom) /2 * scaleY);
      canvas.drawCircle(objectoffset, 5, paintdot);


      // Debugging: print object center coordinates
      print('Object Center: $objectoffset');

      // Check if the object center is close to any grid point
      gridPoints.forEach((gridPoint, color) {
        final distance = (objectoffset - gridPoint).distance;
        // Debugging: print grid point coordinates and distance
        print('Grid Point: $gridPoint, Distance: $distance');

        if (distance < 20) {
          gridPoints[gridPoint] = Colors.green;
          // Debugging: print when a point is highlighted
          print('Highlighted Grid Point: $gridPoint');
        }
      });

      for (final label in obj.labels) {
        final textPainter = TextPainter(
          text: TextSpan(
            text: '${label.text} ${label.confidence.toStringAsFixed(2)}',
            style: TextStyle(
              color: Colors.red,
              fontSize: 16,
              backgroundColor: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        textPainter.layout();
        textPainter.paint(
          canvas,
          Offset(scaledRect.left, scaledRect.top - textPainter.height),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}

class PosePainter extends CustomPainter {
  final List<Pose> detectedPoses;
  final Size imageSize;

  PosePainter({required this.detectedPoses, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final pose in detectedPoses) {
      final landmarkPairs = [
        [PoseLandmarkType.leftShoulder, PoseLandmarkType.rightShoulder],
        [PoseLandmarkType.leftHip, PoseLandmarkType.rightHip],
        [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftElbow],
        [PoseLandmarkType.leftElbow, PoseLandmarkType.leftWrist],
        [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightElbow],
        [PoseLandmarkType.rightElbow, PoseLandmarkType.rightWrist],
        [PoseLandmarkType.leftHip, PoseLandmarkType.leftKnee],
        [PoseLandmarkType.leftKnee, PoseLandmarkType.leftAnkle],
        [PoseLandmarkType.rightHip, PoseLandmarkType.rightKnee],
        [PoseLandmarkType.rightKnee, PoseLandmarkType.rightAnkle],
        [PoseLandmarkType.leftShoulder, PoseLandmarkType.leftHip],
        [PoseLandmarkType.rightShoulder, PoseLandmarkType.rightHip],
      ];

      for (final pair in landmarkPairs) {
        final startLandmark = pose.landmarks[pair[0]];
        final endLandmark = pose.landmarks[pair[1]];

        if (startLandmark != null && endLandmark != null) {
          final startX = startLandmark.x * scaleX;
          final startY = startLandmark.y * scaleY;
          final endX = endLandmark.x * scaleX;
          final endY = endLandmark.y * scaleY;

          final paint = Paint()
            ..color = Colors.blue
            ..strokeWidth = 3.0;

          canvas.drawLine(Offset(startX, startY), Offset(endX, endY), paint);
        }
      }

      for (final landmark in pose.landmarks.values) {
        final scaledX = landmark.x * scaleX;
        final scaledY = landmark.y * scaleY;

        final paint = Paint()
          ..color = Colors.red
          ..strokeWidth = 3.0
          ..style = PaintingStyle.fill;

        canvas.drawCircle(Offset(scaledX, scaledY), 5, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}


class MarkerPainter extends CustomPainter {
  final List<Pose> detectedPoses;
  final Size imageSize;
  List<Offset> markerOffsets=[];

  MarkerPainter({required this.detectedPoses, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    markerOffsets.clear(); // 새로운 프레임을 그릴 때마다 초기화

    final scaleX = size.width / imageSize.width;
    final scaleY = size.height / imageSize.height;

    for (final pose in detectedPoses) {
        final leftFootPos =pose.landmarks[PoseLandmarkType.leftFootIndex];
        final rightFootPos =pose.landmarks[PoseLandmarkType.rightFootIndex];
        final nosePos =pose.landmarks[PoseLandmarkType.nose];

        final nosescaledX = (nosePos?.x ?? 0)* scaleX;
        final nosescaledY = (nosePos?.y ?? 0)* scaleY;
        final scaledX = (((leftFootPos?.x ?? 0) + (rightFootPos?.x ?? 0)) / 2)* scaleX;
        final scaledY = (((leftFootPos?.y ?? 0) + (rightFootPos?.y ?? 0)) / 2)* scaleY;

        final paint = Paint()
          ..color = Colors.purple
          ..strokeWidth = 3.0
          ..style = PaintingStyle.fill;

        final FootOffset = Offset(scaledX, scaledY);
        final noseOffset = Offset(nosescaledX, nosescaledY);

        markerOffsets.add(FootOffset);
        //markerOffsets.add(noseOffset);
        canvas.drawCircle(Offset(scaledX, scaledY), 10, paint);
        canvas.drawCircle(Offset(nosescaledX, nosescaledY), 10, paint);
      }
    }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true;
  }
}


class GridPainter extends CustomPainter {
  final Map<Offset,Color> gridPoints;
  GridPainter({required this.gridPoints});
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final paintdot = Paint()
      ..color = Colors.grey
      ..strokeWidth = 3.0
      ..style = PaintingStyle.fill;

    final double xStep = size.width / 3;
    final double yStep = size.height / 3;

    for (int i = 1; i < 3; i++) {
      canvas.drawLine(Offset(xStep * i, 0), Offset(xStep * i, size.height), paint);
      canvas.drawLine(Offset(0, yStep * i), Offset(size.width, yStep * i), paint);
    }

    gridPoints.forEach((offset, color) {
      final paintdot = Paint()
        ..color = color
        ..strokeWidth = 3.0
        ..style = PaintingStyle.fill;
      canvas.drawCircle(offset, 5, paintdot);
    });
  }


  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return false;
  }
}
