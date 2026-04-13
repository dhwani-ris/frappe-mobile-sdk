import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'base_field.dart';

/// Frappe Geolocation field — fetches live GPS coordinates and stores them
/// as a GeoJSON FeatureCollection string (the format Frappe expects).
///
/// UI: A card showing current coordinates (if any) with a "Fetch Location"
/// button. Tapping the button requests location permission and captures
/// the device's current position.
///
/// **Platform setup required by consuming apps:**
/// - Android: `ACCESS_FINE_LOCATION` + `ACCESS_COARSE_LOCATION` in AndroidManifest.xml
/// - iOS: `NSLocationWhenInUseUsageDescription` in Info.plist
class GeolocationField extends BaseField {
  const GeolocationField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  @override
  Widget buildField(BuildContext context) {
    return _GeolocationFieldWidget(
      value: value,
      onChanged: onChanged,
      enabled: enabled && !field.readOnly,
      reqd: field.reqd,
      label: field.displayLabel,
    );
  }
}

class _GeolocationFieldWidget extends StatefulWidget {
  const _GeolocationFieldWidget({
    required this.value,
    required this.onChanged,
    required this.enabled,
    required this.reqd,
    required this.label,
  });

  final dynamic value;
  final ValueChanged<dynamic>? onChanged;
  final bool enabled;
  final bool reqd;
  final String label;

  @override
  State<_GeolocationFieldWidget> createState() =>
      _GeolocationFieldWidgetState();
}

class _GeolocationFieldWidgetState extends State<_GeolocationFieldWidget> {
  bool _loading = false;
  String? _error;
  double? _latitude;
  double? _longitude;

  @override
  void initState() {
    super.initState();
    _parseExistingValue();
  }

  /// Parse existing GeoJSON value to extract coordinates for display.
  void _parseExistingValue() {
    final val = widget.value;
    if (val == null || val.toString().trim().isEmpty) return;
    try {
      final Map<String, dynamic> geo = val is Map<String, dynamic>
          ? val
          : jsonDecode(val.toString());
      final features = geo['features'] as List?;
      if (features != null && features.isNotEmpty) {
        final geometry = features[0]['geometry'] as Map<String, dynamic>?;
        if (geometry != null && geometry['type'] == 'Point') {
          final coords = geometry['coordinates'] as List;
          // GeoJSON is [longitude, latitude]
          _longitude = (coords[0] as num).toDouble();
          _latitude = (coords[1] as num).toDouble();
        }
      }
    } catch (_) {
      // Ignore parse errors for existing value
    }
  }

  /// Build GeoJSON FeatureCollection string with a single Point feature.
  String _toGeoJson(double latitude, double longitude) {
    return jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [longitude, latitude],
          },
          'properties': {},
        },
      ],
    });
  }

  Future<void> _fetchLocation() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          _error = 'Location services are disabled. Please enable GPS.';
          _loading = false;
        });
        return;
      }

      // Check and request permission
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() {
            _error = 'Location permission denied.';
            _loading = false;
          });
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() {
          _error =
              'Location permission permanently denied. Please enable in Settings.';
          _loading = false;
        });
        return;
      }

      // Get current position
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );

      final geoJson = _toGeoJson(position.latitude, position.longitude);

      setState(() {
        _latitude = position.latitude;
        _longitude = position.longitude;
        _loading = false;
      });

      widget.onChanged?.call(geoJson);
    } catch (e) {
      setState(() {
        _error = 'Failed to get location. Please try again.';
        _loading = false;
      });
    }
  }

  void _clearLocation() {
    setState(() {
      _latitude = null;
      _longitude = null;
      _error = null;
    });
    widget.onChanged?.call(null);
  }

  @override
  Widget build(BuildContext context) {
    final hasLocation = _latitude != null && _longitude != null;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Coordinates display
          if (hasLocation)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(7),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.location_on,
                    color: Colors.green.shade700,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_latitude!.toStringAsFixed(6)}, ${_longitude!.toStringAsFixed(6)}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.green.shade800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Location captured',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.green.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.enabled)
                    IconButton(
                      icon: Icon(
                        Icons.close,
                        size: 18,
                        color: Colors.grey.shade600,
                      ),
                      onPressed: _clearLocation,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      tooltip: 'Clear location',
                    ),
                ],
              ),
            ),

          // Error message
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    Icons.error_outline,
                    color: Colors.red.shade700,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.red.shade700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Fetch button
          if (widget.enabled)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _fetchLocation,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          hasLocation ? Icons.refresh : Icons.my_location,
                          size: 18,
                        ),
                  label: Text(
                    _loading
                        ? 'Fetching location...'
                        : hasLocation
                        ? 'Refresh Location'
                        : 'Fetch Location',
                  ),
                ),
              ),
            ),

          // Read-only empty state
          if (!widget.enabled && !hasLocation)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'No location captured',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
            ),
        ],
      ),
    );
  }
}
