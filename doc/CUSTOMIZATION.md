# Customization

This file is the primary reference for customization.

## Form styling

The SDK exposes three predefined styles:

- `DefaultFormStyle.standard` (Material 3 style)
- `DefaultFormStyle.compact` (reduced spacing)
- `DefaultFormStyle.material` (classic Material underline inputs)

You can also provide a fully custom `FrappeFormStyle`.

Example (from README):

```dart
// Use predefined styles
DefaultFormStyle.standard;  // Standard Material 3 style
DefaultFormStyle.compact;   // Compact style
DefaultFormStyle.material;  // Material Design style

// Or create custom style
FrappeFormStyle(
  labelStyle: TextStyle(fontSize: 16),
  sectionPadding: EdgeInsets.all(20),
  fieldDecoration: (field) => InputDecoration(...),
);
```

## Extensibility points

- **Custom field factory**: provide your own field widget mapping for specific field types/fieldnames.
- **Custom field widgets**: use your own widget implementations for specialized UI needs.
- **Login styling**: customize login UI with `LoginScreenStyle`.

- `FrappeFormStyle` / `DefaultFormStyle`
- custom field factory widgets
- `LoginScreenStyle`

