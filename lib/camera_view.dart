import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:mad_week4_front/gallery_view.dart';
import 'package:path_provider/path_provider.dart';
import 'detector_painter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class DetectionView extends StatefulWidget {
  final List<CameraDescription> cameras;
  const DetectionView({Key? key, required this.cameras}) : super(key: key);

  @override
  State<DetectionView> createState() => _DetectionViewState();
}

enum DetectionModes { object, pose, side }

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
  List<Map<String, dynamic>> _imageData = [];

  MarkerPainter? _markerPainter;
  String _feedbackMessage = "";
  Map<Offset, Color> gridPoints = {};

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
    _loadImageData();
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
      var rotationCompensation =
          _orientations[_controller.value.deviceOrientation];

      if (rotationCompensation == null) {
        _showError("Rotation compensation is null");
        return null;
      }

      if (camera.lensDirection == CameraLensDirection.front) {
        rotationCompensation = (sensorOrientation + rotationCompensation) % 360;
      } else {
        rotationCompensation =
            (sensorOrientation - rotationCompensation + 360) % 360;
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
/*
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    final imageSize = Size(
      _controller.value.previewSize!.height,
      _controller.value.previewSize!.width,
    );
    final scaleX = screenWidth / imageSize.width;
    final scaleY = screenHeight / imageSize.height;
*/
    try {
      if (_detectionMode == DetectionModes.object) {
        final List<DetectedObject> objects =
            await _objectDetector.processImage(inputImage);
        setState(() {
          _detectedObjects = objects;
          _detectedPoses = [];
          _feedbackMessage='물체사진';
        });
      } else if (_detectionMode == DetectionModes.pose) {
        final List<Pose> poses = await _poseDetector.processImage(inputImage);

        setState(() {
          _detectedPoses = poses;
          _detectedObjects = [];
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _performOperationOnMarkerCoordinates();
        });

      } else if (_detectionMode == DetectionModes.side) {
        final List<Pose> poses = await _poseDetector.processImage(inputImage);

        setState(() {
          _detectedPoses = poses;
          _detectedObjects = [];
        });

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _performOperationOnMarkerCoordinates_side();
        });
      }
    } catch (e) {
      _showError('Error detecting objects: $e');
    } finally {
      _isDetecting = false;
    }
  }

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
      if (_controller.value.isStreamingImages) {
        await _controller.stopImageStream();
      }

      if (!_controller.value.isInitialized) {
        _showError('Camera not initialized');
        return;
      }

      final rawImage = await _controller.takePicture();

      final directory = await getApplicationDocumentsDirectory();
      final path =
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final File newImage = await File(rawImage.path).copy(path);

      await ImageGallerySaver.saveFile(newImage.path);
      await _sendImageToServer(newImage);

      if (!_controller.value.isStreamingImages) {
        await _controller.startImageStream(_processCameraImage);
      }
    } catch (e) {
      _showError('Error capturing image: $e');
    }
  }

  Future<void> _sendImageToServer(File imageFile) async {
    final request = http.MultipartRequest(
      'POST',
      Uri.parse(
          'http://172.10.5.90/upload-image'), // Replace with your backend URL
    );
    request.files
        .add(await http.MultipartFile.fromPath('file', imageFile.path));

    try {
      final response = await request.send();

      if (response.statusCode == 200) {
        final responseData = await response.stream.bytesToString();
        final jsonData = jsonDecode(responseData);
        final decodedData = jsonDecode(responseData);
        final filename = decodedData['filename'];

        final double score = jsonData['score'] is String
            ? double.tryParse(jsonData['score']) ?? 0.0
            : jsonData['score'] is int
                ? (jsonData['score'] as int).toDouble()
                : jsonData['score'] is double
                    ? jsonData['score']
                    : 0.0;

        setState(() {
          _imageData.add(
              {'path': imageFile.path, 'score': score, 'filename': filename});
        });
        _saveImageData();
      } else {
        _showError('Failed to get score from server');
      }
    } catch (e) {
      _showError('Error: $e');
    }
  }

  Future<void> _saveImageData() async {
    final prefs = await SharedPreferences.getInstance();
    final imageDataJson = jsonEncode(_imageData);
    await prefs.setString('imageData', imageDataJson);
  }

  Future<void> _loadImageData() async {
    final prefs = await SharedPreferences.getInstance();
    final imageDataJson = prefs.getString('imageData');
    if (imageDataJson != null) {
      setState(() {
        _imageData = List<Map<String, dynamic>>.from(jsonDecode(imageDataJson));
      });
    }
  }

  void _setDetectionMode(DetectionModes mode) {
    String dialogTitle;
    String contentText;
    switch (mode) {
      case DetectionModes.object:
        dialogTitle = '물체 사진 모드';
        contentText = """당신의 인생샷을 위한 물체사진 꿀팁!!\n
물체나 풍경 사진을 찍을 때에는 피사체를 격자점에 맞추어주세요!\n
적당한 여백이 있어야 여유와 안정감이 느껴집니다!\n
음식 사진의 경우 위에서 찍기 보다는 \n음식과 수평한 시야로 찍어주세요!\n""";
        break;
      case DetectionModes.pose:
        dialogTitle = '전신사진 모드';
        contentText = """당신의 인생샷을 위한 전신사진\n3가지 꿀팁!!\n
    1. 전신사진을 찍을 때는 발까지\n나오도록 하고 발목 자르지 않기!\n
    2. 얼굴은 왜곡이 적은 격자 가운데   위치시키고 화면 아래쪽에 발끝 맞추기!\n
    3. 사진 찍는 대상 눈높이보단 낮은 곳에서 약간 카메라를 내쪽으로 당겨서\n촬영하기!""";
        break;
      case DetectionModes.side:
        dialogTitle = '측면사진 모드';
        contentText = """당신의 인생샷을 위한 측면사진 꿀팁!!\n
격자의 1/3지점에 인물이 위치하도록 \n합니다!\n
인물이 바라보는 지점에는 배경적 여유가 있어야 안정적으로 느껴집니다!""";
        break;
      default:
        dialogTitle = '모드 변경';
        contentText = '모드에 대한 설명이 없습니다.';
        break;
    }

    showDialog(
      context: context,
      builder: (context) {
        return CustomDialog(
          title: dialogTitle,
          content: contentText,
          onConfirm: () {
            Navigator.of(context).pop();
            setState(() {
              _detectionMode = mode;
              _feedbackMessage = dialogTitle;
            });
          },
        );
      },
    );
  }


  Color targetColor = Color(0xFFD9D9D9);

  void _performOperationOnMarkerCoordinates() {
    if (_markerPainter == null ||
        _markerPainter!.markerOffsets['noseOffsets'] == null ||
        _markerPainter!.markerOffsets['footOffsets'] == null ||
        _markerPainter!.markerOffsets['noseOffsets']!.isEmpty ||
        _markerPainter!.markerOffsets['footOffsets']!.isEmpty) {
      setState(() {
        _feedbackMessage = "사람을 감지할 수 없어요";
        targetColor = Color(0xFFD9D9D9);
      });
      return;
    }
      final offset= _markerPainter!.markerOffsets['footOffsets']!.first;
        final headAligned = (offset != null &&
            (offset.dx > MediaQuery.of(context).size.width * 0.33) &&
            (offset.dx < MediaQuery.of(context).size.width * 0.66));
        final feetAligned = (offset != null && (offset.dy - feetTarget.dy) > 0);
        if (feetAligned && headAligned) {
          setState(() {
            targetColor = Colors.green;
            _feedbackMessage =
                "완벽해요!";
          });
        } else {
          if (!headAligned) {
            setState(() {
              targetColor = Colors.red;
              _feedbackMessage =
                  "중앙으로 이동해주세요";
            });
          } else if (!feetAligned) {
            setState(() {
              targetColor = Colors.red;
              _feedbackMessage = "발 끝선을 맞춰주세요";
            });
          }

      }

  }


  void _performOperationOnMarkerCoordinates_side() {
    if (_markerPainter == null ||
        _markerPainter!.markerOffsets['noseOffsets'] == null ||
        _markerPainter!.markerOffsets['footOffsets'] == null ||
        _markerPainter!.markerOffsets['noseOffsets']!.isEmpty ||
        _markerPainter!.markerOffsets['footOffsets']!.isEmpty) {
      setState(() {
        _feedbackMessage = "사람을 감지할 수 없어요";
        targetColor = Color(0xFFD9D9D9);
      });
      return;
    }
      final offset= _markerPainter!.markerOffsets['footOffsets']!.first;
      final offset_nose= _markerPainter!.markerOffsets['noseOffsets']!.first;
        final headAligned = (offset_nose != null &&(
            ((offset_nose.dx - MediaQuery.of(context).size.width * 0.33).abs()<20) ||
            ((offset_nose.dx - MediaQuery.of(context).size.width * 0.66).abs()<20)));
        final feetAligned = (offset != null &&(
          ((offset.dx - MediaQuery.of(context).size.width * 0.33).abs()<20) ||
              ((offset.dx - MediaQuery.of(context).size.width * 0.66).abs()<20)));
        final feetAligned_y = (offset != null && (offset.dy - feetTarget.dy) > 0);
        if (feetAligned && headAligned && feetAligned_y) {
          setState(() {
            targetColor = Colors.green;
            _feedbackMessage =
            "완벽해요!";
          });
        } else {
          if (!headAligned) {
            setState(() {
              targetColor = Colors.red;
              _feedbackMessage =
              "머리를 측면 1/3 라인에 맞춰주세요";
            });
          } else if (!feetAligned) {
            setState(() {
              targetColor = Colors.red;
              _feedbackMessage = "발을 측면 1/3 라인에 맞춰주세요";
            });
          }
          else if(!feetAligned_y) {
            setState(() {
              targetColor = Colors.red;
              _feedbackMessage = "발 끝선을 맞춰주세요";
            });
          }

      }

  }


  Color targetColor_obj = Colors.grey;

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
    feetTarget = Offset(screenWidth / 2, screenHeight * 0.9);

    gridPoints = {
      Offset(screenWidth / 3, screenHeight / 3): Colors.grey,
      // Adjusting for top offset
      Offset(2 * screenWidth / 3, screenHeight / 3): Colors.grey,
      Offset(screenWidth / 3, 2 * screenHeight / 3): Colors.grey,
      Offset(2 * screenWidth / 3, 2 * screenHeight / 3): Colors.grey,
    };

    _markerPainter = MarkerPainter(
      detectedPoses: _detectedPoses,
      imageSize: Size(
        _controller.value.previewSize!.height,
        _controller.value.previewSize!.width,
      ),
    );

    return Scaffold(
      body: Column(
      children: [
        Container(
          width: screenWidth,
          height: screenHeight,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.9),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 0,
                top: 0,
                child: Container(
                  width: screenWidth,
                  height: screenHeight,
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
                            gridPoints: gridPoints,
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
                        painter: GridPainter(gridPoints: gridPoints),
                      ),
                      CustomPaint(
                        painter: _markerPainter,
                      ),
                      /*
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

                       */
                      CustomPaint(
                        painter: LinePainter(
                            feetTarget.dy, targetColor), // Add LinePainter here
                      ),
                    ],
                  ),
                ),
              ),
              _buildModeButton(
                  left: screenWidth * 0.11,
                  top: screenHeight * 0.83,
                  label: '전신사진',
                  mode: DetectionModes.pose),
              _buildModeButton(
                  left: screenWidth * 0.43,
                  top: screenHeight * 0.83,
                  label: '물체사진',
                  mode: DetectionModes.object),
              _buildModeButton(
                  left: screenWidth * 0.76,
                  top: screenHeight * 0.83,
                  label: '측면사진',
                  mode: DetectionModes.side),
              _buildCaptureButton(
                  left: screenWidth * 0.42,
                  top: screenHeight * 0.898,
                  onTap: _captureImage),
              _buildGalleryButton(
                left: screenWidth * 0.0625,
                top: screenHeight * 0.91,
                onTap: () async {
                  if (_controller.value.isStreamingImages) {
                    await _controller.stopImageStream();
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => GalleryPage(imageData: _imageData),
                    ),
                  ).then((_) {
                    if (!_controller.value.isStreamingImages) {
                      _controller.startImageStream(_processCameraImage);
                    }
                  });
                },
              ),
              Positioned(
                left: 86,
                top: 35,
                child: SizedBox(
                  width: 200,
                  height: 30,

                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.purple,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _feedbackMessage,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                        height: 0,
                      ),
                    ),
                  ),

                ),
              ),
            ],
          ),
        ),
      ],
    ),
    );
  }

  Widget _buildModeButton(
      {required double left,
      required double top,
      required String label,
      required DetectionModes mode}) {
    final isActive = _detectionMode == mode;
    final color = isActive ? Colors.white : Colors.white; // 활성화된 모드는 노란색으로 표시
    final fontWeight = isActive ? FontWeight.bold : FontWeight.normal; // 활성화된 모드는 굵은 글씨
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: () => _setDetectionMode(mode),
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: isActive ? Colors.purple : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontFamily: 'Inter',
              fontWeight: fontWeight,
              height: 0,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCaptureButton(
      {required double left,
      required double top,
      required VoidCallback onTap}) {
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
                color: Colors.transparent, // 바깥 쪽 링의 색상
                shape: OvalBorder(
                  side: BorderSide(
                    color: targetColor, // 바깥 쪽 링의 색상
                    width: 3, // 링의 두께
                  ),
                ),
              ),
            ),
            Container(
              width: 50,
              height: 50,
              decoration: ShapeDecoration(
                color: Colors.transparent, // 가운데 버튼을 투명하게 설정
                shape: OvalBorder(
                  side: BorderSide(
                    color: targetColor, // 바깥 쪽 링의 색상
                    width: 1, // 내부 링의 두께
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryButton(
      {required double left,
      required double top,
      required VoidCallback onTap}) {
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onTap: onTap,
        child:IconButton(
          onPressed: onTap,
          icon:
          Icon(Icons.photo_library, color: Color(0xFFD9D9D9)),
          iconSize: 40,


        ),
      ),
    );
  }
}

class CustomDialog extends StatelessWidget {
  final String title;
  final String content;
  final VoidCallback onConfirm;

  CustomDialog({required this.title, required this.content, required this.onConfirm});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(24.0)),
      ),
      title: Text(
        title,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.purple,
          fontSize: 24,
          fontFamily: 'Work Sans',
          fontWeight: FontWeight.w600,
        ),
      ),
      content: Text(
        content,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xFF191C20),
          fontSize: 16,
          fontFamily: 'Work Sans',
          fontWeight: FontWeight.w400,
        ),
      ),
      actions: [
        Center(
          child: TextButton(
            onPressed: onConfirm,
            child: Text(
              '확인',
              style: TextStyle(
                color: Color(0xFF191C20),
                fontSize: 18,
                fontFamily: 'Work Sans',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
      actionsAlignment: MainAxisAlignment.center, // 이 줄을 추가하여 버튼을 가운데 정렬
    );
  }
}

class LinePainter extends CustomPainter {
  final double yOffset;
  final Color lineColor;

  LinePainter(this.yOffset, this.lineColor);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = lineColor
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;

    final dashWidth = 5.0;
    final dashSpace = 5.0;
    double startX = 0;

    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, yOffset),
        Offset(startX + dashWidth, yOffset),
        paint,
      );
      startX += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return false;
  }
}
