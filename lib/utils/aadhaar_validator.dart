class AadhaarValidator {
  static bool isValid(String? aadhaarNumber) {
    if (aadhaarNumber == null || aadhaarNumber.isEmpty) {
      return false;
    }

    String cleanNumber = aadhaarNumber.replaceAll(RegExp(r'[\s-]'), '');

    // Aadhaar Regex
    RegExp aadhaarRegExp = RegExp(r'^[2-9][0-9]{11}$');

    return aadhaarRegExp.hasMatch(cleanNumber);
  }
}
