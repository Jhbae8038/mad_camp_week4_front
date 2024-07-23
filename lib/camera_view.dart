import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'detector_painter.dart';
import 'package:permission_handler/permission_handler.dart';

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
    _disposeCamera();
    _objectDetector.close();
    _poseDetector.close();
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
      print("Camera initialized");
      _controller.startImageStream((CameraImage image) async {
        if (_isDetecting) return;
        _isDetecting = true;
        await _processCameraImage(image);
        _isDetecting = false;
      });
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> _disposeCamera() async {
    try {
      await _controller.stopImageStream();
    } catch (e) {
      print("Failed to stop image stream: $e");
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
    print("Object detector initialized");

    final poseOptions = PoseDetectorOptions();
    _poseDetector = PoseDetector(options: poseOptions);
    print("Pose detector initialized");
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

    print("Converting CameraImage to InputImage");

    if (Platform.isIOS) {
      rotation = InputImageRotationValue.fromRawValue(sensorOrientation);
      print("Rotation for iOS: $rotation");
    } else if (Platform.isAndroid) {
      var rotationCompensation = _orientations[_controller.value.deviceOrientation];
      print("Rotation compensation: $rotationCompensation");

      if (rotationCompensation == null) {
        print("Rotation compensation is null");
        return null;
      }

      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation = (sensorOrientation - rotationCompensation + 360) % 360;
      }
      rotation = InputImageRotationValue.fromRawValue(rotationCompensation);
      print("Rotation for Android: $rotation");
    }

    if (rotation == null) {
      print("Rotation is null");
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
    final inputImage = _inputImageFromCameraImage(image);
    if (inputImage == null) {
      print("Failed to convert CameraImage to InputImage");
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
        if (objects.isNotEmpty) {
          print("Detected ${objects.length} objects");
        } else {
          print("No objects detected");
        }

        setState(() {
          _detectedObjects = objects;
          _detectedPoses = [];
        });
      } else if (_detectionMode == DetectionModes.pose) {
        final List<Pose> poses = await _poseDetector.processImage(inputImage);
        if (poses.isNotEmpty) {

          print("Detected ${poses.length} poses");
          _updateFeedback(poses);

          setState(() {
            _detectedPoses = poses;
            _detectedObjects = [];
          });
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _performOperationOnMarkerCoordinates();
          });
        } else {
          print("No poses detected");
          setState(() {
            _feedbackMessage = "No poses detected";
          });
        }
      }
    } catch (e) {
      print('Error detecting objects: $e');
    }
  }
  void _updateFeedback(List<Pose> poses) {
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

  Future<void> checkCameraPermission() async {
    if (await Permission.camera.request().isGranted &&
        await Permission.storage.request().isGranted) {
      print("All permissions granted.");
    } else {
      print("Permissions not granted. Requesting permissions...");
      await [
        Permission.camera,
        Permission.storage,
      ].request();
    }
  }

  void _captureImage() async {
    print("Starting capture process...");

    // 권한 확인
    await checkCameraPermission();
    print("Camera permission granted.");

    // 이미지 스트림 중지
    try {
      await _controller.stopImageStream();
      print("Image stream stopped.");
    } catch (e) {
      print("Failed to stop image stream: $e");
      return;
    }

    // 카메라가 제대로 초기화되었는지 확인
    if (!_controller.value.isInitialized) {
      print('카메라 초기화에 실패했습니다.');
      return;
    }

    // 이미지 캡처 시도
    XFile? rawImage;
    try {
      rawImage = await _controller.takePicture();
      print("Image captured");
    } catch (e) {
      print('이미지 캡처 실패: $e');
      return;
    }

    // 이미지가 null인지 확인
    if (rawImage == null) {
      print('이미지 캡처 실패');
      return;
    }

    // 이미지 저장 시도
    try {
      await ImageGallerySaver.saveFile(rawImage.path);
      print('이미지 저장됨');
    } catch (e) {
      print('이미지 저장 실패: $e');
    }

    // 이미지 스트림 다시 시작
    try {
      _controller.startImageStream((CameraImage image) async {
        if (_isDetecting) return;
        _isDetecting = true;
        await _processCameraImage(image);
        _isDetecting = false;
      });
      print("Image stream restarted.");
    } catch (e) {
      print("Failed to restart image stream: $e");
    }
  }
  void _setDetectionMode(DetectionModes mode) {
    setState(() {
      _detectionMode = mode;
    });
  }

  Color targetColor = Colors.red;

  void _performOperationOnMarkerCoordinates() {
    if (_markerPainter != null) {
      for (final offset in _markerPainter!.markerOffsets) {
        print('Marker Offset: $offset');
        print('Feet Target: $feetTarget');
        final feetAligned = (offset != null &&
            (offset.dy - feetTarget.dy).abs() < 20);
        if (feetAligned) {
          setState(() {
            targetColor = Colors.green;
            _feedbackMessage = "Move the camera down to include your feet.";
          });
          break;
        } else {
          setState(() {
            targetColor = Colors.red;
          });
        }
        print('Marker Offset: $offset');
      }
    }
  }


  @override
  Widget build(BuildContext context) {
    if (!_controller.value.isInitialized) {
      return Center(child: CircularProgressIndicator());
    }

    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    headTarget = Offset(screenWidth / 2, screenHeight * 0.2);
    feetTarget = Offset(screenWidth / 2, screenHeight * 0.85);
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
            color: Colors.black.withOpacity(0.8999999761581421),
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
              Positioned(
                left: 156,
                top: 676,
                child: GestureDetector(
                  onTap:()=> _setDetectionMode(DetectionModes.object),
                  child: SizedBox(
                    width: 53,
                    height: 15,
                    child: Text(
                      '물체 사진',
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
              ),
              Positioned(
                left: 50,
                top: 676,
                child: GestureDetector(
                  onTap:()=> _setDetectionMode(DetectionModes.pose),
                  child: SizedBox(
                    width: 51,
                    height: 15,
                    child: Text(
                      '전신사진',
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
              ),
              Positioned(
                left: 259,
                top: 676,
                child: GestureDetector(
                  //onTap:()=> _setDetectionMode(DetectionModes.segment),
                  child: SizedBox(
                    width: 51,
                    height: 15,
                    child: Text(
                      '모드 3',
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
              ),
              Positioned(//바깥쪽원
                left: 153,
                top: 718,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: ShapeDecoration(
                    color: Color(0xFFD9D9D9),
                    shape: OvalBorder(),
                  ),
                ),
              ),
              Positioned(//안쪽원
                left: 158,
                top: 723,
                child:GestureDetector(
                  onTap: _captureImage,
                  child: Container(
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
                ),
              ),
              Positioned(//갤러리
                left: 25,
                top: 728,
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
              ),
              /*
              Positioned(
                left: 16,
                top: 25,
                child: SizedBox(
                  width: 59,
                  height: 17,
                  child: Text(
                    '연속촬영',
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

               */
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
}