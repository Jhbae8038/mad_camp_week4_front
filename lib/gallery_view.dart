import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class GalleryPage extends StatelessWidget {
  final List<Map<String, dynamic>> imageData;

  GalleryPage({required this.imageData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Gallery'),
      ),
      body: GridView.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 4.0,
          mainAxisSpacing: 4.0,
        ),
        itemCount: imageData.length,
        itemBuilder: (context, index) {
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => FullScreenPage(
                    imageData: imageData,
                    initialIndex: index,
                  ),
                ),
              );
            },
            child: Stack(
              children: [
                Image.file(
                  File(imageData[index]['path']),
                  fit: BoxFit.cover,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black54,
                    padding: EdgeInsets.all(4.0),
                    child: Text(
                      'Score: ${imageData[index]['score']}',
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
        return
          AlertDialog(
          title: Text('Image Feedback'),
          content: SingleChildScrollView(
        child:Text(feedback),
        ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text('OK'),
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
        title: Text('Photo Viewer'),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.imageData.length,
        itemBuilder: (context, index) {
          final image = widget.imageData[index];
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
                right: 20,
                child: Container(
                  color: Colors.black54,
                  padding: EdgeInsets.all(8.0),
                  child: Column(
                    children: [
                      Text(
                        'Score: ${image['score']}',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                      SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () {
                          _getFeedback(image['filename']);
                        },
                        child: Text('Get Feedback'),
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