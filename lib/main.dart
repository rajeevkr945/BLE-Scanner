import 'dart:async';
import 'dart:io';
import 'dart:typed_data'; // Required for Uint8List and BytesBuilder
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:image/image.dart' as img; // Import image package with prefix
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:permission_handler/permission_handler.dart'; // Import permission handler
import 'package:device_info_plus/device_info_plus.dart'; // <--- MOVED IMPORT HERE

// --- Constants ---
final Guid _IMAGE_SERVICE_UUID = Guid("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
// Notification Characteristic UUID provided by user
final Guid _IMAGE_NOTIFICATION_CHAR_UUID = Guid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");

const int IMAGE_WIDTH = 80;
const int IMAGE_HEIGHT = 62;
const int TOTAL_PIXELS = IMAGE_WIDTH * IMAGE_HEIGHT;

void main() {
  // FlutterBluePlus.setLogLevel(LogLevel.verbose, color:true); // Optional: for verbose logging
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Image Viewer',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
      ),
      home: const BleScannerScreen(),
      routes: {
        // Placeholder route definition, actual device passed during navigation
        '/imageDisplay': (context) => ImageDisplayScreen(device: BluetoothDevice(remoteId: const DeviceIdentifier('00:00:00:00:00:00'))),
      },
    );
  }
}


class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  List<ScanResult> _allScanResults = [];
  List<ScanResult> _filteredScanResults = [];
  bool _isScanning = false;
  BluetoothDevice? _connectedDevice;
  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  int _currentMtu = 0;

  final TextEditingController _nameFilterController = TextEditingController();
  final TextEditingController _rssiFilterController = TextEditingController();
  final TextEditingController _manufacturerIdFilterController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _nameFilterController.addListener(_applyFilters);
    _rssiFilterController.addListener(_applyFilters);
    _manufacturerIdFilterController.addListener(_applyFilters);
    _checkBluetoothAdapterState();
  }

  Future<void> _checkBluetoothAdapterState() async {
    if (!mounted) return;
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please turn on Bluetooth.")),
        );
      }
      // Wait until the adapter is on
      await FlutterBluePlus.adapterState
          .where((s) => s == BluetoothAdapterState.on)
          .first;
    }
  }

  void _toggleScan() async {
    if (!mounted) return;
    if (_isScanning) {
      await _stopScan();
    } else {
      // Check BT status before starting scan
      if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Cannot start scan. Bluetooth is off.")),
          );
        }
        await _checkBluetoothAdapterState(); // Wait for it to be turned on
        if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) return; // Still off, don't scan
      }
      await _startScan();
    }
  }

  Future<void> _startScan() async {
    if (!mounted) return;
    // Consider disconnecting only if you *must* disconnect before scanning
    // Often, scanning while connected is possible and desired.
    // await _disconnectFromDevice();

    setState(() {
      _isScanning = true;
      _allScanResults.clear();
      _filteredScanResults.clear();
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

      _scanResultsSubscription?.cancel();
      _scanResultsSubscription = FlutterBluePlus.scanResults.listen((results) {
        if (!mounted) return;
        setState(() {
          // Filter results to only include devices with a name
          _allScanResults = results.where((r) => r.device.platformName.isNotEmpty || r.advertisementData.advName.isNotEmpty).toList();
          _applyFilters(); // Apply user filters
        });
      }, onError: (e) {
        print("Scan Error: $e");
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Scan Error: $e")));
        _stopScan();
      });
    } catch (e) {
      print("Error starting scan: $e");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error starting scan: $e. Check permissions & Bluetooth status.")));
      if (mounted) setState(() => _isScanning = false);
    }

    // Automatically stop the scan visually after the timeout
    Future.delayed(const Duration(seconds: 10), () {
      if (_isScanning && mounted) _stopScan();
    });
  }

  Future<void> _stopScan() async {
    // Check if scan is active before stopping
    if (FlutterBluePlus.isScanningNow) {
      await FlutterBluePlus.stopScan();
    }
    if (mounted) setState(() => _isScanning = false);
  }

  void _applyFilters() {
    if (!mounted) return;
    List<ScanResult> tempResults = List.from(_allScanResults);
    String nameQuery = _nameFilterController.text.toLowerCase();
    if (nameQuery.isNotEmpty) {
      tempResults = tempResults.where((result) =>
      result.device.platformName.toLowerCase().contains(nameQuery) ||
          result.advertisementData.advName.toLowerCase().contains(nameQuery)).toList();
    }
    int? minRssi = int.tryParse(_rssiFilterController.text);
    if (minRssi != null) {
      tempResults = tempResults.where((result) => result.rssi >= minRssi).toList();
    }
    int? manufacturerId = int.tryParse(_manufacturerIdFilterController.text);
    if (manufacturerId != null) {
      tempResults = tempResults.where((result) =>
          result.advertisementData.manufacturerData.containsKey(manufacturerId)).toList();
    }
    setState(() => _filteredScanResults = tempResults);
  }

  Future<void> _connectAndNavigate(BluetoothDevice device) async {
    if (!mounted) return;
    if (_isScanning) await _stopScan(); // Stop scanning before connecting

    // Check if already trying to connect or connected to this device
    if (_connectedDevice?.remoteId == device.remoteId && device.isConnected) {
      print("Already connected to ${device.platformName}.");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Already connected to ${device.platformName}")));
      // Optionally navigate again if already connected
      // _navigateToImageScreen(device);
      return;
    }

    // Disconnect from any previously connected device
    await _disconnectFromDevice();

    if (!mounted) return;
    // Show connecting message
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Connecting to ${device.platformName.isNotEmpty ? device.platformName : device.remoteId.str}...")),
    );
    print("Attempting to connect to ${device.platformName} (${device.remoteId})");

    BluetoothCharacteristic? targetCharacteristic; // To store the characteristic

    try {
      // Cancel any previous connection state subscription
      _connectionStateSubscription?.cancel();
      // Listen to the connection state stream
      _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) async {
        if (!mounted) return; // Check if widget is still mounted
        print("Device ${device.remoteId} state: $state");

        if (state == BluetoothConnectionState.connected) {
          // Update the UI to show connected device
          setState(() => _connectedDevice = device);
          print("Connected to ${device.platformName}. Discovering services...");
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connected to ${device.platformName}. Discovering services...")));

          List<BluetoothService> services = [];
          try {
            // Discover services after connection
            services = await device.discoverServices();
            print("Services discovered for ${device.platformName}");
          } catch (e) {
            print("Error discovering services: $e");
            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error discovering services: $e")));
            await _disconnectFromDevice(); // Disconnect if service discovery fails
            return;
          }

          // Find the specific image service
          BluetoothService? imageService;
          try { imageService = services.firstWhere((s) => s.uuid == _IMAGE_SERVICE_UUID); } catch (e) { imageService = null; }

          // Handle if service not found
          if (imageService == null) {
            print("Image Service ($_IMAGE_SERVICE_UUID) not found.");
            if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Required Image Service not found on this device.")));
            await _disconnectFromDevice();
            return;
          }

          // Find the specific notification characteristic within the service
          try { targetCharacteristic = imageService.characteristics.firstWhere((c) => c.uuid == _IMAGE_NOTIFICATION_CHAR_UUID && c.properties.notify); } catch (e) { targetCharacteristic = null; }

          // Handle if characteristic not found or doesn't support notify
          if (targetCharacteristic == null) {
            print("Image Characteristic ($_IMAGE_NOTIFICATION_CHAR_UUID) with Notify property not found.");
            if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Required Image Characteristic not found.")));
            await _disconnectFromDevice();
            return;
          }

          print("Found target characteristic. Requesting MTU and navigating.");
          // Request higher MTU on Android for potentially faster data transfer
          if (!kIsWeb && Platform.isAndroid) {
            print("Requesting MTU 512 for Android");
            try {
              // Request MTU and wait briefly for negotiation
              await device.requestMtu(512, timeout: 2);
              // Read the negotiated MTU value
              _currentMtu = await device.mtu.first;
              print("MTU is now: $_currentMtu");
            } catch(e_mtu) {
              print("Error requesting MTU: $e_mtu");
              if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("MTU request failed: $e_mtu")));
              // Proceed even if MTU request fails
            }
          }

          // Navigate to the image display screen
          _navigateToImageScreen(device);

        } else if (state == BluetoothConnectionState.disconnected) {
          // Handle disconnection
          print("Disconnected from ${device.platformName}");
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Disconnected from ${device.platformName}")));
          _clearConnectionData(); // Clear connection state in UI
        }
      }, onError: (dynamic error) {
        // Handle errors in the connection state stream
        print("Connection state error: $error");
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Connection error: $error")));
        _clearConnectionData();
      });

      // Initiate the connection attempt
      await device.connect(timeout: const Duration(seconds: 15), autoConnect: false);

    } catch (e) {
      // Catch errors during the initial connect call
      print("Error connecting to device ${device.remoteId}: $e");
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Failed to connect: $e")));
      _clearConnectionData(); // Ensure state is cleared on connection failure
    }
  }

  // Navigate to the ImageDisplayScreen
  void _navigateToImageScreen(BluetoothDevice device) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ImageDisplayScreen(device: device),
      ),
    ).then((_) {
      // This code runs when returning from ImageDisplayScreen
      print("Returned from ImageDisplayScreen");
      // Check if the device is still connected upon return
      if (_connectedDevice != null && !_connectedDevice!.isConnected) {
        _clearConnectionData(); // Clear state if disconnected while away
      }
    });
  }

  // Disconnect from the currently connected device
  Future<void> _disconnectFromDevice() async {
    _connectionStateSubscription?.cancel(); // Cancel listener
    _connectionStateSubscription = null;
    if (_connectedDevice != null && _connectedDevice!.isConnected) {
      print("Disconnecting from ${_connectedDevice!.platformName}");
      try {
        await _connectedDevice!.disconnect(); // Send disconnect command
        print("Disconnect call completed for ${_connectedDevice!.platformName}");
      } catch (e) {
        print("Error during disconnect: $e");
      }
    }
    // Always clear local connection data after attempting disconnect
    _clearConnectionData();
  }

  // Clear local state related to the connection
  void _clearConnectionData() {
    if (mounted) {
      setState(() {
        _connectedDevice = null;
        _currentMtu = 0;
      });
    }
  }

  @override
  void dispose() {
    // Cancel all stream subscriptions
    _scanResultsSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    // Dispose text editing controllers
    _nameFilterController.dispose();
    _rssiFilterController.dispose();
    _manufacturerIdFilterController.dispose();
    // Ensure scanning is stopped
    FlutterBluePlus.stopScan();
    // Avoid disconnecting here, let user control or handle on screen pop
    // _disconnectFromDevice();
    super.dispose();
  }

  // Helper widget for creating filter text fields
  Widget _buildFilterTextField(TextEditingController controller, String labelText, TextInputType inputType) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: labelText,
          border: const OutlineInputBorder(),
          // Add a clear button to the text field
          suffixIcon: controller.text.isNotEmpty ? IconButton(icon: const Icon(Icons.clear), onPressed: () { controller.clear(); _applyFilters(); }) : null,
        ),
        keyboardType: inputType,
        onChanged: (_) => _applyFilters(), // Apply filters immediately on change
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Check if a device is currently connected
    bool isAnyDeviceConnected = _connectedDevice?.isConnected ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text("BLE Scanner"),
        actions: [
          // Show disconnect button only if connected
          if (isAnyDeviceConnected)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: TextButton(
                onPressed: _disconnectFromDevice,
                child: const Text("DISCONNECT", style: TextStyle(color: Colors.white)),
              ),
            )
        ],
      ),
      body: Column(
        children: [
          // Filter section
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(children: [
              _buildFilterTextField(_nameFilterController, "Filter by Name", TextInputType.text),
              _buildFilterTextField(_rssiFilterController, "Min RSSI (e.g., -70)", const TextInputType.numberWithOptions(signed: true)),
              _buildFilterTextField(_manufacturerIdFilterController, "Manufacturer ID (Decimal)", TextInputType.number),
            ]),
          ),
          // Section to show connected device info
          if (isAnyDeviceConnected)
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
                child: Card( elevation: 2, child: Padding( padding: const EdgeInsets.all(8.0),
                    child: Column( crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text("Status: Connected to ${_connectedDevice!.platformName.isNotEmpty ? _connectedDevice!.platformName : 'Unknown Device'} (${_connectedDevice!.remoteId})", style: const TextStyle(fontWeight: FontWeight.bold)),
                      // Button to re-open the image screen if already connected
                      ElevatedButton( child: const Text("VIEW IMAGE SCREEN"), onPressed: () => _navigateToImageScreen(_connectedDevice!),)
                    ])))),
          // Show scanning indicator
          if (_isScanning)
            const Padding( padding: EdgeInsets.all(8.0), child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(), SizedBox(width: 10), Text("Scanning...")])),
          // List of scanned devices
          Expanded(
            child: _filteredScanResults.isEmpty && !_isScanning
            // Show message when no devices are found or match filters
                ? Center(child: Padding(padding: const EdgeInsets.all(16.0), child: Text(
                _allScanResults.isNotEmpty && _filteredScanResults.isEmpty ? "No devices match filters." : "Press scan button to find devices.", textAlign: TextAlign.center)))
            // Build the list view
                : ListView.builder(
                itemCount: _filteredScanResults.length,
                itemBuilder: (context, index) {
                  final result = _filteredScanResults[index];
                  final device = result.device;
                  final advName = result.advertisementData.advName;
                  final deviceName = device.platformName;
                  // Determine the best name to display
                  String displayName = advName.isNotEmpty ? advName : (deviceName.isNotEmpty ? deviceName : "Unknown Device");
                  // Check if this specific device in the list is the currently connected one
                  bool isThisDeviceConnected = _connectedDevice?.remoteId == device.remoteId && isAnyDeviceConnected;

                  // Use Card for better list item appearance
                  return Card( margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0), elevation: 1,
                      child: ListTile(
                        title: Text(displayName),
                        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text("ID: ${device.remoteId.str}"), Text("RSSI: ${result.rssi} dBm"),
                          // Display manufacturer data if available
                          if (result.advertisementData.manufacturerData.isNotEmpty) Text("Manuf. Data: ${result.advertisementData.manufacturerData.entries.map((e) => "0x${e.key.toRadixString(16)}: ${e.value.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}").join(", ")}", overflow: TextOverflow.ellipsis),
                          // Display service UUIDs if available (shortened)
                          if (result.advertisementData.serviceUuids.isNotEmpty) Text("Services: ${result.advertisementData.serviceUuids.map((u) => u.str.substring(4, 8)).join(', ')}", overflow: TextOverflow.ellipsis),
                        ]),
                        trailing: ElevatedButton(
                          // Style button differently if connected
                          style: ElevatedButton.styleFrom(backgroundColor: isThisDeviceConnected ? Colors.grey : Theme.of(context).primaryColor),
                          child: Text(isThisDeviceConnected ? "CONNECTED" : "CONNECT", style: const TextStyle(color: Colors.white)),
                          // Disable button if connected to this device or currently scanning
                          onPressed: (isThisDeviceConnected || _isScanning) ? null : () => _connectAndNavigate(device),
                        ),
                        // Allow tapping the list tile itself to connect
                        onTap: (isThisDeviceConnected || _isScanning) ? null : () => _connectAndNavigate(device),
                      ));
                }),
          ),
        ],
      ),
      // Floating action button for scanning control
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleScan,
        tooltip: _isScanning ? 'Stop Scan' : 'Start Scan',
        icon: Icon(_isScanning ? Icons.stop : Icons.bluetooth_searching),
        label: Text(_isScanning ? 'STOP SCAN' : 'SCAN'),
      ),
    );
  }
}


// --- Screen for Displaying Image ---

class ImageDisplayScreen extends StatefulWidget {
  final BluetoothDevice device;
  const ImageDisplayScreen({super.key, required this.device});

  @override
  State<ImageDisplayScreen> createState() => _ImageDisplayScreenState();
}

class _ImageDisplayScreenState extends State<ImageDisplayScreen> {
  BluetoothCharacteristic? _imageCharacteristic;
  StreamSubscription<List<int>>? _notificationSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  final BytesBuilder _imageDataBuilder = BytesBuilder(); // Efficiently build image bytes
  Uint8List? _displayImageBytes;
  bool _isReceiving = false; // Track if data is actively being received
  String _statusMessage = "Initializing..."; // Display status messages to the user
  bool _isSaving = false; // Flag to prevent multiple save attempts concurrently

  @override
  void initState() {
    super.initState();
    _setupNotifications(); // Start listening for image data
    _listenToConnectionState(); // Monitor connection status
  }

  // Listen for device disconnection
  void _listenToConnectionState() {
    _connectionStateSubscription = widget.device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected) {
        print("Image Screen: Device disconnected.");
        if (mounted) {
          // Update UI and pop screen on disconnect
          setState(() { _statusMessage = "Device disconnected."; _isReceiving = false; });
          // Pop back to scanner screen after a short delay
          Future.delayed(const Duration(seconds: 2), () { if (mounted && Navigator.canPop(context)) Navigator.pop(context); });
        }
        _cleanupSubscriptions(); // Clean up listeners
      } else if (state == BluetoothConnectionState.connected) {
        // Optional: Handle re-connection logic if needed
        print("Image Screen: Device connected/still connected.");
        if (mounted) setState(() => _statusMessage = "Connected. Waiting for image data...");
      }
    });
  }

  // Find the characteristic and subscribe to notifications
  Future<void> _setupNotifications() async {
    if (!mounted) return;
    setState(() => _statusMessage = "Finding image characteristic...");
    try {
      // Ensure services are discovered (might have been done on previous screen)
      // It's often safe to call discoverServices again if unsure.
      List<BluetoothService> services = await widget.device.discoverServices();
      BluetoothService? imageService;
      // Find the image service
      try { imageService = services.firstWhere((s) => s.uuid == _IMAGE_SERVICE_UUID); } catch (e) { imageService = null; }

      if (imageService == null) { if(mounted) setState(() => _statusMessage = "Error: Image Service not found."); return; }

      // Find the notification characteristic
      try { _imageCharacteristic = imageService.characteristics.firstWhere((c) => c.uuid == _IMAGE_NOTIFICATION_CHAR_UUID && c.properties.notify); } catch (e) { _imageCharacteristic = null; }

      if (_imageCharacteristic == null) { if(mounted) setState(() => _statusMessage = "Error: Image Characteristic not found."); return; }

      // Subscribe to the characteristic
      await _imageCharacteristic!.setNotifyValue(true);
      // Listen for incoming data
      _notificationSubscription = _imageCharacteristic!.onValueReceived.listen((value) {
        if (value.isNotEmpty) {
          // Process the received chunk (remove last byte as requested)
          List<int> processedChunk = value.sublist(0, value.length - 1);
          _imageDataBuilder.add(processedChunk); // Add to the buffer

          // Check if we have enough bytes for a complete image
          if (_imageDataBuilder.length >= TOTAL_PIXELS) {
            // Extract the latest complete image data from the buffer
            Uint8List completeImageData = Uint8List.fromList(_imageDataBuilder.toBytes().sublist(_imageDataBuilder.length - TOTAL_PIXELS));
            // Create an image object using the 'image' package
            img.Image? image = img.Image.fromBytes(width: IMAGE_WIDTH, height: IMAGE_HEIGHT, bytes: completeImageData.buffer, format: img.Format.uint8, numChannels: 1);
            // Encode the image as PNG bytes for display and saving
            Uint8List pngBytes = Uint8List.fromList(img.encodePng(image));

            if (mounted) {
              setState(() {
                _displayImageBytes = pngBytes; // Update the image bytes for the UI
                _isReceiving = true;
                _statusMessage = "Receiving image data... (${_imageDataBuilder.length} bytes)";
              });
            }
          } else {
            // Still waiting for more data
            if (mounted) setState(() { _statusMessage = "Receiving image data... (${_imageDataBuilder.length} bytes)"; _isReceiving = true; });
          }
        }
      },
          onError: (error) { print("Notification error: $error"); if (mounted) setState(() => _statusMessage = "Notification Error: $error"); _isReceiving = false; },
          onDone: () { print("Notification stream done."); if (mounted) setState(() => _statusMessage = "Notification stream closed."); _isReceiving = false; }
      );

      if(mounted) setState(() => _statusMessage = "Subscribed. Waiting for image data...");
      print("Successfully subscribed to image characteristic.");

    } catch (e) {
      print("Error setting up notifications: $e");
      if (mounted) setState(() => _statusMessage = "Error setting up notifications: $e");
    }
  }

  // --- Function to Save Image to Gallery ---
// --- Function to Save Image to Gallery as BMP ---
  Future<void> _saveImageToGallery() async {
    // Prevent saving if no image data collected or already saving
    // Check if we have enough raw data for a complete image frame
    if (_imageDataBuilder.length < TOTAL_PIXELS || _isSaving) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Not enough image data received yet (${_imageDataBuilder.length}/${TOTAL_PIXELS} bytes).")),
        );
      }
      return;
    }

    if (mounted) setState(() => _isSaving = true); // Show saving indicator

    PermissionStatus status;
    // 1. Request appropriate permission based on platform and Android version
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo; // Use DeviceInfoPlugin instance
      if (androidInfo.version.sdkInt >= 33) { // Android 13+
        status = await Permission.photos.request(); // Request photos permission
      } else { // Android 12 or lower
        status = await Permission.storage.request(); // Request storage permission
      }
    } else if (Platform.isIOS) {
      status = await Permission.photosAddOnly.request(); // iOS: Add only permission
    } else {
      status = PermissionStatus.denied; // Default for unsupported platforms
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Saving not supported on this platform.")));
      if (mounted) setState(() => _isSaving = false); // Hide saving indicator
      return; // Exit if platform is not supported
    }

    // 2. Handle permission result
    if (status.isGranted) {
      try {
        // --- BMP Encoding Logic ---
        // Get the complete raw image data (last TOTAL_PIXELS bytes) from the buffer
        Uint8List rawImageData = Uint8List.fromList(
            _imageDataBuilder.toBytes().sublist(_imageDataBuilder.length - TOTAL_PIXELS));

        // Create an image object using the 'image' package from the raw data
        // Assuming Format.uint8 (grayscale) based on your previous code logic
        img.Image? image = img.Image.fromBytes(
            width: IMAGE_WIDTH,
            height: IMAGE_HEIGHT,
            bytes: rawImageData.buffer,
            format: img.Format.uint8, // Specify format as grayscale
            numChannels: 1 // Specify 1 channel for grayscale
        );

        if (image == null) {
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error creating image from raw data.")));
          if (mounted) setState(() => _isSaving = false);
          return;
        }

        // Encode the image as BMP bytes
        Uint8List bmpBytes = Uint8List.fromList(img.encodeBmp(image));

        // --- Save to Gallery ---
        final result = await ImageGallerySaverPlus.saveImage( // Use ImageGallerySaver use cheyyan pattila, namespace illa
            bmpBytes,
            quality: 100,  //oru safety kk vendi
            name: "thermal_image_${DateTime.now().millisecondsSinceEpoch}.bmp"
        );

        print("Save result: $result"); // Log the result from the saver

        if (mounted) { // Check if widget is still mounted before showing SnackBar
          if (result['isSuccess'] == true) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Image saved to gallery as BMP!")));
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text("Failed to save image: ${result['errorMessage'] ?? 'Unknown error'}")));
          }
        }
      } catch (e) {
        print("Error saving image: $e");
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error saving image: $e")));
        }
      }
    } else if (status.isPermanentlyDenied) {
      // Handle permanently denied permission
      print("Storage permission permanently denied.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Permission denied. Please enable storage access in app settings.")));
        // Guide user to app settings
        openAppSettings();
      }
    } else {
      // Handle denied permission
      print("Storage permission denied.");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Storage permission denied. Cannot save image.")));
      }
    }

    if (mounted) setState(() => _isSaving = false); // Hide saving indicator
  }


  // Clean up stream subscriptions
  void _cleanupSubscriptions() {
    _notificationSubscription?.cancel(); _notificationSubscription = null;
    _connectionStateSubscription?.cancel(); _connectionStateSubscription = null;
    // Optional: Turn off notifications explicitly if characteristic is still valid
    // This is usually handled by the disconnect itself.
    // if (_imageCharacteristic != null && widget.device.isConnected) {
    //   _imageCharacteristic!.setNotifyValue(false).catchError((e) {/* ignore */});
    // }
  }

  @override
  void dispose() {
    print("Image Screen disposing. Cleaning up subscriptions.");
    _cleanupSubscriptions(); // Ensure cleanup on dispose
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // Show device name in AppBar
        title: Text("Image from ${widget.device.platformName.isNotEmpty ? widget.device.platformName : widget.device.remoteId.str}"),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              // Display status message
              Text(_statusMessage),
              const SizedBox(height: 20),
              // Image display area
              Expanded(
                child: Container(
                  width: double.infinity, // Take available width
                  decoration: BoxDecoration(border: Border.all(color: Colors.grey), color: Colors.grey[200]),
                  alignment: Alignment.center,
                  // Show image if available, otherwise show placeholder
                  child: _displayImageBytes != null
                      ? Image.memory(_displayImageBytes!, gaplessPlayback: true, fit: BoxFit.contain)
                      : Column( mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.image_search, size: 50, color: Colors.grey[400]),
                    const SizedBox(height: 10),
                    Text(_isReceiving ? 'Waiting for enough data...' : 'No image data received yet.'),
                  ]),
                ),
              ),
              const SizedBox(height: 20),
              // --- Save Button ---
              ElevatedButton.icon(
                // Show progress indicator while saving
                icon: _isSaving ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.save_alt),
                label: Text(_isSaving ? "SAVING..." : "SAVE TO GALLERY"),
                // Disable button if no image or already saving
                onPressed: (_displayImageBytes == null || _isSaving) ? null : _saveImageToGallery,
                style: ElevatedButton.styleFrom(minimumSize: const Size(150, 40)), // Ensure button has reasonable size
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// --- DeviceInfoPlugin import moved to the top ---
