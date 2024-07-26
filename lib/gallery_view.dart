import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class GalleryPage extends StatefulWidget {
  final List<Map<String, dynamic>> imageData;

  GalleryPage({required this.imageData});

  @override
  _GalleryPageState createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  Color _getColorBasedOnScore(double score) {
    if (score < 50) {
      return Colors.red;
    } else if (score < 65) {
      return Colors.yellow;
    }else if (score < 70) {
      return Colors.green;
    }else {
      return Colors.purple;
    }
  }

  void _deleteImage(int index) {
    setState(() {
      widget.imageData.removeAt(index);
    });
  }

  void _showDeleteDialog(int index) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('이미지 삭제'),
          content: Text('이 이미지를 삭제하시겠습니까?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text('취소'),
            ),
            TextButton(
              onPressed: () {
                _deleteImage(index);
                Navigator.of(context).pop();
              },
              child: Text('삭제'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('갤러리'),
      ),
      body: GridView.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4.0,
          mainAxisSpacing: 4.0,
        ),
        itemCount: widget.imageData.length,
        itemBuilder: (context, index) {
          double score = widget.imageData[index]['score'];
          Color scoreColor = _getColorBasedOnScore(score);

          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FullScreenPage(
                    imageData: widget.imageData,
                    initialIndex: index,
                  ),
                ),
              );
            },
            onLongPress: () {
              _showDeleteDialog(index);
            },
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: FileImage(File(widget.imageData[index]['path'])),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Positioned(
                  top: 5,
                  left: 5,
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: scoreColor.withOpacity(0.7),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: EdgeInsets.all(4.0),
                    child: Text(
                      '점수: ${score.toStringAsFixed(1)}',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}


class FullScreenPage extends StatefulWidget {
  final List<Map<String, dynamic>> imageData;
  final int initialIndex;

  FullScreenPage({required this.imageData, required this.initialIndex});

  @override
  _FullScreenPageState createState() => _FullScreenPageState();
}

class _FullScreenPageState extends State<FullScreenPage> {
  late PageController _pageController;
  String _feedbackMessage = '';

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  Future<void> _getFeedback(String filename) async {
    final apiKey = 'your_api_key'; // Replace with your actual API key if needed
    final response = await http.post(
      Uri.parse('http://172.10.5.90/image-feedback/'),
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': 'Bearer $apiKey',
      },
      body: {
        'filename': filename,
      },
    );

    if (response.statusCode == 200) {
      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      setState(() {
        _feedbackMessage = responseData['feedback'];
      });
      _showFeedbackDialog(responseData['feedback']);
    } else {
      setState(() {
        _feedbackMessage = 'Failed to get feedback';
      });
      _showFeedbackDialog('Failed to get feedback');
    }
  }

  void _showFeedbackDialog(String feedback) {
    showDialog(
      context: context,
      builder: (context) {
        return CustomDialog(
            title: '이미지 피드백',
            content: feedback,
            onConfirm: () {
        Navigator.of(context).pop();
        });
      },
    );
  }

  Color _getColorBasedOnScore(double score) {
    if (score < 50) {
      return Colors.red;
    } else if (score < 75) {
      return Colors.yellow;
    } else {
      return Colors.green;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('이미지 뷰어'),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.imageData.length,
        itemBuilder: (context, index) {
          final image = widget.imageData[index];
          double score = image['score'];
          Color scoreColor = _getColorBasedOnScore(score);
          return Stack(
            children: [
              Center(
                child: Image.file(
                  File(image['path']),
                  fit: BoxFit.contain,
                ),
              ),
              Positioned(
                bottom: 20,
                left: 20,
                right: 20,
                child: Container(
                  padding: EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8.0),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: scoreColor.withOpacity(0.7),
                              shape: BoxShape.circle,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            '점수: ${score.toStringAsFixed(1)}',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      ElevatedButton(
                        onPressed: () {
                          _getFeedback(image['filename']);
                        },
                        child: Text('피드백 받기'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
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
      content: SingleChildScrollView(
    child:Text(
        content,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Color(0xFF191C20),
          fontSize: 15,
          fontFamily: 'Work Sans',
          fontWeight: FontWeight.w400,
        ),
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

