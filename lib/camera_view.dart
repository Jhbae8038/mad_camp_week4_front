import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'detector_painter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';

class DetectionView extends StatefulWidget {
  final List<CameraDescription> cameras;
  const DetectionView({Key? key, required this.cameras}) : super(key: key);

  @override
  State<DetectionView> createState() => _DetectionViewState();
}

enum DetectionModes { object, pose }

class _DetectionViewState extends State<DetectionView> {
  late CameraController _controller;
  late ObjectDetector _objectDetector;
  late PoseDetector _poseDetector;
  bool _isDetecting = false;
  DetectionModes _detectionMode = DetectionModes.object;
  List<DetectedObject> _detectedObjects = [];
  List<Pose> _detectedPoses = [];
  bool _isCapturing = false;
  Offset headTarget = Offset.zero;
  Offset feetTarget = Offset.zero;
  MarkerPainter? _markerPainter;
  String _feedbackMessage = "";

  final _orientations = {
    DeviceOrientation.portraitUp: 0,
    DeviceOrientation.landscapeLeft: 90,
    DeviceOrientation.portraitDown: 180,
    DeviceOrientation.landscapeRight: 270,
  };

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _initializeDetectors();
  }

  @override
  void dispose() {
    _disposeResources();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    final camera = widget.cameras.first;
    _controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await _controller.initialize();
      if (!mounted) return;
      setState(() {});
      _controller.startImageStream(_processCameraImage);
    } catch (e) {
      _showError('Error initializing camera: $e');
    }
  }

  Future<void> _disposeResources() async {
    await _disposeCamera();
    await _objectDetector.close();
    await _poseDetector.close();
  }

  Future<void> _disposeCamera() async {
    try {
      await _controller.stopImageStream();
    } catch (e) {
      _showError("Failed to stop image stream: $e");
    }
    _controller.dispose();
  }

  void _initializeDetectors() {
    final objectOptions = ObjectDetectorOptions(
      mode: DetectionMode.stream,
      classifyObjects: true,
      multipleObjects: true,
    );
    _objectDetector = ObjectDetector(options: objectOptions);

    final poseOptions = PoseDetectorOptions();
    _poseDetector = PoseDetector(options: poseOptions);
  }

  Uint8List _convertYUV420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final int ySize = width * height;
    final int uvSize = width * height ~/ 2;

    final Uint8List nv21Bytes = Uint8List(ySize + uvSize);
    final Uint8List yBytes = image.planes[0].bytes;
    final Uint8List uBytes = image.planes[1].bytes;
    final Uint8List vBytes = image.planes[2].bytes;

    nv21Bytes.setRange(0, ySize, yBytes);

    for (int i = 0; i < uvSize; i += 2) {
      nv21Bytes[ySize + i] = vBytes[i ~/ 2];
      nv21Bytes[ySize + i + 1] = uBytes[i ~/ 2];
    }

    return nv21Bytes;
  }

  InputImage? _inputImageFromCameraImage(CameraImage image) {
    final camera = widget.cameras.first;
    final sensorOrientation = camera.sensorOrientation;
    InputImageRotation? rotation;

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_controller.value.deviceOrientation];

      if (rotationCompensation == null) {
        _showError("Rotation compensation is null");
        return null;
      }

      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
    }

    if (rotation == null) {
      _showError("Rotation is null");
      return null;
    }

    final nv21Bytes = _convertYUV420ToNV21(image);
    final format = InputImageFormat.nv21;

    return InputImage.fromBytes(
      bytes: nv21Bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: image.planes[0].bytesPerRow,
      ),
    );
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isDetecting) return;
    _isDetecting = true;

    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      _isDetecting = false;
      return;
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final imageSize = Size(
      _controller.value.previewSize!.height,
      _controller.value.previewSize!.width,
    );
    final scaleX = screenWidth / imageSize.width;
    final scaleY = screenHeight / imageSize.height;

    try {
      if (_detectionMode == DetectionModes.object) {
        final List<DetectedObject> objects = await _objectDetector.processImage(inputImage);
        setState(() {
          _detectedObjects = objects;
          _detectedPoses = [];
        });
      } else if (_detectionMode == DetectionModes.pose) {
        final List<Pose> poses = await _poseDetector.processImage(inputImage);
        //_updateFeedback(poses);

        setState(() {
          _detectedPoses = poses;
          _detectedObjects = [];
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _performOperationOnMarkerCoordinates();
        });
      }
    } catch (e) {
      _showError('Error detecting objects: $e');
    } finally {
      _isDetecting = false;
    }
  }
/*
  void _updateFeedback(List<Pose> poses) {
    if (poses.isEmpty) {
      setState(() {
        _feedbackMessage = "No poses detected";
      });
      return;
    }

    final Pose pose = poses.first;
    final PoseLandmark? leftFoot = pose.landmarks[PoseLandmarkType.leftFootIndex];
    final PoseLandmark? rightFoot = pose.landmarks[PoseLandmarkType.rightFootIndex];
    final PoseLandmark? head = pose.landmarks[PoseLandmarkType.nose];

    if (leftFoot == null || rightFoot == null || head == null) {
      setState(() {
        _feedbackMessage = "No poses detected";
      });
      return;
    }

    final Size imageSize = Size(
      _controller.value.previewSize!.height,
      _controller.value.previewSize!.width,
    );

    final headPos = Offset(
      (head.x / imageSize.width) * MediaQuery.of(context).size.width,
      (head.y / imageSize.height) * MediaQuery.of(context).size.height,
    );

    final feetPos = [
      Offset(
        (leftFoot.x / imageSize.width) * MediaQuery.of(context).size.width,
        (leftFoot.y / imageSize.height) * MediaQuery.of(context).size.height,
      ),
      Offset(
        (rightFoot.x / imageSize.width) * MediaQuery.of(context).size.width,
        (rightFoot.y / imageSize.height) * MediaQuery.of(context).size.height,
      ),
    ];

    final isFeetOnGrid = feetPos.every((pos) => pos.dy > MediaQuery.of(context).size.height * 0.8);
    final isHeadCentered = headPos.dx > MediaQuery.of(context).size.width * 0.4 &&
        headPos.dx < MediaQuery.of(context).size.width * 0.6;

    if (isFeetOnGrid && isHeadCentered) {
      setState(() {
        _feedbackMessage = "Perfect! Hold still and click the camera button.";
      });
    } else {
      setState(() {
        if (!isFeetOnGrid) {
          _feedbackMessage = "Move the camera down to include your feet.";
        } else if (!isHeadCentered) {
          _feedbackMessage = "Center your head in the middle of the screen.";
        }
      });
    }
  }
*/
  Future<void> checkCameraPermission() async {
    if (await Permission.camera.request().isGranted &&
        await Permission.storage.request().isGranted) {
      return;
    } else {
      await [
        Permission.camera,
        Permission.storage,
      ].request();
    }
  }

  void _captureImage() async {
    await checkCameraPermission();

    try {
      await _controller.stopImageStream();
      if (!_controller.value.isInitialized) {
        _showError('Camera not initialized');
        return;
      }

      final rawImage = await _controller.takePicture();
      await ImageGallerySaver.saveFile(rawImage.path);

      await _controller.startImageStream(_processCameraImage);
    } catch (e) {
      _showError('Error capturing image: $e');
    }
  }
  void _setDetectionMode(DetectionModes mode) {
    String dialogTitle;
    String contentText;
    switch (mode) {
      case DetectionModes.object:
        dialogTitle = '물체 사진 모드';
        contentText = '이 모드는 물체를 감지하는 모드입니다.';
        break;
      case DetectionModes.pose:
        dialogTitle = '전신사진 모드';
        contentText = '이 모드는 전신 사진을 촬영하는 모드입니다.';
        break;
      default:
        dialogTitle = '모드 변경';
        contentText = '모드에 대한 설명이 없습니다.';
        break;
    }

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(dialogTitle),
          content: Text(contentText),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                setState(() {
                  _detectionMode = mode;
                  _feedbackMessage = dialogTitle;
                });
              },
              child: Text('확인'),
            ),
          ],
        );
      },
    );
  }

  Color targetColor = Colors.red;

  void _performOperationOnMarkerCoordinates() {
    if (_markerPainter == null) {
      setState(() {
        _feedbackMessage = "No poses detected";
      });
      return;
    }else{
      for (final offset in _markerPainter!.markerOffsets) {
        final headAligned = (offset != null &&
            (offset.dx >MediaQuery.of(context).size.width * 0.33) &&(offset.dx < MediaQuery.of(context).size.width* 0.66));
        final feetAligned = (offset != null &&
            (offset.dy - feetTarget.dy)>0);
        if (feetAligned && headAligned) {
          setState(() {
            targetColor = Colors.green;
            _feedbackMessage = "Perfect! Hold still and click the camera button.";
          });
          break;
        } else {
          if (!headAligned) {
            setState(() {
              targetColor = Colors.red.withOpacity(1.0);
              _feedbackMessage =
              "Center your head in the middle of the screen.";
            });
          } else if (!feetAligned) {
            setState(() {
              targetColor = Colors.red.withOpacity(1.0);
              _feedbackMessage = "Move the camera down to include your feet.";
            });
          }
        }
      }
    }
  }

  void _showError(String message) {
    setState(() {
      _feedbackMessage = message;
    });
    print(message);
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return Center(child: CircularProgressIndicator());
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final previewSize = _controller.value.previewSize!;
    final previewAspectRatio = previewSize.height / previewSize.width;
    final previewHeight = screenWidth * previewAspectRatio;
    headTarget = Offset(screenWidth / 2, screenHeight * 0.2);
    feetTarget = Offset(screenWidth / 2, previewSize.height * 0.75);
    _markerPainter = MarkerPainter(
      detectedPoses: _detectedPoses,
      imageSize: Size(
        _controller.value.previewSize!.height,
        _controller.value.previewSize!.width,
      ),
    );

    return Column(
      children: [
        Container(
          width: 400,
          height: 800,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.9),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 62,
                child: Container(
                  width: 400,
                  height: 597,
                  decoration: BoxDecoration(color: Color(0xFFD9D9D9)),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(_controller),
                      if (_detectionMode == DetectionModes.object)
                        CustomPaint(
                          painter: ObjectDetectorPainter(
                            detectedObjects: _detectedObjects,
                            imageSize: Size(
                              _controller.value.previewSize!.height,
                              _controller.value.previewSize!.width,
                            ),
                          ),
                        ),
                      if (_detectionMode == DetectionModes.pose)
                        CustomPaint(
                          painter: PosePainter(
                            detectedPoses: _detectedPoses,
                            imageSize: Size(
                              _controller.value.previewSize!.height,
                              _controller.value.previewSize!.width,
                            ),
                          ),
                        ),
                      CustomPaint(
                        painter: GridPainter(),
                      ),
                      CustomPaint(
                        painter: _markerPainter,
                      ),
                      Positioned(
                        left: feetTarget.dx - 10,
                        top: feetTarget.dy - 10,
                        child: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            color: targetColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _buildModeButton(left: 156, top: 676, label: '물체 사진', onTap: () => _setDetectionMode(DetectionModes.object)),
              _buildModeButton(left: 50, top: 676, label: '전신사진', onTap: () => _setDetectionMode(DetectionModes.pose)),
              _buildModeButton(left: 259, top: 676, label: '모드 3', onTap: () {}),
              _buildCaptureButton(left: 153, top: 718, onTap: _captureImage),
              _buildGalleryButton(left: 25, top: 728),
              Positioned(
                left: 83,
                top: 35,
                child: SizedBox(
                  width: 200,
                  height: 30,
                  child: Text(
                    _feedbackMessage,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Color(0xFFF5E12A),
                      fontSize: 12,
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w400,
                      height: 0,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildModeButton({required double left, required double top, required String label, required VoidCallback onTap}) {
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 53,
          height: 15,
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontFamily: 'Inter',
              fontWeight: FontWeight.w400,
              height: 0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton({required double left, required double top, required VoidCallback onTap}) {
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: ShapeDecoration(
                color: Color(0xFFD9D9D9),
                shape: OvalBorder(),
              ),
            ),
            Container(
              width: 50,
              height: 50,
              decoration: ShapeDecoration(
                color: Color(0xFFD9D9D9),
                shape: OvalBorder(
                  side: BorderSide(
                    width: 1,
                    strokeAlign: BorderSide.strokeAlignOutside,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryButton({required double left, required double top}) {
    return Positioned(
      left: left,
      top: top,
      child: Container(
        width: 40,
        height: 40,
        decoration: ShapeDecoration(
          color: Color(0xFFD9D9D9),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
    );
  }
}
