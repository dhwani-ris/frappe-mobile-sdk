import 'package:flutter/material.dart';
import 'package:flutter_form_builder/flutter_form_builder.dart';
import '../../../models/doc_field.dart';
import 'base_field.dart';

/// Common country codes with their dial codes
class CountryCode {
  final String name;
  final String code;
  final String dialCode;
  final String flag;

  CountryCode({
    required this.name,
    required this.code,
    required this.dialCode,
    required this.flag,
  });
}

/// Widget for Phone field type with country code selector
class PhoneField extends BaseField {
  const PhoneField({
    super.key,
    required super.field,
    super.value,
    super.onChanged,
    super.enabled,
    super.style,
  });

  static final List<CountryCode> _countryCodes = [
    CountryCode(name: 'India', code: 'IN', dialCode: '+91', flag: '🇮🇳'),
    CountryCode(name: 'United States', code: 'US', dialCode: '+1', flag: '🇺🇸'),
    CountryCode(name: 'United Kingdom', code: 'GB', dialCode: '+44', flag: '🇬🇧'),
    CountryCode(name: 'Canada', code: 'CA', dialCode: '+1', flag: '🇨🇦'),
    CountryCode(name: 'Australia', code: 'AU', dialCode: '+61', flag: '🇦🇺'),
    CountryCode(name: 'Germany', code: 'DE', dialCode: '+49', flag: '🇩🇪'),
    CountryCode(name: 'France', code: 'FR', dialCode: '+33', flag: '🇫🇷'),
    CountryCode(name: 'Italy', code: 'IT', dialCode: '+39', flag: '🇮🇹'),
    CountryCode(name: 'Spain', code: 'ES', dialCode: '+34', flag: '🇪🇸'),
    CountryCode(name: 'Japan', code: 'JP', dialCode: '+81', flag: '🇯🇵'),
    CountryCode(name: 'China', code: 'CN', dialCode: '+86', flag: '🇨🇳'),
    CountryCode(name: 'Brazil', code: 'BR', dialCode: '+55', flag: '🇧🇷'),
    CountryCode(name: 'Russia', code: 'RU', dialCode: '+7', flag: '🇷🇺'),
    CountryCode(name: 'South Korea', code: 'KR', dialCode: '+82', flag: '🇰🇷'),
    CountryCode(name: 'Mexico', code: 'MX', dialCode: '+52', flag: '🇲🇽'),
    CountryCode(name: 'Netherlands', code: 'NL', dialCode: '+31', flag: '🇳🇱'),
    CountryCode(name: 'Sweden', code: 'SE', dialCode: '+46', flag: '🇸🇪'),
    CountryCode(name: 'Norway', code: 'NO', dialCode: '+47', flag: '🇳🇴'),
    CountryCode(name: 'Denmark', code: 'DK', dialCode: '+45', flag: '🇩🇰'),
    CountryCode(name: 'Finland', code: 'FI', dialCode: '+358', flag: '🇫🇮'),
    CountryCode(name: 'Poland', code: 'PL', dialCode: '+48', flag: '🇵🇱'),
    CountryCode(name: 'Turkey', code: 'TR', dialCode: '+90', flag: '🇹🇷'),
    CountryCode(name: 'Saudi Arabia', code: 'SA', dialCode: '+966', flag: '🇸🇦'),
    CountryCode(name: 'UAE', code: 'AE', dialCode: '+971', flag: '🇦🇪'),
    CountryCode(name: 'Singapore', code: 'SG', dialCode: '+65', flag: '🇸🇬'),
    CountryCode(name: 'Malaysia', code: 'MY', dialCode: '+60', flag: '🇲🇾'),
    CountryCode(name: 'Thailand', code: 'TH', dialCode: '+66', flag: '🇹🇭'),
    CountryCode(name: 'Indonesia', code: 'ID', dialCode: '+62', flag: '🇮🇩'),
    CountryCode(name: 'Philippines', code: 'PH', dialCode: '+63', flag: '🇵🇭'),
    CountryCode(name: 'Vietnam', code: 'VN', dialCode: '+84', flag: '🇻🇳'),
    CountryCode(name: 'Bangladesh', code: 'BD', dialCode: '+880', flag: '🇧🇩'),
    CountryCode(name: 'Pakistan', code: 'PK', dialCode: '+92', flag: '🇵🇰'),
    CountryCode(name: 'Sri Lanka', code: 'LK', dialCode: '+94', flag: '🇱🇰'),
    CountryCode(name: 'Nepal', code: 'NP', dialCode: '+977', flag: '🇳🇵'),
    CountryCode(name: 'South Africa', code: 'ZA', dialCode: '+27', flag: '🇿🇦'),
    CountryCode(name: 'Egypt', code: 'EG', dialCode: '+20', flag: '🇪🇬'),
    CountryCode(name: 'Nigeria', code: 'NG', dialCode: '+234', flag: '🇳🇬'),
    CountryCode(name: 'Kenya', code: 'KE', dialCode: '+254', flag: '🇰🇪'),
    CountryCode(name: 'Israel', code: 'IL', dialCode: '+972', flag: '🇮🇱'),
    CountryCode(name: 'New Zealand', code: 'NZ', dialCode: '+64', flag: '🇳🇿'),
    CountryCode(name: 'Argentina', code: 'AR', dialCode: '+54', flag: '🇦🇷'),
    CountryCode(name: 'Chile', code: 'CL', dialCode: '+56', flag: '🇨🇱'),
    CountryCode(name: 'Colombia', code: 'CO', dialCode: '+57', flag: '🇨🇴'),
    CountryCode(name: 'Peru', code: 'PE', dialCode: '+51', flag: '🇵🇪'),
    CountryCode(name: 'Venezuela', code: 'VE', dialCode: '+58', flag: '🇻🇪'),
  ];

  /// Extract country code and phone number from full phone string
  static CountryCode? _extractCountryCode(String? phoneValue) {
    if (phoneValue == null || phoneValue.isEmpty) {
      return _countryCodes.first; // Default to first (India)
    }

    // Find matching country code
    for (final country in _countryCodes) {
      if (phoneValue.startsWith(country.dialCode)) {
        return country;
      }
    }

    // Default to first if no match
    return _countryCodes.first;
  }

  /// Extract phone number without country code
  static String _extractPhoneNumber(String? phoneValue, CountryCode countryCode) {
    if (phoneValue == null || phoneValue.isEmpty) {
      return '';
    }

    if (phoneValue.startsWith(countryCode.dialCode)) {
      return phoneValue.substring(countryCode.dialCode.length).trim();
    }

    return phoneValue.trim();
  }

  @override
  Widget buildField(BuildContext context) {
    final phoneValue = value?.toString() ?? field.defaultValue ?? '';
    final selectedCountry = _extractCountryCode(phoneValue);
    final phoneNumber = _extractPhoneNumber(phoneValue, selectedCountry!);

    // Use a StatefulWidget to manage country code selection
    // Add key based on value to force rebuild when value changes
    return _PhoneFieldWidget(
      key: ValueKey('phone_${field.fieldname}_$phoneValue'),
      field: field,
      initialValue: phoneValue,
      selectedCountry: selectedCountry,
      phoneNumber: phoneNumber,
      enabled: enabled && !field.readOnly,
      style: style,
      onChanged: onChanged,
    );
  }
}

class _PhoneFieldWidget extends StatefulWidget {
  final DocField field;
  final String initialValue;
  final CountryCode selectedCountry;
  final String phoneNumber;
  final bool enabled;
  final FieldStyle? style;
  final ValueChanged<dynamic>? onChanged;

  const _PhoneFieldWidget({
    super.key,
    required this.field,
    required this.initialValue,
    required this.selectedCountry,
    required this.phoneNumber,
    required this.enabled,
    this.style,
    this.onChanged,
  });

  @override
  State<_PhoneFieldWidget> createState() => _PhoneFieldWidgetState();
}

class _PhoneFieldWidgetState extends State<_PhoneFieldWidget> {
  late CountryCode _selectedCountry;
  late String _phoneNumber;

  @override
  void initState() {
    super.initState();
    _selectedCountry = widget.selectedCountry;
    _phoneNumber = widget.phoneNumber;
  }

  @override
  void didUpdateWidget(_PhoneFieldWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Always update if initialValue changed, even if country/phone appear same
    if (oldWidget.initialValue != widget.initialValue ||
        oldWidget.selectedCountry != widget.selectedCountry ||
        oldWidget.phoneNumber != widget.phoneNumber) {
      final newCountry = PhoneField._extractCountryCode(widget.initialValue);
      final newPhone = PhoneField._extractPhoneNumber(widget.initialValue, newCountry!);
      setState(() {
        _selectedCountry = newCountry;
        _phoneNumber = newPhone;
      });
    }
  }

  void _updateValue(String newPhoneNumber) {
    final newValue = '${_selectedCountry.dialCode}$newPhoneNumber';
    widget.onChanged?.call(newValue);
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Country code dropdown
        Container(
          width: 110,
          height: 56,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(4),
            color: widget.field.readOnly ? Colors.grey[200] : Colors.white,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<CountryCode>(
              value: _selectedCountry,
              isExpanded: true,
              isDense: false,
              icon: Icon(
                Icons.arrow_drop_down,
                size: 24,
                color: widget.enabled ? Colors.grey[700] : Colors.grey[400],
              ),
              style: TextStyle(
                fontSize: 14,
                color: widget.enabled ? Colors.black87 : Colors.grey[600],
              ),
              items: PhoneField._countryCodes.map((country) {
                return DropdownMenuItem<CountryCode>(
                  value: country,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          country.flag,
                          style: const TextStyle(fontSize: 18),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          country.dialCode,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
              onChanged: widget.enabled
                  ? (CountryCode? newCountry) {
                      if (newCountry != null && newCountry != _selectedCountry) {
                        setState(() {
                          _selectedCountry = newCountry;
                        });
                        _updateValue(_phoneNumber);
                      }
                    }
                  : null,
            ),
          ),
        ),
        const SizedBox(width: 12),
        // Phone number input
        Expanded(
          child: FormBuilderTextField(
            key: ValueKey('${widget.field.fieldname}_phone_${_phoneNumber}_${_selectedCountry.dialCode}'),
            name: widget.field.fieldname ?? '',
            initialValue: _phoneNumber, // Only show phone number, not country code
            enabled: widget.enabled,
            keyboardType: TextInputType.phone,
            decoration: widget.style?.decoration ?? InputDecoration(
              hintText: widget.field.placeholder ?? 'Enter phone number',
              border: const OutlineInputBorder(),
              filled: widget.field.readOnly,
              fillColor: widget.field.readOnly ? Colors.grey[200] : null,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            ),
            maxLength: (widget.field.length != null && widget.field.length! > 0)
                ? widget.field.length
                : null,
            validator: widget.field.reqd
                ? (value) {
                    if (value == null || value.toString().isEmpty) {
                      return '${widget.field.displayLabel} is required';
                    }
                    // Validate phone number format (digits only, reasonable length)
                    final cleaned = value.replaceAll(RegExp(r'[\s\-\(\)]'), '');
                    if (!RegExp(r'^[0-9]{7,15}$').hasMatch(cleaned)) {
                      return 'Please enter a valid phone number';
                    }
                    return null;
                  }
                : (value) {
                    if (value != null && value.isNotEmpty) {
                      final cleaned = value.replaceAll(RegExp(r'[\s\-\(\)]'), '');
                      if (!RegExp(r'^[0-9]{7,15}$').hasMatch(cleaned)) {
                        return 'Please enter a valid phone number';
                      }
                    }
                    return null;
                  },
            onChanged: (val) {
              if (val != null) {
                setState(() {
                  _phoneNumber = val;
                });
                _updateValue(val);
              }
            },
          ),
        ),
      ],
    );
  }
}
