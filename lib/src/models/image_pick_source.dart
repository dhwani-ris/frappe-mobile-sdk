/// Which sources an image field offers the user.
///
/// Supplied by the host through a hook so it can be flipped from a setting
/// without rebuilding. Null anywhere in the chain means [both], so a host that
/// wires nothing keeps the previous behaviour.
///
/// Applies to `Attach Image` / `Image` only. `Attach` uses the system file
/// picker, which has no gallery/camera distinction.
enum ImagePickSource {
  /// Only "Choose from gallery".
  gallery,

  /// Only "Take a photo" — use this to force a fresh capture, e.g. so a stock
  /// image cannot be submitted as evidence.
  camera,

  /// Both, the default.
  both,
}

extension ImagePickSourceHelpers on ImagePickSource {
  bool get allowsGallery => this != ImagePickSource.camera;
  bool get allowsCamera => this != ImagePickSource.gallery;
}
