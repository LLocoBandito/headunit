import 'dart:math' as math;

import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

enum DrowsyState { noFace, calibrating, awake, eyesClosed, drowsy }

class DetectionResult {
  final double? ratio;
  final DrowsyState state;
  const DetectionResult(this.ratio, this.state);
}

class DrowsinessDetector {
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      enableContours: true,
      performanceMode: FaceDetectorMode.fast,
    ),
  );

  // Parameter yang perlu kamu tuning dari data nyata
  static const double thresholdFactor = 0.65; // 65% dari rasio mata terbuka
  static const Duration drowsyAfter = Duration(milliseconds: 1500);
  static const int calibrationSamples = 6; // 6 frame x 500 ms = 3 detik
  static const double defaultBaseline = 0.25;

  double? baseline;
  final List<double> _calib = [];
  bool _calibrating = false;
  DateTime? _closedSince;

  void startCalibration() {
    _calib.clear();
    _calibrating = true;
    baseline = null;
    _closedSince = null;
  }

  double _eyeRatio(List<math.Point<int>> pts) {
    final xs = pts.map((p) => p.x);
    final ys = pts.map((p) => p.y);
    final w = xs.reduce(math.max) - xs.reduce(math.min);
    final h = ys.reduce(math.max) - ys.reduce(math.min);
    return w == 0 ? 0 : h / w;
  }

  Future<DetectionResult> analyze(String path) async {
    final faces = await _detector.processImage(InputImage.fromFilePath(path));
    if (faces.isEmpty) {
      _closedSince = null;
      return DetectionResult(null, DrowsyState.noFace);
    }

    final face = faces.first;
    final l = face.contours[FaceContourType.leftEye]?.points;
    final r = face.contours[FaceContourType.rightEye]?.points;
    if (l == null || r == null || l.isEmpty || r.isEmpty) {
      return DetectionResult(null, DrowsyState.noFace);
    }

    final ratio = (_eyeRatio(l) + _eyeRatio(r)) / 2;

    // Mode kalibrasi: kumpulkan rasio mata terbuka
    if (_calibrating) {
      _calib.add(ratio);
      if (_calib.length >= calibrationSamples) {
        _calib.sort();
        baseline = _calib[_calib.length ~/ 2]; // median
        _calibrating = false;
      }
      return DetectionResult(ratio, DrowsyState.calibrating);
    }

    final threshold = (baseline ?? defaultBaseline) * thresholdFactor;
    if (ratio < threshold) {
      _closedSince ??= DateTime.now();
      final closedFor = DateTime.now().difference(_closedSince!);
      return DetectionResult(
        ratio,
        closedFor >= drowsyAfter ? DrowsyState.drowsy : DrowsyState.eyesClosed,
      );
    }
    _closedSince = null;
    return DetectionResult(ratio, DrowsyState.awake);
  }

  Future<void> dispose() => _detector.close();
}
