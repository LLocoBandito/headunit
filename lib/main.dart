import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';
import 'package:permission_handler/permission_handler.dart';

import 'drowsiness_detector.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Driver Drowsiness',
      theme: ThemeData.dark(),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final UVCCameraController _controller;
  final DrowsinessDetector _detector = DrowsinessDetector();

  bool _permissionGranted = false;
  bool _isOpen = false;
  String _status = 'Meminta izin kamera...';
  String? _lastPhotoPath;

  // Paksa UVCCameraView dibuat ulang setelah kamera ditutup
  int _viewKey = 0;

  // Deteksi kantuk
  bool _detecting = false;
  bool _loopRunning = false;
  DetectionResult? _result;

  // Diagnosis
  String _stage = '-';
  String _diag = '';
  int _tick = 0;
  int _fails = 0;

  @override
  void initState() {
    super.initState();
    _controller = UVCCameraController();

    _controller.cameraStateCallback = (state) {
      debugPrint('UVC state: $state @ ${DateTime.now()}');
      if (!mounted) return;
      final opened = state == UVCCameraState.opened;
      if (!opened && _detecting) _stopDetection();
      setState(() {
        _isOpen = opened;
        _status = 'Status kamera: $state';
      });
    };

    _controller.msgCallback = (msg) {
      debugPrint('UVC msg: $msg');
      if (!mounted) return;
      setState(() => _status = 'Pesan: $msg');
    };

    _requestPermission();
  }

  Future<void> _requestPermission() async {
    final result = await Permission.camera.request();
    if (!mounted) return;
    setState(() {
      _permissionGranted = result.isGranted;
      _status = result.isGranted
          ? 'Izin kamera OK. Colok kamera USB lalu tekan Buka Kamera.'
          : 'Izin kamera ditolak. Aktifkan lewat Pengaturan.';
    });
  }

  Future<void> _openCamera() async {
    // Beri waktu view baru terpasang dan perangkat USB dilepas sempurna
    await Future.delayed(const Duration(milliseconds: 600));
    _controller.openUVCCamera();
  }

  Future<void> _closeCamera() async {
    _stopDetection();
    _controller.closeCamera(); // bertipe void, jangan di-await
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() {
      _isOpen = false;
      _viewKey++; // paksa UVCCameraView dibuat ulang
    });
  }

  Future<void> _takePicture() async {
    final path = await _controller.takePicture();
    if (!mounted) return;
    setState(() {
      _lastPhotoPath = path;
      _status = path != null ? 'Foto tersimpan: $path' : 'Gagal mengambil foto';
    });
  }

  // ---------- Deteksi kantuk ----------

  void _startDetection() {
    if (!_isOpen || _detecting) return;
    _detector.startCalibration(); // 3 detik pertama: tatap lurus, mata terbuka
    setState(() {
      _detecting = true;
      _result = null;
      _tick = 0;
      _fails = 0;
      _stage = '-';
      _diag = 'mulai';
    });
    if (!_loopRunning) _detectionLoop();
  }

  Future<void> _detectionLoop() async {
    _loopRunning = true;
    await Future.delayed(
      const Duration(seconds: 2),
    ); // beri kamera waktu stabil

    while (mounted && _detecting && _isOpen) {
      _tick++;
      String? path;
      try {
        _stage = 'takePicture';
        path = await _controller.takePicture().timeout(
          const Duration(seconds: 5),
        );
        debugPrint('DETEKSI path=$path');
        if (path == null) throw Exception('takePicture null');

        _stage = 'analyze';
        final result = await _detector
            .analyze(path)
            .timeout(const Duration(seconds: 5));
        debugPrint('DETEKSI hasil=${result.state} ratio=${result.ratio}');
        _fails = 0;
        if (!mounted || !_detecting) break;
        setState(() {
          _result = result;
          _diag = 'tick $_tick OK';
        });
      } catch (e) {
        _fails++;
        debugPrint('DETEKSI error di tahap $_stage ($_fails): $e');
        if (mounted) {
          setState(() => _diag = 'tick $_tick gagal di $_stage ($_fails): $e');
        }
        if (_fails >= 3) {
          if (mounted) {
            setState(
              () => _status =
                  'Deteksi berhenti: gagal 3x di tahap $_stage. Tutup lalu buka kamera lagi.',
            );
          }
          break;
        }
        await Future.delayed(
          const Duration(seconds: 2),
        ); // jeda sebelum coba lagi
      } finally {
        if (path != null) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
      }
      await Future.delayed(const Duration(milliseconds: 1000)); // sekitar 1 FPS
    }

    _loopRunning = false;
    if (mounted && _detecting) _stopDetection();
  }

  void _stopDetection() {
    if (mounted) {
      setState(() {
        _detecting = false;
        _result = null;
      });
    } else {
      _detecting = false;
    }
  }

  String _stateText() {
    final r = _result;
    if (r == null) return 'Menunggu frame pertama...\n$_diag';
    final ratio = r.ratio?.toStringAsFixed(3) ?? '-';
    final base = _detector.baseline?.toStringAsFixed(3) ?? '-';
    switch (r.state) {
      case DrowsyState.noFace:
        return 'Wajah tidak terdeteksi\n$_diag';
      case DrowsyState.calibrating:
        return 'Kalibrasi... tatap lurus (rasio $ratio)\n$_diag';
      case DrowsyState.awake:
        return 'Awas | rasio $ratio | baseline $base\n$_diag';
      case DrowsyState.eyesClosed:
        return 'Mata tertutup | rasio $ratio | baseline $base\n$_diag';
      case DrowsyState.drowsy:
        return 'MENGANTUK! | rasio $ratio | baseline $base\n$_diag';
    }
  }

  Color _bannerColor() {
    switch (_result?.state) {
      case DrowsyState.drowsy:
        return Colors.red;
      case DrowsyState.eyesClosed:
        return Colors.orange.shade800;
      case DrowsyState.calibrating:
        return Colors.blueGrey;
      default:
        return Colors.black87;
    }
  }

  @override
  void dispose() {
    _detecting = false;
    _detector.dispose();
    _controller.closeCamera();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Deteksi Kantuk - Nakamichi'),
        backgroundColor: Colors.grey[900],
      ),
      body: Column(
        children: [
          // Area preview + banner overlay (ukuran preview tidak berubah)
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: Colors.black,
                    child: _permissionGranted
                        ? LayoutBuilder(
                            builder: (context, constraints) => UVCCameraView(
                              key: ValueKey(_viewKey),
                              cameraController: _controller,
                              width: constraints.maxWidth,
                              height: constraints.maxHeight,
                            ),
                          )
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ),
                if (_detecting)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: Container(
                      color: _bannerColor().withValues(alpha: 0.85),
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        _stateText(),
                        textAlign: TextAlign.center,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // Status kamera
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _status,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),

          // Tombol kontrol
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: (_permissionGranted && !_isOpen)
                      ? _openCamera
                      : null,
                  child: const Text('Buka Kamera'),
                ),
                ElevatedButton(
                  onPressed: _isOpen ? _closeCamera : null,
                  child: const Text('Tutup'),
                ),
                ElevatedButton(
                  onPressed: _isOpen ? _takePicture : null,
                  child: const Text('Ambil Foto'),
                ),
                ElevatedButton(
                  onPressed: _isOpen
                      ? (_detecting ? _stopDetection : _startDetection)
                      : null,
                  child: Text(_detecting ? 'Stop Deteksi' : 'Mulai Deteksi'),
                ),
              ],
            ),
          ),

          if (_lastPhotoPath != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _lastPhotoPath!,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
